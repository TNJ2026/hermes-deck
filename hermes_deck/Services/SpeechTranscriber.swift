import AppKit
import AVFoundation
import CoreMedia
import Foundation
import Observation
import os
@preconcurrency import Speech

/// User-selectable dictation language. An empty stored identifier means "follow
/// the system locale". Persisted in `UserDefaults` so the Settings UI
/// (`@AppStorage`) and the transcriber read the exact same value.
enum SpeechLanguageSettings {
    static let localeIdentifierKey = "speechRecognitionLocaleIdentifier"

    /// Locales the speech recognizer supports, sorted by localized display name.
    static var supportedLocaleIdentifiers: [String] {
        SFSpeechRecognizer.supportedLocales()
            .map(\.identifier)
            .sorted { displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending }
    }

    static func displayName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Recognizer locale from the stored preference, falling back to the system
    /// locale when unset or no longer supported.
    static func resolvedLocale() -> Locale {
        let stored = UserDefaults.standard.string(forKey: localeIdentifierKey) ?? ""
        guard !stored.isEmpty,
              SFSpeechRecognizer.supportedLocales().map(\.identifier).contains(stored) else {
            return .current
        }
        return Locale(identifier: stored)
    }
}

/// Ensures only one composer records at a time. The active recorder claims the
/// lock; every other transcriber reports `isLockedOut` so its mic disables.
@MainActor
@Observable
final class VoiceInputCoordinator {
    static let shared = VoiceInputCoordinator()
    private(set) var activeOwner: UUID?

    private init() {}

    /// Claims the lock for `id`. Returns false if another owner holds it.
    @discardableResult
    func begin(_ id: UUID) -> Bool {
        if activeOwner == nil || activeOwner == id {
            activeOwner = id
            return true
        }
        return false
    }

    func end(_ id: UUID) {
        if activeOwner == id { activeOwner = nil }
    }

    func isLockedOut(_ id: UUID) -> Bool {
        activeOwner != nil && activeOwner != id
    }
}

@MainActor
@Observable
final class SpeechTranscriber {
    nonisolated private static let logger = Logger(subsystem: "ai.tnj.deck", category: "SpeechTranscriber")

    enum State: Equatable {
        case idle
        case requestingPermission
        case recording
        case unavailable(String)
        case failed(String)
    }

    /// Identity for the single-recorder lock (see `VoiceInputCoordinator`).
    nonisolated let id = UUID()

    /// Which Privacy settings pane to deep-link from the next denied-permission
    /// toast. Consumed (and cleared) by `state`'s `didSet`.
    @ObservationIgnored private var pendingSettingsPane: SettingsPane?

    var state: State = .idle {
        didSet {
            switch state {
            case .recording:
                VoiceInputCoordinator.shared.begin(id)
            case .idle:
                VoiceInputCoordinator.shared.end(id)
            case .failed(let message), .unavailable(let message):
                VoiceInputCoordinator.shared.end(id)
                // Surface voice-input failures as a top-center toast instead of
                // text under the composer. Denied permissions also offer a
                // shortcut into the relevant Privacy settings pane, since macOS
                // never re-prompts once the user has denied access.
                let pane = pendingSettingsPane
                pendingSettingsPane = nil
                let action = pane.map { pane in
                    ToastAction(label: "Open Settings") { SpeechTranscriber.openSettings(pane) }
                }
                ToastCenter.shared.show(message, action: action)
            case .requestingPermission:
                break
            }
        }
    }
    var transcript = ""

    /// True when another composer holds the recording lock; the mic should be
    /// disabled to keep recording exclusive.
    var isLockedOut: Bool {
        VoiceInputCoordinator.shared.isLockedOut(id)
    }

    /// Number of bars in the live recording waveform.
    static let waveformBarCount = 64
    /// Rolling normalized input levels (oldest first), driving the waveform.
    private(set) var audioLevels = [Float](repeating: 0, count: SpeechTranscriber.waveformBarCount)

    private let capture = AudioCaptureController()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var userInitiatedStop = false
    private var currentTaskToken: UInt64 = 0

    init() {
        capture.onRuntimeError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Self.logger.warning("Capture session runtime error during recording: \(message, privacy: .public)")
                if self.isRecording {
                    self.finishRecording(cancelTask: true)
                    self.state = .failed(message)
                }
            }
        }
        capture.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.pushAudioLevel(level)
            }
        }
    }

    private func pushAudioLevel(_ level: Float) {
        guard isRecording else { return }
        audioLevels.removeFirst()
        audioLevels.append(level)
    }

    private func resetAudioLevels() {
        audioLevels = [Float](repeating: 0, count: Self.waveformBarCount)
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var helpText: String {
        switch state {
        case .idle:
            "Start voice input"
        case .requestingPermission:
            "Requesting voice input permission"
        case .recording:
            "Stop voice input"
        case .unavailable(let message), .failed(let message):
            message
        }
    }

    func startRecording() async {
        Self.logger.info("startRecording requested. state=\(String(describing: self.state), privacy: .public)")
        // Guard against re-entrancy when already requesting permission or recording
        guard state != .requestingPermission && state != .recording else { return }
        // Enforce a single active recorder across composers. Claim the lock now —
        // before any `await` — so a second composer can't slip through the
        // `isLockedOut` check while this one is suspended on the permission prompts.
        // Every failure path below transitions to `.unavailable`/`.failed`/`.idle`,
        // whose `state` didSet releases the lock again.
        guard VoiceInputCoordinator.shared.begin(id) else {
            Self.logger.info("Voice input is locked out by another composer.")
            return
        }
        userInitiatedStop = false
        finishRecording(cancelTask: true)
        transcript = ""
        state = .requestingPermission

        if let missingUsageDescriptionKey {
            Self.logger.error("Missing Info.plist key: \(missingUsageDescriptionKey, privacy: .public)")
            state = .unavailable("Missing \(missingUsageDescriptionKey) in Info.plist.")
            return
        }

        // Resolve the dictation locale from Settings (empty = follow the system
        // locale), instantiating per-recording so a language change there takes
        // effect on the next recording.
        let locale = SpeechLanguageSettings.resolvedLocale()
        guard let speechRecognizer = SFSpeechRecognizer(locale: locale) else {
            Self.logger.error("SFSpeechRecognizer unavailable for locale \(locale.identifier, privacy: .public).")
            state = .unavailable("Speech recognition is not available for the selected language.")
            return
        }

        let currentSpeechStatus = SFSpeechRecognizer.authorizationStatus()
        Self.logger.info("Current speech recognition authorization status: \(String(describing: currentSpeechStatus), privacy: .public)")
        let speechStatus = await speechAuthorizationStatus(from: currentSpeechStatus)
        Self.logger.info("Speech recognition authorization status: \(String(describing: speechStatus), privacy: .public)")
        guard speechStatus == .authorized else {
            if speechStatus == .denied || speechStatus == .restricted {
                pendingSettingsPane = .speechRecognition
            }
            state = .unavailable(speechAuthorizationMessage(for: speechStatus))
            return
        }

        let currentMicrophoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Self.logger.info("Current microphone authorization status: \(String(describing: currentMicrophoneStatus), privacy: .public)")
        let microphoneAllowed = await microphoneAuthorizationAllowed(from: currentMicrophoneStatus)
        Self.logger.info("Microphone authorization allowed=\(microphoneAllowed, privacy: .public)")
        guard microphoneAllowed else {
            pendingSettingsPane = .microphone
            state = .unavailable("Microphone permission was denied.")
            return
        }

        // Bail out cleanly when there is no input device — configuring an
        // AVCaptureSession with no microphone can raise an uncatchable Obj-C
        // exception and crash, so never reach session setup in that case.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            Self.logger.error("No microphone device available.")
            state = .unavailable("No microphone is available.")
            return
        }

        guard speechRecognizer.isAvailable else {
            Self.logger.error("Speech recognizer exists but is currently unavailable.")
            state = .unavailable("Speech recognizer is currently unavailable.")
            return
        }

        do {
            Self.logger.info("Beginning live speech recognition.")
            resetAudioLevels()
            try await beginRecognition(with: speechRecognizer)
            state = .recording
            Self.logger.info("Speech recording started.")
        } catch {
            finishRecording(cancelTask: true)
            Self.logger.error("Failed to start speech recognition: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func stopRecording() {
        Self.logger.info("stopRecording requested by user/UI.")
        guard recognitionTask != nil else {
            finishRecording(cancelTask: true)
            return
        }
        // Graceful stop: keep the task and wait for the isFinal callback so
        // the trailing audio's recognition result isn't lost.
        userInitiatedStop = true
        capture.stop()
        recognitionRequest?.endAudio()
        Self.logger.info("Audio input ended; awaiting final recognition result.")

        // Fallback timer to force-finish if the final callback doesn't arrive within 3 seconds.
        let token = currentTaskToken
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            if self.currentTaskToken == token && self.userInitiatedStop {
                Self.logger.info("Graceful stop timed out; force-finishing.")
                self.finishRecording(cancelTask: true)
            }
        }
    }

    private func finishRecording(cancelTask: Bool) {
        Self.logger.info("finishRecording cancelTask=\(cancelTask, privacy: .public)")
        capture.stop()
        recognitionRequest?.endAudio()

        // Always increment the token to invalidate any further callbacks from the current task.
        currentTaskToken &+= 1

        if cancelTask {
            recognitionTask?.cancel()
            Self.logger.info("Recognition task canceled.")
        }
        recognitionRequest = nil
        recognitionTask = nil
        resetAudioLevels()

        if isRecording || state == .requestingPermission {
            state = .idle
            Self.logger.info("Speech state reset to idle.")
        }
    }

    private func beginRecognition(with speechRecognizer: SFSpeechRecognizer) async throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        currentTaskToken &+= 1
        let token = currentTaskToken
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription

            Self.logger.info("Recognition callback received. hasText=\((text != nil), privacy: .public) isFinal=\(isFinal, privacy: .public) hasError=\((errorMessage != nil), privacy: .public)")
            DispatchQueue.main.async {
                guard let self, self.currentTaskToken == token else {
                    Self.logger.info("Ignoring stale recognition callback.")
                    return
                }
                self.handleRecognitionUpdate(text: text, errorMessage: errorMessage, isFinal: isFinal)
            }
        }

        // Drive recognition from an AVCaptureSession audio data output — more
        // robust than AVAudioEngine on sandboxed macOS, where the engine's input
        // tap can hit kAudioUnitErr_InvalidElement (-10877) and a device switch
        // tears the whole engine down. The session converts each capture sample
        // buffer to a PCM buffer and appends it to the recognition request.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            capture.start(appendingTo: request) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func handleRecognitionUpdate(text: String?, errorMessage: String?, isFinal: Bool) {
        if let text {
            transcript = text
            Self.logger.info("Transcript updated. characterCount=\(text.count, privacy: .public)")
        }
        if let errorMessage {
            if userInitiatedStop {
                Self.logger.info("Ignoring recognition error during user-initiated stop: \(errorMessage, privacy: .public)")
                userInitiatedStop = false
                finishRecording(cancelTask: false)
            } else {
                Self.logger.error("Recognition callback error: \(errorMessage, privacy: .public)")
                finishRecording(cancelTask: false)
                state = .failed(errorMessage)
            }
        } else if isFinal {
            Self.logger.info("Recognition callback final result.")
            userInitiatedStop = false
            finishRecording(cancelTask: false)
        }
    }

    private func speechAuthorizationStatus(from currentStatus: SFSpeechRecognizerAuthorizationStatus) async -> SFSpeechRecognizerAuthorizationStatus {
        guard currentStatus == .notDetermined else { return currentStatus }
        Self.logger.info("Requesting speech recognition authorization.")

        let stream = AsyncStream<SFSpeechRecognizerAuthorizationStatus> { continuation in
            Self.logger.info("Speech recognition authorization request AsyncStream1")
            let timeout = Task {
                try? await Task.sleep(for: .seconds(120))
                continuation.yield(.denied)
                continuation.finish()
            }
            continuation.onTermination = { _ in timeout.cancel() }
            Self.logger.info("Speech recognition authorization request AsyncStream2")
            SFSpeechRecognizer.requestAuthorization { status in
                Self.logger.info("Speech recognition authorization request completed: \(String(describing: status), privacy: .public).")
                DispatchQueue.main.async {
                    continuation.yield(status)
                    continuation.finish()
                }
            }
        }
        Self.logger.info("Speech recognition authorization request AsyncStream3")
        for await status in stream {
            return status
        }
        Self.logger.info("Speech recognition authorization request AsyncStream4")
        return .denied
    }


    private func microphoneAuthorizationAllowed(from currentStatus: AVAuthorizationStatus) async -> Bool {
        switch currentStatus {
        case .authorized:
            return true
        case .notDetermined:
            Self.logger.info("Requesting microphone authorization.")
            return await requestMicrophoneAuthorization()
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        let stream = AsyncStream<Bool> { continuation in
            // Safety net mirroring `requestSpeechAuthorization`: never hang in
            // `.requestingPermission` if the system callback goes missing.
            let timeout = Task {
                try? await Task.sleep(for: .seconds(120))
                continuation.yield(false)
                continuation.finish()
            }
            continuation.onTermination = { _ in timeout.cancel() }
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                DispatchQueue.main.async {
                    continuation.yield(allowed)
                    continuation.finish()
                }
            }
        }
        var allowed = false
        for await val in stream {
            allowed = val
            break
        }
        return allowed
    }

    private func speechAuthorizationMessage(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            "Speech recognition permission has not been requested."
        case .denied:
            "Speech recognition permission was denied."
        case .restricted:
            "Speech recognition is restricted on this Mac."
        case .authorized:
            "Speech recognition is authorized."
        @unknown default:
            "Speech recognition authorization status is unknown."
        }
    }

    /// A macOS Privacy & Security settings pane reachable via deep link.
    private enum SettingsPane {
        case microphone
        case speechRecognition

        var url: URL? {
            switch self {
            case .microphone:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .speechRecognition:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            }
        }
    }

    /// Opens the relevant Privacy settings pane so the user can re-enable a
    /// permission macOS will no longer prompt for.
    private static func openSettings(_ pane: SettingsPane) {
        guard let url = pane.url else { return }
        NSWorkspace.shared.open(url)
    }

    private var missingUsageDescriptionKey: String? {
        let bundle = Bundle.main
        if bundle.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") == nil {
            return "NSSpeechRecognitionUsageDescription"
        }
        if bundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") == nil {
            return "NSMicrophoneUsageDescription"
        }
        return nil
    }
}

/// Captures microphone audio with an `AVCaptureSession` and forwards each sample
/// buffer (converted to an `AVAudioPCMBuffer`) to a speech recognition request.
/// All session work runs on a dedicated serial queue; sample buffers are
/// delivered on the same queue.
private final class AudioCaptureController: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    nonisolated private static let logger = Logger(subsystem: "ai.tnj.deck", category: "AudioCaptureController")

    /// Invoked (off the main thread) when the running session hits a runtime
    /// error — e.g. the active microphone is unplugged mid-recording.
    var onRuntimeError: ((String) -> Void)?

    /// Per-buffer normalized input level (0…1), for a live waveform. Called off
    /// the main thread on the capture queue.
    var onLevel: ((Float) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "ai.tnj.deck.speech.capture")
    private weak var request: SFSpeechAudioBufferRecognitionRequest?
    private var runtimeErrorObserver: NSObjectProtocol?

    override init() {
        super.init()
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                ?? "The microphone session stopped unexpectedly."
            self?.onRuntimeError?(message)
        }
    }

    deinit {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
    }

    func start(appendingTo request: SFSpeechAudioBufferRecognitionRequest, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            self.request = request
            do {
                try configureLocked()
                session.startRunning()
                Self.logger.info("Capture session started.")
                completion(.success(()))
            } catch {
                Self.logger.error("Capture session start failed: \(error.localizedDescription, privacy: .public)")
                completion(.failure(error))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            request = nil
            if session.isRunning {
                session.stopRunning()
                Self.logger.info("Capture session stopped.")
            }
        }
    }

    private func configureLocked() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs { session.removeInput(input) }
        for existing in session.outputs { session.removeOutput(existing) }

        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw Self.error("No microphone is available.")
        }
        let input = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(input) else {
            throw Self.error("Could not attach the microphone input.")
        }
        session.addInput(input)

        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw Self.error("Could not attach the audio output.")
        }
        session.addOutput(output)
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let request, let buffer = Self.makePCMBuffer(from: sampleBuffer) else { return }
        request.append(buffer)
        if let onLevel {
            onLevel(Self.normalizedLevel(of: buffer))
        }
    }

    /// RMS of the buffer mapped to 0…1 via a -50…0 dBFS window, for display.
    private static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let channels = Int(buffer.format.channelCount)
        var sumSquares: Float = 0
        var sampleCount = 0

        if let floatData = buffer.floatChannelData {
            for channel in 0..<channels {
                let samples = floatData[channel]
                for index in 0..<frames {
                    let value = samples[index]
                    sumSquares += value * value
                }
                sampleCount += frames
            }
        } else if let int16Data = buffer.int16ChannelData {
            for channel in 0..<channels {
                let samples = int16Data[channel]
                for index in 0..<frames {
                    let value = Float(samples[index]) / 32_768
                    sumSquares += value * value
                }
                sampleCount += frames
            }
        } else if let int32Data = buffer.int32ChannelData {
            for channel in 0..<channels {
                let samples = int32Data[channel]
                for index in 0..<frames {
                    let value = Float(samples[index]) / 2_147_483_648
                    sumSquares += value * value
                }
                sampleCount += frames
            }
        } else {
            return 0
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sumSquares / Float(sampleCount))
        let decibels = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (decibels + 50) / 50))
    }

    /// Wraps an audio `CMSampleBuffer`'s PCM data in an `AVAudioPCMBuffer` using
    /// the buffer's own stream format, ready to hand to the recognition request.
    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        guard let format = AVAudioFormat(streamDescription: streamDescription) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "SpeechTranscriber", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
