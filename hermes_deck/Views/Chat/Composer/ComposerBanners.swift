import SwiftUI

struct PermissionRequestBanner: View {
    let request: PermissionRequest
    var onAnswer: (Int) -> Void = { _ in }
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: bannerIcon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(bannerTint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 8) {
                Text(bannerTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                // Long permission texts (full commands, diffs) scroll between
                // the title and the answer buttons instead of growing the
                // banner past the viewport; short ones keep their exact height.
                ViewThatFits(in: .vertical) {
                    messageText
                    ScrollView {
                        messageText
                    }
                }
                .frame(maxHeight: 200)

                if request.isAnswerable {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(request.choices.enumerated()), id: \.offset) { index, choice in
                            Button {
                                onAnswer(index)
                            } label: {
                                Text(optionTitle(index: index, choice: choice))
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(bannerTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(bannerTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(bannerTint.opacity(0.28))
        }
    }

    private var messageText: some View {
        Text(request.message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bannerTitle: String {
        request.isAnswerable ? "Permission request" : "Tool permission"
    }

    private var bannerIcon: String {
        request.isAnswerable ? "lock.shield" : "info.circle"
    }

    private var bannerTint: Color {
        request.isAnswerable ? .orange : .secondary
    }

    private func optionTitle(index: Int, choice: String) -> String {
        let normalizedChoice = choice.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = normalizedChoice.lowercased()
        if lowercased == "yes" || lowercased == "no" {
            return normalizedChoice
        }
        return "\(index + 1). \(normalizedChoice)"
    }
}

struct ClarificationRequestBanner: View {
    let request: ClarificationRequest
    let isSending: Bool
    let onAnswer: (String) -> Void
    let onDismiss: () -> Void
    @State private var freeformAnswer = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                // Long questions scroll between the title and the answer row
                // instead of growing the banner past the viewport; short ones
                // keep their exact height.
                ViewThatFits(in: .vertical) {
                    questionText
                    ScrollView {
                        questionText
                    }
                }
                .frame(maxHeight: 200)

                switch interactionKind {
                case .confirmation, .choice:
                    FlowLayout(spacing: 6) {
                        ForEach(Array(request.choices.enumerated()), id: \.offset) { index, choice in
                            Button {
                                onAnswer(choice)
                            } label: {
                                Text(optionTitle(index: index, choice: choice))
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                            .disabled(isSending)
                        }
                    }
                case .freeform:
                    HStack(spacing: 8) {
                        TextField("Type a reply...", text: $freeformAnswer, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...4)
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .onSubmit(submitFreeformAnswer)

                        Button("Send") {
                            submitFreeformAnswer()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(freeformAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.28))
        }
    }

    private var questionText: some View {
        Text(request.question)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var interactionKind: ClarificationInteractionKind {
        if request.choices.isEmpty {
            return .freeform
        }
        if request.choices.count == 2 {
            let normalized = Set(request.choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            if normalized == ["yes", "no"] || normalized == ["y", "n"] {
                return .confirmation
            }
        }
        return .choice
    }

    private var title: String {
        switch interactionKind {
        case .confirmation:
            "Confirmation needed"
        case .choice:
            "Choose an option"
        case .freeform:
            "Clarification needed"
        }
    }

    private var iconName: String {
        switch interactionKind {
        case .confirmation:
            "checkmark.circle"
        case .choice:
            "list.bullet.rectangle"
        case .freeform:
            "questionmark.bubble"
        }
    }

    private func optionTitle(index: Int, choice: String) -> String {
        if interactionKind == .confirmation {
            return choice
        }
        return "\(index + 1). \(choice)"
    }

    private func submitFreeformAnswer() {
        let answer = freeformAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        onAnswer(answer)
    }
}

enum ClarificationInteractionKind {
    case confirmation
    case choice
    case freeform
}
