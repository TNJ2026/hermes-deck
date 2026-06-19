import SwiftUI

struct ThinkingIndicatorRow: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(.purple)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 0.3 : 1)
            Text("Thinking…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

func abbreviatedDuration(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(0, Int(seconds))
    if totalSeconds < 60 { return "\(totalSeconds)s" }
    let minutes = totalSeconds / 60
    let secs = totalSeconds % 60
    if minutes < 60 {
        return secs == 0 ? "\(minutes)m" : "\(minutes)m\(secs)s"
    }
    let hours = minutes / 60
    let mins = minutes % 60
    return mins == 0 ? "\(hours)h" : "\(hours)h\(mins)m"
}

struct SegmentTimeline: View {
    let segments: [AssistantSegment]
    var onClarificationAnswer: ((ClarificationRequest, String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(groupedSegments().enumerated()), id: \.offset) { _, group in
                switch group {
                case .thinking(let segment):
                    ThinkingRow(segment: segment)
                case .tools(let events):
                    ToolCallSection(events: events)
                case .clarifications(let items):
                    ClarifySection(clarifications: items, onAnswer: onClarificationAnswer)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupedSegments() -> [SegmentGroup] {
        var groups: [SegmentGroup] = []
        for segment in segments {
            switch segment {
            case .thinking(let item):
                groups.append(.thinking(item))
            case .tool(let event):
                if case .tools(var existing) = groups.last {
                    existing.append(event)
                    groups[groups.count - 1] = .tools(existing)
                } else {
                    groups.append(.tools([event]))
                }
            case .clarify(let item):
                if case .clarifications(var existing) = groups.last {
                    existing.append(item)
                    groups[groups.count - 1] = .clarifications(existing)
                } else {
                    groups.append(.clarifications([item]))
                }
            }
        }
        return groups
    }
}

enum SegmentGroup {
    case thinking(ThinkingSegment)
    case tools([ToolCallEvent])
    case clarifications([ClarificationRequest])
}

func tokenEstimate(forCharacters count: Int) -> String {
    let tokens = max(1, count / 4)
    let formatted: String
    if tokens >= 1000 {
        let thousands = Double(tokens) / 1000
        formatted = thousands >= 10
            ? "\(Int(thousands.rounded()))K"
            : String(format: "%.1fK", thousands)
    } else {
        formatted = "\(tokens)"
    }
    return "~\(formatted) tokens"
}

struct ProcessSection<Title: View, Content: View>: View {
    let dotColor: Color
    @ViewBuilder var title: () -> Title
    @ViewBuilder var content: () -> Content
    @State private var isExpanded = false

    init(
        dotColor: Color,
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.dotColor = dotColor
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.smooth(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                        .padding(.trailing, 2)
                    Text(isExpanded ? "▾" : "▸")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 7, alignment: .leading)
                    title()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    content()
                }
                .padding(.leading, 22)
            }
        }
    }
}

struct ProcessTreeRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("└─")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

struct ThinkingRow: View {
    let segment: ThinkingSegment
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasReasoningContent {
                Button {
                    withAnimation(.smooth(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    summaryRow(showsDisclosure: true)
                }
                .buttonStyle(.plain)
            } else {
                summaryRow(showsDisclosure: false)
            }

            if isExpanded, hasReasoningContent {
                Text(reasoningContent)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary, lineWidth: 1)
                    }
                    .padding(.leading, 22)
            }
        }
    }

    private var reasoningContent: String {
        segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasReasoningContent: Bool {
        !reasoningContent.isEmpty
    }

    private func summaryRow(showsDisclosure: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(.purple)
                .frame(width: 6, height: 6)
                .padding(.trailing, 2)
            if showsDisclosure {
                Text(isExpanded ? "▾" : "▸")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 7, alignment: .leading)
            }
            thinkingTitleView
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            if !hasReasoningContent {
                Text("(⌐■_■) reasoning…")
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(tokenEstimate(forCharacters: segment.text.count))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .contentShape(Rectangle())
    }

    /// "Thought for 4.2s" once finalized; a live "Thinking 3s" timer while the
    /// model is still reasoning; plain "Thinking" when timing is unavailable.
    @ViewBuilder
    private var thinkingTitleView: some View {
        if let duration = segment.durationSeconds {
            Text("Thought for \(Self.durationLabel(duration))")
        } else if let startedAt = segment.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Thinking \(Self.durationLabel(context.date.timeIntervalSince(startedAt)))")
            }
        } else {
            Text("Thinking")
        }
    }

    static func durationLabel(_ seconds: Double) -> String {
        if seconds < 60 {
            return seconds < 10 ? String(format: "%.1fs", seconds) : "\(Int(seconds.rounded()))s"
        }
        let total = Int(seconds.rounded())
        return "\(total / 60)m \(total % 60)s"
    }
}
