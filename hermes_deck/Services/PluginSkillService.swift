import Foundation

enum HermesToolListParser {
    static func parse(_ data: Data) -> [HermesInstalledTool] {
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        var tools: [HermesInstalledTool] = []
        var currentSource = ""

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasSuffix(":"), let source = sourceName(from: line) {
                currentSource = source
                continue
            }

            guard !currentSource.isEmpty, let tool = parseToolLine(line, source: currentSource) else {
                continue
            }
            tools.append(tool)
        }

        return tools.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func sourceName(from header: String) -> String? {
        let title = String(header.dropLast()).trimmingCharacters(in: .whitespaces)
        guard let range = title.range(of: " toolsets") else { return nil }
        let source = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return source.isEmpty ? nil : source
    }

    private static func parseToolLine(_ line: String, source: String) -> HermesInstalledTool? {
        guard line.hasPrefix("✓ ") || line.hasPrefix("✗ ") else { return nil }
        let parts = line.split(maxSplits: 3, whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 3 else { return nil }

        let status = parts[1].capitalized
        let name = parts[2]
        let summary = parts.count >= 4 ? parts[3].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) : ""

        return HermesInstalledTool(
            id: "\(source)-\(name)",
            name: name,
            source: source,
            status: status,
            summary: summary
        )
    }
}

enum HermesSkillListParser {
    static func parse(_ data: Data) -> [HermesInstalledSkill] {
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.components(separatedBy: .newlines).compactMap(parseLine)
    }

    private static func parseLine(_ line: String) -> HermesInstalledSkill? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("│"), trimmed.hasSuffix("│") else { return nil }

        let columns = trimmed
            .dropFirst()
            .dropLast()
            .split(separator: "│", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        guard columns.count == 5, columns[0] != "Name", !columns[0].isEmpty else {
            return nil
        }

        return HermesInstalledSkill(
            id: columns[0],
            name: columns[0],
            category: columns[1],
            source: columns[2],
            trust: columns[3],
            status: columns[4]
        )
    }
}

struct LocalHermesPluginProvider: HermesPluginProvider {
    static let deckDelegationPluginName = "deck-delegate-agent"
    static let deckDelegationPluginVersion = "0.1.2"

    var configURL: URL
    var userPluginsURL: URL
    var bundledPluginsURL: URL
    var hermesExecutableURL: URL
    var hermesArgumentsPrefix: [String]
    var rootURL: URL

    nonisolated init(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/config.yaml"),
        userPluginsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/plugins"),
        bundledPluginsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/hermes-agent/plugins"),
        hermesExecutableURL: URL = LocalHermesPluginProvider.defaultHermesExecutableURL(),
        hermesArgumentsPrefix: [String] = [],
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
    ) {
        self.configURL = configURL
        self.userPluginsURL = userPluginsURL
        self.bundledPluginsURL = bundledPluginsURL
        self.hermesExecutableURL = hermesExecutableURL
        self.hermesArgumentsPrefix = hermesArgumentsPrefix
        self.rootURL = rootURL
    }

    func installedTools(profile: HermesProfile) async throws -> [HermesInstalledTool] {
        let executableURL = hermesExecutableURL
        let arguments = hermesArgumentsPrefix + ["tools", "list"]
        let environment = Self.environment(for: profile, rootURL: rootURL)

        return try await Task.detached(priority: .utility) {
            let result = try await Self.runHermesList(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment
            )
            if result.status != 0 {
                let message = String(data: result.output, encoding: .utf8)?.pluginTextValue ?? "hermes tools list failed"
                throw NSError(domain: "HermesTools", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: message])
            }
            return HermesToolListParser.parse(result.output)
        }.value
    }

    func setTool(_ name: String, enabled: Bool, profile: HermesProfile) async throws {
        let configURL = Self.configURL(for: profile, rootURL: rootURL)
        try await Task.detached(priority: .utility) {
            try Self.setConfiguredName(
                name,
                enabled: enabled,
                enabledPath: ["tools", "enabled"],
                disabledPath: ["tools", "disabled"],
                in: configURL
            )
        }.value
    }

    func installDeckDelegationPlugin(profile: HermesProfile) async throws {
        let homeURL = Self.home(for: profile, rootURL: rootURL)
        let pluginURL = homeURL
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(Self.deckDelegationPluginName, isDirectory: true)
        let configURL = Self.configURL(for: profile, rootURL: rootURL)

        try await Task.detached(priority: .utility) {
            try Self.writeDeckDelegationPlugin(to: pluginURL)
            try Self.setConfiguredName(
                Self.deckDelegationPluginName,
                enabled: true,
                enabledPath: ["plugins", "enabled"],
                disabledPath: ["plugins", "disabled"],
                in: configURL
            )
        }.value
    }

    func deckDelegationPluginStatus(profile: HermesProfile) async throws -> DeckDelegationToolStatus {
        let homeURL = Self.home(for: profile, rootURL: rootURL)
        let pluginURL = homeURL
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(Self.deckDelegationPluginName, isDirectory: true)
        return try await Task.detached(priority: .utility) {
            try Self.deckDelegationPluginStatus(at: pluginURL)
        }.value
    }

    static func environment(for profile: HermesProfile, rootURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HERMES_HOME"] = home(for: profile, rootURL: rootURL).path(percentEncoded: false)
        return environment
    }

    static func home(for profile: HermesProfile, rootURL: URL) -> URL {
        let id = profile.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id == "default" || id.isEmpty { return rootURL }
        return rootURL.appendingPathComponent("profiles").appendingPathComponent(id)
    }

    static func configURL(for profile: HermesProfile, rootURL: URL) -> URL {
        home(for: profile, rootURL: rootURL).appendingPathComponent("config.yaml")
    }

    static func defaultHermesExecutableURL() -> URL {
        let localBinURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/hermes")
        if FileManager.default.isExecutableFile(atPath: localBinURL.path(percentEncoded: false)) {
            return localBinURL
        }

        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/hermes-agent/venv/bin/hermes")
    }

    func installedPlugins() async throws -> [HermesInstalledPlugin] {
        let configURL = configURL
        let userPluginsURL = userPluginsURL
        let bundledPluginsURL = bundledPluginsURL

        return try await Task.detached(priority: .utility) {
            let configuredStatuses = try Self.configuredStatuses(from: configURL)
            return try Self.pluginManifests(userPluginsURL: userPluginsURL, bundledPluginsURL: bundledPluginsURL).values.map { pluginManifest in
                var plugin = pluginManifest.plugin
                plugin.status = configuredStatuses[plugin.name] ?? "Available"
                return plugin
            }.sorted { lhs, rhs in
                let statusOrder = ["Enabled": 0, "Disabled": 1, "Available": 2]
                let lhsStatusOrder = statusOrder[lhs.status] ?? 3
                let rhsStatusOrder = statusOrder[rhs.status] ?? 3
                if lhsStatusOrder != rhsStatusOrder {
                    return lhsStatusOrder < rhsStatusOrder
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }.value
    }

    func installedTools() async throws -> [HermesInstalledTool] {
        let executableURL = hermesExecutableURL
        let arguments = hermesArgumentsPrefix + ["tools", "list"]

        return try await Task.detached(priority: .utility) {
            let result = try await Self.runHermesList(executableURL: executableURL, arguments: arguments)
            if result.status != 0 {
                let message = String(data: result.output, encoding: .utf8)?.pluginTextValue ?? "hermes tools list failed"
                throw NSError(domain: "HermesTools", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: message])
            }

            return HermesToolListParser.parse(result.output)
        }.value
    }

    func setPlugin(_ name: String, enabled: Bool) async throws {
        let configURL = configURL

        try await Task.detached(priority: .utility) {
            try Self.setConfiguredName(
                name,
                enabled: enabled,
                enabledPath: ["plugins", "enabled"],
                disabledPath: ["plugins", "disabled"],
                in: configURL
            )
        }.value
    }

    func setTool(_ name: String, enabled: Bool) async throws {
        let configURL = configURL

        try await Task.detached(priority: .utility) {
            try Self.setConfiguredName(
                name,
                enabled: enabled,
                enabledPath: ["tools", "enabled"],
                disabledPath: ["tools", "disabled"],
                in: configURL
            )
        }.value
    }

    fileprivate static func setConfiguredName(
        _ name: String,
        enabled: Bool,
        enabledPath: [String],
        disabledPath: [String],
        in configURL: URL
    ) throws {
        let config = HermesConfigurationFile(url: configURL)
        try config.load()

        var enabledNames = try config.stringArray(at: enabledPath)
        var disabledNames = try config.stringArray(at: disabledPath)
        enabledNames.removeAll { $0 == name }
        disabledNames.removeAll { $0 == name }

        if enabled {
            enabledNames.append(name)
        } else {
            disabledNames.append(name)
        }

        try config.setStringArray(enabledNames, at: enabledPath)
        try config.setStringArray(disabledNames, at: disabledPath)
        try config.save()
    }

    fileprivate nonisolated static func runHermesList(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> (status: Int32, output: Data) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = output

        try process.runTranslatingMissingCommand(named: "Hermes")
        let outputDataTask = Task {
            output.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        return (process.terminationStatus, await outputDataTask.value)
    }

    private static func writeDeckDelegationPlugin(to pluginURL: URL) throws {
        try FileManager.default.createDirectory(at: pluginURL, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: pluginURL.appendingPathComponent("__pycache__", isDirectory: true))
        try deckDelegationPluginManifest.write(
            to: pluginURL.appendingPathComponent("plugin.yaml"),
            atomically: true,
            encoding: .utf8
        )
        try deckDelegationPluginPython.write(
            to: pluginURL.appendingPathComponent("__init__.py"),
            atomically: true,
            encoding: .utf8
        )
        try deckDelegationPluginReadme.write(
            to: pluginURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func deckDelegationPluginStatus(at pluginURL: URL) throws -> DeckDelegationToolStatus {
        let manifestURL = pluginURL.appendingPathComponent("plugin.yaml")
        guard FileManager.default.fileExists(atPath: manifestURL.path(percentEncoded: false)) else {
            return .missing
        }

        let manifest = HermesConfigurationFile(url: manifestURL)
        try manifest.load()
        guard (try manifest.string(at: ["name"])) == deckDelegationPluginName else {
            return .missing
        }
        let installedVersion = try manifest.string(at: ["version"])
        guard installedVersion == deckDelegationPluginVersion else {
            return .outdated(installedVersion: installedVersion, bundledVersion: deckDelegationPluginVersion)
        }
        return .current(version: deckDelegationPluginVersion)
    }

    private static let deckDelegationPluginManifest = """
    name: deck-delegate-agent
    version: 0.1.2
    description: "Route delegated prompts from Hermes back to Hermes Deck."
    author: Hermes Deck
    kind: standalone
    provides_tools:
      - deck_delegate_agent
    """

    private static let deckDelegationPluginReadme = """
    # deck-delegate-agent

    Hermes Deck installs this plugin so Hermes agents can call the
    `deck_delegate_agent` tool.

    The tool validates `target` and `prompt`, then calls back to Hermes Deck
    through `HERMES_DECK_ROUTE_HOST`, `HERMES_DECK_ROUTE_PORT`, and
    `HERMES_DECK_ROUTE_TOKEN`. Hermes Deck owns the actual routing, thread
    updates, and UI handoff.
    """

    private static let deckDelegationPluginPython = #"""
    from __future__ import annotations

    import json
    import os
    import socket
    from typing import Any, Dict


    TOOL_NAME = "deck_delegate_agent"


    SCHEMA: Dict[str, Any] = {
        "name": TOOL_NAME,
        "description": (
            "Delegate a focused prompt to another Hermes Deck agent/profile. "
            "The Deck app owns routing and UI handoff. Use dry_run only for "
            "installation tests."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "target": {
                    "type": "string",
                    "description": "Deck target alias without @, such as coding or researcher.",
                },
                "prompt": {
                    "type": "string",
                    "description": "Self-contained prompt to send to the target agent.",
                },
                "wait": {
                    "type": "boolean",
                    "description": "Request synchronous waiting. Defaults to async queued handoff.",
                },
                "dry_run": {
                    "type": "boolean",
                    "description": "Validate arguments without calling Hermes Deck IPC.",
                },
            },
            "required": ["target", "prompt"],
        },
    }


    def _json(payload: Dict[str, Any]) -> str:
        return json.dumps(payload, ensure_ascii=False, sort_keys=True)


    def _error(message: str, **extra: Any) -> str:
        payload = {"ok": False, "error": message}
        payload.update(extra)
        return _json(payload)


    def _handle(args: Dict[str, Any], **kwargs: Any) -> str:
        target = str(args.get("target") or "").strip().lstrip("@")
        prompt = str(args.get("prompt") or "").strip()
        wait = bool(args.get("wait") or False)
        dry_run = bool(args.get("dry_run") or False)
        source_session_key = str(kwargs.get("task_id") or "").strip()
        source_profile_id = os.getenv("HERMES_PROFILE", "").strip()

        if not target:
            return _error("target is required")
        if not prompt:
            return _error("prompt is required")

        request = {
            "target": target,
            "prompt": prompt,
            "wait": wait,
            "source_session_key": source_session_key,
            "source_profile_id": source_profile_id,
        }
        if dry_run:
            return _json({"ok": True, "dry_run": True, "request": request})

        host = os.getenv("HERMES_DECK_ROUTE_HOST", "").strip()
        port = os.getenv("HERMES_DECK_ROUTE_PORT", "").strip()
        token = os.getenv("HERMES_DECK_ROUTE_TOKEN", "").strip()
        if not token or not host or not port:
            missing = [
                name
                for name, value in {
                    "HERMES_DECK_ROUTE_HOST": host,
                    "HERMES_DECK_ROUTE_PORT": port,
                    "HERMES_DECK_ROUTE_TOKEN": token,
                }.items()
                if not value
            ]
            return _error(
                "Hermes Deck routing IPC is not available. Run this tool from a Hermes gateway/session started by the Hermes Deck desktop app, then restart that gateway after installing or updating deck_delegate_agent.",
                missing=missing,
                request=request,
            )

        envelope = dict(request)
        envelope["token"] = token
        newline = bytes([10])

        try:
            client = socket.create_connection((host, int(port)), timeout=10)
            with client:
                client.settimeout(10)
                client.sendall(json.dumps(envelope, ensure_ascii=False).encode("utf-8") + newline)
                chunks = []
                while True:
                    chunk = client.recv(65536)
                    if not chunk:
                        break
                    chunks.append(chunk)
                    if newline in chunk:
                        break
        except (OSError, ValueError) as exc:
            return _error(f"Failed to call Hermes Deck routing IPC: {exc}", request=request)

        raw = b"".join(chunks).split(newline, 1)[0].decode("utf-8", errors="replace")
        if not raw.strip():
            return _error("Hermes Deck routing IPC returned an empty response", request=request)
        try:
            response = json.loads(raw)
        except json.JSONDecodeError:
            return _error("Hermes Deck routing IPC returned non-JSON", raw=raw, request=request)
        if isinstance(response, dict):
            return _json(response)
        return _json({"ok": True, "response": response})


    def register(ctx) -> None:
        ctx.register_tool(
            name=TOOL_NAME,
            toolset="deck",
            schema=SCHEMA,
            handler=_handle,
            description=SCHEMA["description"],
            emoji="",
        )
    """#

    private static func configuredStatuses(from configURL: URL) throws -> [String: String] {
        let config = HermesConfigurationFile(url: configURL)
        try config.load()
        let configuredPlugins = HermesPluginConfigurationParser.parse(config.yaml)
        return Dictionary(uniqueKeysWithValues: configuredPlugins.map { ($0.name, $0.status) })
    }

    private static func pluginManifests(userPluginsURL: URL, bundledPluginsURL: URL) throws -> [String: ParsedPluginManifest] {
        let manifestURLs = manifestURLs(in: [userPluginsURL, bundledPluginsURL])
        var pluginsByName: [String: ParsedPluginManifest] = [:]

        for manifestURL in manifestURLs {
            let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
            let manifest = PluginManifest.parse(manifestText)
            let source = sourceName(for: manifestURL, userPluginsURL: userPluginsURL)
            let plugin = manifest.plugin(source: source, path: manifestURL.deletingLastPathComponent().path(percentEncoded: false))
            if pluginsByName[plugin.name]?.plugin.source != "Local" {
                pluginsByName[plugin.name] = ParsedPluginManifest(plugin: plugin, manifest: manifest)
            }
        }

        return pluginsByName
    }

    private struct ParsedPluginManifest {
        var plugin: HermesInstalledPlugin
        var manifest: PluginManifest
    }

    private static func manifestURLs(in roots: [URL]) -> [URL] {
        roots.flatMap { root in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else {
                return [URL]()
            }

            return enumerator.compactMap { item in
                guard let url = item as? URL, url.lastPathComponent == "plugin.yaml" else {
                    return nil
                }
                return url
            }
        }
    }

    private static func sourceName(for manifestURL: URL, userPluginsURL: URL) -> String {
        manifestURL.standardizedFileURL.path.hasPrefix(userPluginsURL.standardizedFileURL.path) ? "Local" : "Bundled"
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let value = String(parts[1]).pluginCleanedYAMLValue
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private struct PluginManifest {
        var fields: [String: String]
        var lists: [String: [String]]

        static func parse(_ text: String) -> PluginManifest {
            var fields: [String: String] = [:]
            var lists: [String: [String]] = [:]
            var currentListKey: String?

            for rawLine in text.components(separatedBy: .newlines) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

                if trimmed.hasPrefix("- ") {
                    if let currentListKey {
                        lists[currentListKey, default: []].append(String(trimmed.dropFirst(2)).pluginCleanedYAMLValue)
                    }
                    continue
                }

                guard let (key, value) = keyValue(trimmed) else { continue }
                if value.isEmpty {
                    currentListKey = key
                    lists[key] = []
                } else {
                    currentListKey = nil
                    fields[key] = value
                }
            }

            return PluginManifest(fields: fields, lists: lists)
        }

        func plugin(source: String, path: String) -> HermesInstalledPlugin {
            let name = fields["name"] ?? URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            let capabilities = [
                lists["provides_tools"],
                lists["provides_web_providers"],
                lists["provides_browser_providers"],
                lists["provides_image_gen_providers"],
                lists["provides_video_gen_providers"],
                lists["provides_memory_providers"],
                lists["hooks"],
            ].compactMap { $0 }.flatMap { $0 }

            return HermesInstalledPlugin(
                id: "\(source)-\(name)",
                name: name,
                displayName: name,
                version: fields["version"]?.pluginTextValue ?? "Unknown",
                source: source,
                category: fields["kind"]?.pluginTextValue ?? "",
                developerName: fields["author"]?.pluginTextValue ?? "",
                summary: fields["description"]?.pluginFirstParagraph ?? "",
                capabilities: capabilities,
                path: path
            )
        }
    }
}

struct LocalHermesSkillProvider: HermesSkillProvider {
    var configURL: URL
    var hermesExecutableURL: URL
    var hermesArgumentsPrefix: [String]
    var rootURL: URL

    nonisolated init(
        configURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/config.yaml"),
        hermesExecutableURL: URL = LocalHermesPluginProvider.defaultHermesExecutableURL(),
        hermesArgumentsPrefix: [String] = [],
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
    ) {
        self.configURL = configURL
        self.hermesExecutableURL = hermesExecutableURL
        self.hermesArgumentsPrefix = hermesArgumentsPrefix
        self.rootURL = rootURL
    }

    func installedSkills(profile: HermesProfile) async throws -> [HermesInstalledSkill] {
        let executableURL = hermesExecutableURL
        let arguments = hermesArgumentsPrefix + ["skills", "list"]
        let environment = LocalHermesPluginProvider.environment(for: profile, rootURL: rootURL)

        return try await Task.detached(priority: .utility) {
            let result = try await LocalHermesPluginProvider.runHermesList(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment
            )
            if result.status != 0 {
                let message = String(data: result.output, encoding: .utf8)?.pluginTextValue ?? "hermes skills list failed"
                throw NSError(domain: "HermesSkills", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: message])
            }

            return HermesSkillListParser.parse(result.output)
        }.value
    }

    func setSkill(_ name: String, enabled: Bool, profile: HermesProfile) async throws {
        let configURL = LocalHermesPluginProvider.configURL(for: profile, rootURL: rootURL)
        try await Task.detached(priority: .utility) {
            try LocalHermesPluginProvider.setConfiguredName(
                name,
                enabled: enabled,
                enabledPath: ["skills", "enabled"],
                disabledPath: ["skills", "disabled"],
                in: configURL
            )
        }.value
    }

    func installedSkills() async throws -> [HermesInstalledSkill] {
        let executableURL = hermesExecutableURL
        let arguments = hermesArgumentsPrefix + ["skills", "list"]

        return try await Task.detached(priority: .utility) {
            let result = try await LocalHermesPluginProvider.runHermesList(
                executableURL: executableURL,
                arguments: arguments
            )
            if result.status != 0 {
                let message = String(data: result.output, encoding: .utf8)?.pluginTextValue ?? "hermes skills list failed"
                throw NSError(domain: "HermesSkills", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: message])
            }

            return HermesSkillListParser.parse(result.output)
        }.value
    }

    func setSkill(_ name: String, enabled: Bool) async throws {
        let configURL = configURL

        try await Task.detached(priority: .utility) {
            try LocalHermesPluginProvider.setConfiguredName(
                name,
                enabled: enabled,
                enabledPath: ["skills", "enabled"],
                disabledPath: ["skills", "disabled"],
                in: configURL
            )
        }.value
    }
}

enum HermesPluginConfigurationParser {
    static func parse(_ config: String) -> [ConfiguredPlugin] {
        let configuredNames = pluginNamesByStatus(in: config)
        let enabled = configuredNames.enabled
            .map { ConfiguredPlugin(name: $0, status: "Enabled") }
        let disabled = configuredNames.disabled
            .map { ConfiguredPlugin(name: $0, status: "Disabled") }

        var seen: Set<String> = []
        return (enabled + disabled).filter { plugin in
            seen.insert(plugin.name).inserted
        }
    }

    static func pluginNamesByStatus(in config: String) -> (enabled: [String], disabled: [String]) {
        (
            pluginNames(in: block(named: "enabled", under: "plugins", in: config)),
            pluginNames(in: block(named: "disabled", under: "plugins", in: config))
        )
    }

    private static func pluginNames(in block: String?) -> [String] {
        guard let block else { return [] }
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "[]" { return [] }
        return block.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { return nil }
            return String(trimmed.dropFirst(2)).pluginCleanedYAMLValue.pluginTextValue
        }
    }

    private static func block(named name: String, under parent: String, in yaml: String) -> String? {
        let lines = yaml.components(separatedBy: .newlines)
        guard let parentIndex = lines.firstIndex(where: { $0 == "\(parent):" }) else { return nil }
        guard let start = lines.dropFirst(parentIndex + 1).firstIndex(where: { line in
            line == "  \(name):" || line.hasPrefix("  \(name): ")
        }) else {
            return nil
        }

        let parts = lines[start].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let inlineValue = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if !inlineValue.isEmpty {
                return inlineValue
            }
        }

        var blockLines: [String] = []
        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("  "), trimmed.hasPrefix("- ") {
                blockLines.append(line)
                continue
            }
            if !trimmed.isEmpty {
                break
            }
            blockLines.append(line)
        }
        return blockLines.joined(separator: "\n")
    }

    struct ConfiguredPlugin: Hashable, Sendable {
        var name: String
        var status: String
    }
}
