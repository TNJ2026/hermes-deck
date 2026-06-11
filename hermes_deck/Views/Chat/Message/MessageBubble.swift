import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    /// Minimum gap between an assistant bubble and the trailing edge. Defaults
    /// to the wide main-chat column; the narrow right-sidebar panels pass a
    /// tighter value so replies get more width. User bubbles are unaffected.
    var assistantTrailingInset: CGFloat = 80

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 8) {
                if !message.segments.isEmpty {
                    SegmentTimeline(segments: message.segments)
                }
                if hasMessageCard {
                    VStack(alignment: .leading, spacing: 8) {
                        if !message.content.isEmpty {
                            if let routedSourceProfileName = message.routedSourceProfileName {
                                RoutedUserPromptContent(
                                    sourceProfileName: routedSourceProfileName,
                                    prompt: message.content
                                )
                            } else if message.role == .assistant,
                                      let replyName = message.agentReplyName {
                                ExternalAgentReplyContent(attribution: ExternalAgentReplyAttribution(
                                    source: ExternalAgentReplySource.parse(displayName: replyName),
                                    displayName: replyName,
                                    body: message.content
                                ))
                            } else if message.role == .assistant,
                                      let attribution = ExternalAgentReplyAttribution.parse(message.content) {
                                ExternalAgentReplyContent(attribution: attribution)
                            } else if shouldRenderMarkdown {
                                // User prompts and completed assistant replies both
                                // render as Markdown.
                                MarkdownView(message.content)
                            } else {
                                Text(message.content)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !message.attachments.isEmpty {
                            AttachmentStrip(attachments: message.attachments)
                        }
                    }
                    .padding(14)
                    .background {
                        if message.role == .user {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.06))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.quaternary)
                    }
                }
            }
            if message.role != .user { Spacer(minLength: assistantTrailingInset) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var hasMessageCard: Bool {
        !message.content.isEmpty || !message.attachments.isEmpty
    }

    private var shouldRenderMarkdown: Bool {
        message.role != .assistant || message.completedAt != nil
    }
}

struct ExternalAgentReplyContent: View {
    let attribution: ExternalAgentReplyAttribution

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(attribution.displayName):")
                .font(.body.weight(.semibold))
                .foregroundStyle(sourceColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(sourceColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)

            MarkdownView(attribution.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceColor: Color {
        ExternalAgentAppearance.color(for: attribution.source)
    }
}

enum ExternalAgentAppearance {
    /// `nil` source (a Hermes profile reply) falls back to the accent color.
    static func color(for source: ExternalAgentReplySource?) -> Color {
        guard let source else { return .accentColor }
        return color(for: source)
    }

    static func color(for source: ExternalAgentReplySource) -> Color {
        switch source {
        case .claude:
            Color(red: 217 / 255, green: 119 / 255, blue: 86 / 255)
        case .codex:
            Color(red: 130 / 255, green: 163 / 255, blue: 255 / 255)
        case .gemini:
            Color(red: 150 / 255, green: 100 / 255, blue: 160 / 255)
        }
    }

    static func source(for backend: AgentBackend) -> ExternalAgentReplySource? {
        switch backend {
        case .acp(.codex):
            .codex
        case .claudeCLI:
            .claude
        case .agy:
            .gemini
        case .hermes:
            nil
        }
    }

    static func color(for backend: AgentBackend) -> Color {
        guard let source = source(for: backend) else { return .accentColor }
        return color(for: source)
    }
}

struct RoutedUserPromptContent: View {
    let sourceProfileName: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(sourceProfileName)@You:")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.blue)
                .lineLimit(1)

            Text(prompt)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AttachmentStrip: View {
    let attachments: [Attachment]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(attachments) { attachment in
                Label(attachment.name, systemImage: "paperclip")
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
