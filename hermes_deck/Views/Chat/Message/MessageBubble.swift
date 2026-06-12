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
                            } else if message.role == .user,
                                      message.isAgentReplyFollowUp == true,
                                      let framed = AgentRepliedContent.parse(message.content) {
                                framed
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

/// The close-the-loop follow-up fed back to a source agent (`X replied:`
/// followed by the routed agent's reply). Only internally flagged messages use
/// this view; ordinary user prose is never parsed into this shape.
///
/// Renders as a one-line receipt — the full reply already lives in the routed
/// agent's own thread, so repeating it here only duplicates a wall of text.
struct AgentRepliedContent: View {
    let name: String
    let reply: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 11, weight: .semibold))
            Text("\(name) replied")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.blue)
    }

    /// Parses `<name> replied:\n\n<reply>`; the name must be a single line.
    static func parse(_ content: String) -> AgentRepliedContent? {
        let separator = " replied:\n\n"
        guard let separatorRange = content.range(of: separator) else { return nil }
        let name = String(content[..<separatorRange.lowerBound])
        guard !name.isEmpty, !name.contains("\n") else { return nil }
        let reply = String(content[separatorRange.upperBound...])
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AgentRepliedContent(name: name, reply: reply)
    }
}

struct RoutedUserPromptContent: View {
    let sourceProfileName: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(sourceProfileName)@You:")
                .font(.system(size: 14, weight: .semibold))
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
