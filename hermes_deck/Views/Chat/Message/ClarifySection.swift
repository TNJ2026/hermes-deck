import SwiftUI

struct ClarifySection: View {
    let clarifications: [ClarificationRequest]
    var onAnswer: ((ClarificationRequest, String) -> Void)?

    var body: some View {
        ProcessSection(
            dotColor: .orange
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Clarify")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(tokenEstimate(forCharacters: characterCount))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
        } content: {
            ForEach(clarifications) { clarification in
                VStack(alignment: .leading, spacing: 6) {
                    ProcessTreeRow {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Circle()
                                .fill(.orange)
                                .frame(width: 6, height: 6)
                                .padding(.trailing, 2)
                            Text(clarification.question)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !clarification.choices.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(clarification.choices, id: \.self) { choice in
                                Button {
                                    onAnswer?(clarification, choice)
                                } label: {
                                    Text(choice)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .disabled(onAnswer == nil)
                            }
                        }
                        .padding(.leading, 18)
                    }
                }
            }
        }
    }

    private var characterCount: Int {
        clarifications.reduce(0) { total, item in
            total + item.question.count + item.choices.reduce(0) { $0 + $1.count }
        }
    }
}
