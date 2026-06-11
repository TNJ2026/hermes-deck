import SwiftUI

/// The lower pane of a split Agents panel: a titled, profile-pickable agent chat.
/// Mutually exclusive with the top pane / left sidebar, so its picker only lists
/// the remaining profiles.
struct AgentSplitBottomPanel: View {
    @Bindable var store: ChatStore
    @Binding var profile: HermesProfile?
    @Binding var threadID: UUID?
    @Binding var draft: String
    @Binding var isFileImporterPresented: Bool
    let availableProfiles: [HermesProfile]
    let onFileImportRequested: (UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SidebarView.fixedTemplateImage("robot", size: 14)
                    .foregroundStyle(.secondary)
                Text(profile?.displayName ?? "")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .padding(.bottom, 6)

            ChatDetailView(
                store: store,
                draft: $draft,
                isFileImporterPresented: $isFileImporterPresented,
                composerPresentation: .inline,
                showsComposer: true,
                messageHorizontalInset: 8,
                assistantTrailingInset: 12,
                usesAgentsComposer: true,
                threadID: threadID,
                sendProfile: profile,
                sendState: store.sendState(forAgentThreadID: threadID),
                onFileImportRequested: onFileImportRequested
            )
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            // Forced single choice → no picker; multiple → floating picker in the
            // title bar's top-right corner.
            if availableProfiles.count >= 2 {
                Picker("Profile", selection: $profile) {
                    ForEach(availableProfiles) { candidate in
                        Text(candidate.displayName).lineLimit(1).tag(Optional(candidate))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 150)
                .onChange(of: profile) { _, newValue in
                    guard let newValue else { return }
                    threadID = store.threadIDForAgentProfile(newValue)
                }
                .padding(.top, 10)
            }
        }
    }
}
