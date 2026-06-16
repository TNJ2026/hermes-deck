import SwiftUI
import AppKit

extension View {
    @ViewBuilder
    func composerSurface(presentation: ComposerPresentation, cornerRadius: CGFloat, border: Color) -> some View {
        switch presentation {
        case .floating:
            composerGlassSurface(cornerRadius: cornerRadius, border: border)
        case .inline:
            inlineComposerSurface(cornerRadius: cornerRadius, border: border)
        }
    }

    private func composerGlassSurface(cornerRadius: CGFloat, border: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return self
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay {
                shape.stroke(border)
            }
            .shadow(color: .black.opacity(0.1), radius: 14, x: 0, y: 6)
    }

    private func inlineComposerSurface(cornerRadius: CGFloat, border: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return self
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay {
                shape.stroke(border)
            }
    }
}

extension View {
    func pointingHandCursor(_ isEnabled: Bool = true) -> some View {
        self.onHover { isInside in
            guard isEnabled else { return }
            if isInside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

struct ComposerAttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(iconBackground)
                Image(systemName: iconName)
                    .font(.caption)
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)

            Text(attachment.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 32)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
    }

    private var iconName: String {
        attachment.contentType.hasPrefix("image") ? "photo" : "doc"
    }

    private var iconBackground: LinearGradient {
        LinearGradient(
            colors: [.accentColor, .accentColor.opacity(0.55)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct ComposerIconButton: View {
    @Environment(\.isEnabled) private var isEnabled

    let systemImage: String
    let accessibilityLabel: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .pointingHandCursor(isEnabled)
    }
}
