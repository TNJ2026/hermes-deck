import SwiftUI

/// Equatable so rows can short-circuit via `.equatable()`: a streaming delta
/// mutates `store.threads` and invalidates every visible row in every chat
/// list — without the short-circuit, each token re-parses the Markdown of all
/// completed messages in both the main list and any open panel.
struct MessageBubble: View, Equatable {
    let message: ChatMessage
    /// Minimum gap between an assistant bubble and the trailing edge. Defaults
    /// to the wide main-chat column; the narrow right-sidebar panels pass a
    /// tighter value so replies get more width. User bubbles are unaffected.
    var assistantTrailingInset: CGFloat = 80
    var onClarificationAnswer: ((ClarificationRequest, String) -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 8) {
                if !message.segments.isEmpty {
                    SegmentTimeline(segments: message.segments, onClarificationAnswer: onClarificationAnswer)
                }
                if hasMessageCard {
                    VStack(alignment: .leading, spacing: 8) {
                        if !trimmedContent.isEmpty {
                            if let routedSourceProfileName = message.routedSourceProfileName {
                                RoutedUserPromptContent(
                                    sourceProfileName: routedSourceProfileName,
                                    prompt: trimmedContent
                                )
                            } else if message.role == .assistant,
                                      let replyName = message.agentReplyName {
                                ExternalAgentReplyContent(attribution: ExternalAgentReplyAttribution(
                                    source: ExternalAgentReplySource.parse(displayName: replyName),
                                    displayName: replyName,
                                    body: trimmedContent
                                ), isComplete: message.completedAt != nil)
                            } else if message.role == .assistant,
                                      let attribution = ExternalAgentReplyAttribution.parse(trimmedContent) {
                                ExternalAgentReplyContent(attribution: attribution, isComplete: message.completedAt != nil)
                            } else if message.role == .assistant {
                                StreamingMarkdownContent(source: trimmedContent, isComplete: message.completedAt != nil)
                            } else {
                                MarkdownView(trimmedContent)
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

    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.assistantTrailingInset == rhs.assistantTrailingInset
    }

    private var hasMessageCard: Bool {
        !trimmedContent.isEmpty || !message.attachments.isEmpty
    }

    /// Leading/trailing blank lines are display noise — trim them at render
    /// time only, leaving the stored message (and what the agent sees) intact.
    private var trimmedContent: String {
        message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

struct ExternalAgentReplyContent: View {
    let attribution: ExternalAgentReplyAttribution
    var isComplete = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(attribution.displayName):")
                .font(.body.weight(.semibold))
                .foregroundStyle(sourceColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(sourceColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)

            StreamingMarkdownContent(source: attribution.body, isComplete: isComplete)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceColor: Color {
        ExternalAgentAppearance.color(for: attribution.source)
    }
}

struct StreamingMarkdownContent: View {
    let source: String
    let isComplete: Bool

    @State private var renderedSource = ""

    var body: some View {
        Group {
            if isComplete {
                MarkdownView(source)
            } else if renderedSource == source {
                MarkdownView(renderedSource)
            } else if !renderedSource.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownView(renderedSource)
                    if !streamingTail.isEmpty {
                        Text(streamingTail)
                            .font(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(source)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: source) {
            guard !isComplete, !source.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            renderedSource = source
        }
    }

    private var streamingTail: String {
        guard source.hasPrefix(renderedSource) else { return source }
        return String(source.dropFirst(renderedSource.count))
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
