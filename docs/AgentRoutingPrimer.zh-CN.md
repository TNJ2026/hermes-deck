# AgentRoutingPrimer 原理与工作过程

> 对应代码版本:`hermes_deck/Models/AgentRoutingPrimer.swift` 及相关模块(2026-06)。

`AgentRoutingPrimer` 解决一个问题:**如何让每个 agent 天然知道"我可以把任务转发给别的 agent,以及现在有哪些目标可转"**——不依赖安装技能、不依赖用户口头教学,并且目标列表永远与 Deck 的真实配置一致。

---

## 1. 背景与动机

Hermes Deck 的 agent 间路由约定是:agent 在回复中输出一个带 `AgentRouting` 标记的 fenced code block:

````
```AgentRouting
@<target> <prompt>
```
````

Deck 客户端解析这个块,把 prompt 转发给目标 agent,再把目标的回复回传给源 agent(close-the-loop)。

这是一个**文本约定**——agent 必须先"知道"这个格式才会使用。早期的知识投递方式是 `deck-routing` 技能(skill),它有几个固有缺陷:

| 缺陷 | 说明 |
|---|---|
| 需要安装/启用 | 每个 profile 单独配置,新建 profile 默认不会路由 |
| 目标列表写死 | skill 文档里只能举例 `@researcher`、`@developer`,不知道用户实际有哪些 profile |
| 格式漂移 | 路由语法在 Deck 仓库演进(行首 mention → code block → AgentRouting 标记),skill 文档在另一个仓库,极易过期 |

Primer 把知识投递改为:**Deck 在创建 gateway 会话时,自动种入一条 system 角色的说明消息**,内容运行时生成。

## 2. 方案选型

实现前评估过四条路径:

| 方案 | 投递位置 | 改 hermes 代码 | 缺点 |
|---|---|---|---|
| A | 首条 user prompt 前拼接 | 否 | user 角色遵从度低;混入会话历史;需要 Deck 簿记"已注入" |
| B | 环境变量 → gateway 拼 system prompt | 是(约 10 行) | env 进程启动时定死,profile 变化需重启 gateway |
| C | RPC 参数 → gateway 拼 system prompt | 是(约 10-20 行) | 体验最完整,但跨仓库 |
| **C-lite(已采用)** | `session.create` 的种子历史,system 角色 | **否** | 在 history 而非 cached system prompt,极长会话理论上可能被历史压缩 |

C-lite 的关键发现:gateway 的 `session.create` 本来就接受 `messages` 参数(种子历史),其解析函数 `_coerce_seed_history`(hermes-agent `tui_gateway/server.py`)**接受 `role: "system"`**:

```python
role = item.get("role")
if role not in ("user", "assistant", "system"):
    continue
```

于是无需修改任何 hermes 代码,就能把 primer 以 system 角色写进会话的第一条历史。

## 3. 组成模块

四个模块,职责单一,串成一条管道:

```
ChatStore.routingPrimer(for:)          ── 目标收集与过滤
        │  (生成文本)
AgentRoutingPrimer.text(targets:)      ── 文案模板
        │  (挂到请求)
HermesChatRequest.routingPrimer        ── 传输载体
        │  (会话创建时种入)
HermesTUIGatewayClient.createParams    ── RPC 投递
```

### 3.1 文案模板 — `Models/AgentRoutingPrimer.swift`

```swift
enum AgentRoutingPrimer {
    static func text(targets: [String]) -> String? {
        guard !targets.isEmpty else { return nil }
        let fence = AgentMentionRouteParser.routingFenceInfo
        ...
    }
}
```

要点:

- **fence 名引用解析器常量** `AgentMentionRouteParser.routingFenceInfo`(`"AgentRouting"`)。文案与解析器在同一模块、同一 commit 维护——格式改了,二者必然同步,这正是 skill 方案做不到的
- `targets` 为空(没有任何可转目标)返回 `nil`,完全不注入
- 文案内容固定五件事:运行环境声明(Hermes Deck)、块格式示例、可用目标列表、规则(块内容以 @target 开头 / 一块一目标 / 多块并行 / 回复会回传 / 单跳不可再转 / prose 与普通代码块不路由)、决策准则(任务明确匹配对方专长或用户要求时才委派)

### 3.2 目标收集 — `ChatStore+Routing.swift` 的 `routingPrimer(for:)`

```swift
func routingPrimer(for profile: HermesProfile) -> String? {
    let selfID = profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let profileAliases = mentionableProfiles
        .map { $0.id... }
        .filter { !$0.isEmpty && $0 != selfID }
    let cliAliases = externalAgentMentionTargets.compactMap(\.aliases.first)
    return AgentRoutingPrimer.text(targets: profileAliases + cliAliases)
}
```

目标来源(与路由解析器的别名表同源):

1. **Hermes profiles**:`mentionableProfiles` = 所有 agent profile + 主聊天的 `default`(`@default` 可把任务转回主 Hermes agent)
2. **外部 CLI**:`externalAgentMentionTargets` 的主别名 —— `codex`、`claude`、`gemini`

过滤规则:**排除会话自身的 profile**(@自己没有意义,路由层也会把自路由当纯文本)。所以每个 profile 的 gateway 收到的目标列表都不同——coding 的列表里没有 coding,manager 的列表里没有 manager。

**动态性**:这个函数在**每次发送时**求值。用户新增/删除 profile 后,下一个新建的会话自动拿到最新列表(profile 列表本身在 App 启动时经 `loadProfiles()` 加载)。

### 3.3 传输载体 — `Services/ServiceModels.swift` 的 `HermesChatRequest`

```swift
/// Seeded as a system-role message when the gateway session is created...
var routingPrimer: String?
```

挂载点在低层 send(`ChatStore+Send.swift`)构造请求处:

```swift
let backend = threadBackends[threadID] ?? .hermes
let request = HermesChatRequest(
    ...
    routingPrimer: backend == .hermes ? routingPrimer(for: profile) : nil
)
```

**只有 `.hermes` backend 注入**。外部 CLI(codex / claude / gemini)被路由层禁止发起转发(external 源一律 denied),给它们注入只会浪费 token,所以 `nil`。

### 3.4 RPC 投递 — `Services/TUIGatewayClient.swift` 的 `createParams(for:)`

```swift
private func createParams(for request: HermesChatRequest) -> [String: TUIJSONValue] {
    var params: [String: TUIJSONValue] = [
        "cols": .number(100),
        "title": .string(title(for: request)),
    ]
    if let primer = request.routingPrimer, !primer.isEmpty {
        params["messages"] = .array([
            .object(["role": .string("system"), "content": .string(primer)])
        ])
    }
    return params
}
```

只在 **`session.create`** 时携带(包括 resume 失败回退到 create 的路径)。`session.resume` 不带——见下文生命周期。

## 4. 完整工作时序

以"用户在 researcher 面板发出第一条消息"为例:

```
用户在 researcher 面板输入 "dig in" → 发送
  │
  ▼
ChatStore 低层 send 构造 HermesChatRequest
  backend == .hermes
  → routingPrimer(for: researcher)
     = mentionableProfiles 排除 researcher 自身
     + codex/claude/gemini
     → AgentRoutingPrimer.text(...)  生成文案
  │
  ▼
HermesTUIGatewayClient.sessionID(for:)
  该会话首次 → session.create
  params.messages = [{role: "system", content: <primer>}]
  │
  ▼
gateway(tui_gateway/server.py)
  _coerce_seed_history 接受 system 角色
  → primer 成为会话历史第 1 条(system)
  → 写入该 profile 的 state.db(持久化)
  │
  ▼
prompt.submit("dig in")
  agent 构建对话:历史[system: primer, user: dig in]
  → 从第一轮起就"知道"路由格式与可用目标
```

之后 agent 任意一轮想委派时:

```
researcher 回复:
  好的,我让 coding 处理:
  ```AgentRouting
  @coding 修复 parser 崩溃
  ```
  │
  ▼
Deck forwardAddressedReply → codeBlockRouteSpans 四道校验
  ① 闭合 fence  ② info == "AgentRouting"(大小写不敏感)
  ③ 内容以 @alias 开头(别名表与 primer 同源)
  ④ 一块一目标
  │
  ▼
fan-out:目标线程并行执行(源线程标 busy,UI 出等待卡片)
  │
  ▼
回复回传:framed "Coding replied:" 以 user 消息发回源 agent
  (UI 不显示该消息,由 replied 状态卡片承载展示)
```

## 5. Agent 是如何"知道"转发格式的

这里没有任何配置项、协议握手或代码层面的能力注册——**机制本质是 LLM 的上下文内学习(in-context learning)**:

1. **格式以自然语言+示例的形式存在于上下文中**。primer 是一条 system 角色消息,内容包含一个完整的格式样例:

   ````
   ```AgentRouting
   @<target> <prompt>
   ```
   ````

   以及使用规则和目标清单。它位于会话历史的第 1 条,**每一轮推理时都在模型的上下文窗口里**——不是"教过一次就忘",而是每轮都看得见。

2. **模型在需要时模仿输出**。当对话中出现"把这个交给 coding"之类的意图(用户明说,或模型自己判断任务匹配某目标的专长),模型按照 primer 中的样例,生成一个同构的 `AgentRouting` 块。这是大模型最可靠的能力之一——按上下文中给出的模板产出结构化文本。

3. **system 角色提升遵从度**。同样的文字放在 user 消息里,模型可能当作普通对话内容对待;system 角色携带"运行环境规则"的语义权重,主流模型对其中的格式约定遵守得更稳定。这是 C-lite 相对方案 A(user prompt 注入)的遵从度优势来源。

4. **闭环由 Deck 完成,模型无感知执行细节**。模型只负责"按格式输出";解析、转发、回传全部由 Deck 客户端在模型之外完成。模型随后收到的 `Coding replied: …` follow-up,在它看来只是又一条输入——它不需要理解(也不知道)中间发生了进程间路由。

换句话说:**agent "知道"格式 = 格式说明持续存在于它的上下文中 + 模型的模板模仿能力**。这也解释了两个边界现象:

- 旧会话(primer 上线前创建)的 agent 不知道格式——它的上下文里没有这段说明;
- 模型偶尔可能输出不合格式的块(双目标、不以 @ 开头等)——这是文本约定的固有误差,两层兜底:① 解析器四道校验保证不产生错误路由,不合格的块原样显示为代码块;② **一次性自动纠错**——带 `AgentRouting` 标记但校验失败的块(意图明确、格式错了),Deck 自动回告具体原因与正确格式,agent 重发一次(`forwardAddressedReply` 的 `allowsCorrection` 限重试一次,防循环;纠错消息走隐藏的 routing follow-up 标志,不在 UI 显示)。仍失败则停止(详见第 6 节;工具化演进见第 9 节)。

## 6. 格式错误的自动纠错(one-shot self-correction)

文本约定的固有误差由两层机制兜底。第一层是解析器的四道校验(保证**永不误路由**);第二层是本节的自动纠错(尽量把**漏路由**也救回来)。

### 6.1 触发条件

回复同时满足两点才触发:

1. `codeBlockRouteSpans` 没有解析出任何**有效**路由(有有效块就直接路由,不纠错——部分成功时重发会产生重复路由,宁可保守);
2. 回复中存在**带 `AgentRouting` 标记但校验失败**的块——fence 标记说明 agent 明确想路由,只是格式写错了。

裸 ``` 块、其它语言块即使内容像路由也不触发(意图不明,不打扰;它们本来就被设计为"永不路由"的安全区)。

### 6.2 诊断

`AgentMentionRouteParser.malformedRoutingBlockReasons(in:aliasGroups:)` 对每个带标记的失败块给出一条人类可读原因,与四道校验一一对应:

| 失败形态 | 回告原因 |
|---|---|
| 内容不以 `@` 开头(如 `please @coding fix it`) | the block's content must start with @<target> |
| `@target` 不在别名表(拼错/不存在的 profile) | the @target is not one of the available targets |
| `@target` 后没有 prompt | the block has no prompt after the @target |
| 正文里出现第二个已知 `@target` | the block contains a second @target — one block addresses one target |

别名表经 `mentionRouteGroups()` 与路由解析器**同源**——诊断永远和真实路由行为一致。

### 6.3 纠错流程

```
agent 回复(含不合格的 AgentRouting 块)
  │
  ▼
forwardAddressedReply
  hasMentionRoute(codeBlockOnly) == false      ← 没有有效路由
  allowsCorrection == true                     ← 首次,允许纠错
  malformedRoutingBlockReasons(...) 非空       ← 确认是"想路由但写错"
  │
  ▼
Deck 自动发送纠错消息(user 角色,isAgentReplyFollowUp = true):
  [Hermes Deck] Your AgentRouting block was not routed: <具体原因>.
  The format is:
  ```AgentRouting
  @<target> <prompt>
  ```
  Re-emit the corrected block(s) now, or reply normally to skip routing.
  │
  ▼
agent 重发(一轮 API)
  │
  ▼
forwardAddressedReply(retryReply, allowsCorrection: false)   ← 递归但禁纠错
  ├─ 重发的块有效 → 正常路由(转发卡片、等待/replied 卡片照常)
  └─ 仍不合格 → 停止。顽固模型最多消耗一轮纠错,不会循环
```

一次性限制就是 `allowsCorrection` 参数:入口默认 `true`,重试递归传 `false`——结构上保证最多一轮。

### 6.4 用户看到什么

- 纠错消息携带 `isAgentReplyFollowUp` 标志,与 close-the-loop 的 framed 回传共用同一隐藏机制:**进 agent 上下文,但不在聊天列表显示**;
- 不合格的原块仍按代码块原样显示(转发卡片只为有效块渲染,显示与路由行为精确一致);
- 纠错成功时,用户看到的效果近似"agent 自己改对了":不合格块之后紧跟修正版的转发卡片与等待卡片;
- 纠错也失败时,界面安静地停在原块,无错误弹窗——格式错误的代价被限制在"这次没转发"。

### 6.5 成本与权衡

- 成本:触发时多一轮 API 调用(不触发零成本);
- 为什么不自动修复而是回告重发:自动改写(猜目标、删第二个 mention)有误路由风险,违反"漏路由可重试、误路由不可逆"的原则;让模型自己改,语义由它负责;
- 与确认按钮方案(UI 一键转发)互补:纠错处理"格式可说清"的错误,按钮适合"机器不该猜"的模糊场景(后者暂未实现)。

### 6.6 对应测试

- `malformedRoutingBlockReasonsDiagnoseEachFailure` —— 四类原因逐项命中;有效块与非路由块零误报
- `malformedRoutingBlockTriggersOneCorrectionThenRoutes` —— 错→纠→对:恰一条纠错消息(带隐藏标志),重发的块成功送达目标
- `malformedRoutingBlockCorrectionRunsOnlyOnce` —— 连续两次失败只纠错一次,且无任何路由发生

## 7. 生命周期与边界

| 场景 | 行为 |
|---|---|
| 新会话首条消息 | `session.create` 种入,一次性,之后所有轮次都在上下文里 |
| 同会话后续消息 | `sessionsByConversationID` 命中缓存,不再 create,不重复注入 |
| App 重启后 resume 历史会话 | **不需要重新注入**——primer 已随种子历史写入 state.db,`session.resume` 重建 agent 时自然带回。这是 C-lite 相比方案 A 的核心优势:零客户端簿记 |
| primer 上线前创建的旧会话 | 历史里没有 primer,resume 也不补(`session.resume` 无 messages 参数)。这些会话里 agent 不保证知道路由;重要任务建议开新会话 |
| 外部 CLI 面板的会话 | 不注入(它们不能发起路由) |
| UI 显示 | **完全不可见**——primer 只进 gateway 的会话历史,Deck 的 `ChatMessage` 列表里没有它(注:用 TUI 终端打开同一会话能看到这条 system 记录) |
| token 成本 | 每会话一次,约 120-150 token |

## 8. 测试覆盖

`hermes_deckTests/ChatStoreTests.swift`:

- `hermesRequestsCarryRoutingPrimerListingOtherTargets` —— 请求带 primer;含 ```` ```AgentRouting ```` 格式与 `@coding`/`@researcher`/`@codex`;**不含**会话自身的 `@default`;聊天线程的消息里无 primer 痕迹
- `externalBackendRequestsCarryNoRoutingPrimer` —— agy 等外部 backend 的请求 `routingPrimer == nil`
- 下游闭环另有独立测试(`codeBlockRouteSpansFollowOneBlockOneTargetRule`、`agentPanelProfileReplyForwardsAddressedMention`、`handoffStatusTracksWaitingThenRepliedForLoopClosingRoutes` 等)

## 9. 已知局限与演进方向

1. **历史压缩风险**:primer 在会话 history 中而非 cached system prompt;极长会话若触发 gateway 的历史压缩,理论上可能被裁掉。终极方案是 "真 C":`server.py` 接受 `client_context` 参数并传入 `build_system_prompt` 现成的 `system_message` 管道(约 10-20 行 hermes patch),Deck 侧只需换参数名
2. **遵从度上限**:文本约定的遵从度低于结构化工具调用。若实际出现格式错误率问题,升级路径是把路由做成 `route_to_agent(target, prompt)` 真工具(仿 `approval.request`/`approval.respond` 的 server↔client 往返),届时 primer、code block 解析、framed 回传整套机制可一并退役
3. **能力描述缺失**:目前目标列表只有别名,没有各 profile 的专长描述。可从 profile config 读取 description 字段附在列表上,提升 agent 的"转给谁"决策质量

## 10. 相关文件索引

| 文件 | 职责 |
|---|---|
| `hermes_deck/Models/AgentRoutingPrimer.swift` | primer 文案生成 |
| `hermes_deck/Models/ChatStore+Routing.swift` | 目标收集(`routingPrimer(for:)`)、路由 fan-out、状态卡片、busy 标记 |
| `hermes_deck/Models/ChatStore+Send.swift` | 请求构造时挂载 primer、按线程串行化 |
| `hermes_deck/Services/ServiceModels.swift` | `HermesChatRequest.routingPrimer` 字段 |
| `hermes_deck/Services/TUIGatewayClient.swift` | `createParams` 种入 system 消息 |
| `hermes_deck/Models/ChatModels.swift` | `AgentMentionRouteParser`(块解析)、`routingFenceInfo` 常量、`AgentReplyFraming` |
| `~/.hermes/hermes-agent/tui_gateway/server.py` | `_coerce_seed_history`(gateway 侧,未修改,现成能力) |
| `~/.hermes/skills/deck-routing/SKILL.md` | 旧知识投递方式,已降级为参考文档 |
