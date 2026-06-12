import SwiftUI

/// Status cards under the bubble that triggered a hand-off: a waiting row
/// (with a spinner) per routed target, flipped to an expandable replied row —
/// or a failed row — as results land. Collapsed by default.
struct AgentHandoffStatusView: View {
    let items: [AgentHandoffItem]
    @State private var expandedIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                switch item.phase {
                case .waiting:
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Waiting for \(item.targetName)…")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    }
                    .foregroundStyle(.blue)
                case .replied(let reply):
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            withAnimation(.smooth(duration: 0.15)) {
                                if expandedIDs.contains(item.id) {
                                    expandedIDs.remove(item.id)
                                } else {
                                    expandedIDs.insert(item.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("\(item.targetName) replied")
                                    .font(.system(size: 14, weight: .semibold))
                                    .lineLimit(1)
                                Image(systemName: expandedIDs.contains(item.id) ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.blue)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if expandedIDs.contains(item.id) {
                            MarkdownView(reply)
                                .padding(10)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(.quaternary)
                                }
                        }
                    }
                case .failed:
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(item.targetName) did not reply")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.2))
        }
    }
}
