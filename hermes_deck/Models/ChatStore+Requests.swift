import Foundation
import UniformTypeIdentifiers

/// Per-thread interaction state: attachments, permission requests, and
/// clarification requests (each with a main-chat and per-agent-thread track).
extension ChatStore {
    func sendState(forAgentThreadID threadID: UUID?) -> ChatSendState {
        guard let threadID else { return .idle }
        return agentSendStates[threadID] ?? .idle
    }

    func pendingAttachments(forAgentThreadID threadID: UUID?) -> [Attachment] {
        guard let threadID else { return [] }
        return agentPendingAttachments[threadID] ?? []
    }

    func pendingPermissionRequest(forAgentThreadID threadID: UUID?) -> PermissionRequest? {
        guard let threadID else { return nil }
        return agentPendingPermissionRequests[threadID]
    }

    func pendingClarificationRequest(forAgentThreadID threadID: UUID?) -> ClarificationRequest? {
        guard let threadID else { return nil }
        return agentPendingClarificationRequests[threadID]
    }

    func sessionInfo(forAgentThreadID threadID: UUID?) -> HermesSessionInfo {
        guard let threadID else { return HermesSessionInfo() }
        return agentSessionInfos[threadID] ?? HermesSessionInfo()
    }

    func attach(urls: [URL]) {
        let attachments = urls.map { url in
            Attachment(name: url.lastPathComponent, url: url, contentType: UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier)
        }
        pendingAttachments.append(contentsOf: attachments)
    }

    func addAttachments(_ attachments: [Attachment], to threadID: UUID? = nil) {
        if let threadID {
            agentPendingAttachments[threadID, default: []].append(contentsOf: attachments)
        } else {
            pendingAttachments.append(contentsOf: attachments)
        }
    }

    func attach(urls: [URL], toAgentThreadID threadID: UUID?) {
        guard let threadID else { return }
        let attachments = urls.map { url in
            Attachment(name: url.lastPathComponent, url: url, contentType: UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier)
        }
        agentPendingAttachments[threadID, default: []].append(contentsOf: attachments)
    }

    func removeAttachment(_ attachment: Attachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    func removeAttachment(_ attachment: Attachment, fromAgentThreadID threadID: UUID?) {
        guard let threadID else { return }
        agentPendingAttachments[threadID]?.removeAll { $0.id == attachment.id }
    }

    func dismissPermissionRequest() {
        cancelPermission(pendingPermissionRequest)
        pendingPermissionRequest = nil
    }

    func dismissPermissionRequest(forAgentThreadID threadID: UUID?) {
        guard let threadID else { return }
        cancelPermission(agentPendingPermissionRequests[threadID])
        agentPendingPermissionRequests[threadID] = nil
    }

    func answerPermission(at index: Int) {
        guard pendingPermissionRequest?.isAnswerable == true else { return }
        respondToPermission(pendingPermissionRequest, at: index)
        pendingPermissionRequest = nil
    }

    func answerPermission(at index: Int, forAgentThreadID threadID: UUID?) {
        guard let threadID, agentPendingPermissionRequests[threadID]?.isAnswerable == true else { return }
        respondToPermission(agentPendingPermissionRequests[threadID], at: index)
        agentPendingPermissionRequests[threadID] = nil
    }

    private func respondToPermission(_ request: PermissionRequest?, at index: Int) {
        guard let request, let requestID = request.requestID, request.options.indices.contains(index) else { return }
        let optionID = request.options[index].id
        let client = agentClient
        Task { await client.respondToPermission(requestID: requestID, optionID: optionID) }
    }

    private func cancelPermission(_ request: PermissionRequest?) {
        guard let request, let requestID = request.requestID else {
            return
        }
        let client = agentClient
        Task { await client.respondToPermission(requestID: requestID, optionID: request.cancelOptionID) }
    }

    func dismissClarificationRequest() {
        pendingClarificationRequest = nil
    }

    func dismissClarificationRequest(forAgentThreadID threadID: UUID?) {
        guard let threadID else { return }
        agentPendingClarificationRequests[threadID] = nil
    }

    func answerClarificationRequest(_ request: ClarificationRequest?, answer: String, forAgentThreadID threadID: UUID?) {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        if let requestID = request?.requestID?.trimmingCharacters(in: .whitespacesAndNewlines), !requestID.isEmpty {
            let client = agentClient
            Task { await client.respondToClarification(requestID: requestID, answer: answer) }
        } else {
            if let threadID {
                if let thread = threads.first(where: { $0.id == threadID }) {
                    Task {
                        await sendAgentProfile(answer, in: threadID, profile: thread.profile)
                    }
                }
            } else {
                Task {
                    await send(answer)
                }
            }
        }
        if let threadID {
            dismissClarificationRequest(forAgentThreadID: threadID)
        } else {
            dismissClarificationRequest()
        }
    }

#if DEBUG
    func simulatePermissionRequest() {
        guard let selectedThreadID else { return }
        showPermissionRequest("Allow simulated shell command?", options: Self.simulatedOptions, requestID: nil, for: selectedThreadID, usesGlobalSendState: true)
    }

    func simulatePermissionRequest(forAgentThreadID threadID: UUID?) {
        guard let threadID else { return }
        showPermissionRequest("Allow simulated shell command?", options: Self.simulatedOptions, requestID: nil, for: threadID, usesGlobalSendState: false)
    }

    private static let simulatedOptions = ["Yes", "No", "Always allow"].map { PermissionOption(id: $0, label: $0) }
#endif

    func clearPermissionRequest(for threadID: UUID, usesGlobalSendState: Bool) {
        if usesGlobalSendState {
            pendingPermissionRequest = nil
        } else {
            agentPendingPermissionRequests[threadID] = nil
        }
    }

    func clearClarificationRequest(for threadID: UUID, usesGlobalSendState: Bool) {
        if usesGlobalSendState {
            pendingClarificationRequest = nil
        } else {
            agentPendingClarificationRequests[threadID] = nil
        }
    }

    func showPermissionRequest(_ text: String, options: [PermissionOption], requestID: String?, for threadID: UUID, usesGlobalSendState: Bool) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOptions = options
            .map { PermissionOption(id: $0.id, label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.label.isEmpty }
        let fallback = [PermissionOption(id: "yes", label: "Yes"), PermissionOption(id: "no", label: "No")]
        let request = PermissionRequest(
            message: message.isEmpty ? "Permission requested." : message,
            options: normalizedOptions.isEmpty ? fallback : normalizedOptions,
            requestID: requestID
        )
        if usesGlobalSendState {
            pendingPermissionRequest = request
        } else {
            agentPendingPermissionRequests[threadID] = request
        }
    }

    func showClarificationRequest(_ request: ClarificationRequest, for threadID: UUID, usesGlobalSendState: Bool) {
        let normalizedQuestion = request.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedChoices = request.choices
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let clarification = ClarificationRequest(
            question: normalizedQuestion.isEmpty ? "Hermes needs more information." : normalizedQuestion,
            choices: normalizedChoices,
            requestID: request.requestID
        )
        if usesGlobalSendState {
            pendingClarificationRequest = clarification
        } else {
            agentPendingClarificationRequests[threadID] = clarification
        }
    }
}
