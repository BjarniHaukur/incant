import AppKit
import AVFoundation
import OSLog
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case listening
        case finishing
        case success
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var level: CGFloat = 0
    @Published var bufferedText = ""
    @Published private(set) var autoInsertEnabled = true
    @Published private(set) var orbMotion = SIMD2<Float>.zero
    @Published private(set) var orbMotionEnergy: Float = 0
    /// Rolled fresh for every session so no two dictations look alike. What the
    /// roll means to the fluid lives with the shader that consumes it.
    @Published private(set) var orbSeed = OrbSeed.random()
    @Published private(set) var shortcut = GlobalHotKey.Shortcut.load()
    @Published private(set) var shortcutError: String?
    @Published private(set) var recognitionPrompt = AppModel.loadRecognitionPrompt()
    @Published var apiKeyDraft = ""
    @Published private(set) var keySaved = false

    var showRecorder: (() -> Void)?
    var hideRecorder: (() -> Void)?
    var showSettings: (() -> Void)?
    var applyShortcut: ((GlobalHotKey.Shortcut) -> String?)?

    private let audio = AudioCapture()
    private let transcriber = RealtimeTranscriber()
    private let lidAngle = LidAngleSensor()
    private let headphoneMotion = HeadphoneMotionSensor()
    private let logger = Logger(subsystem: "com.bjarni.Incant", category: "Dictation")
    private var finishTimeout: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var bufferFlushTask: Task<Void, Never>?
    private var motionDecayTask: Task<Void, Never>?
    let history = TranscriptHistory()
    /// Everything heard in the current session, kept whole so history holds one
    /// entry per dictation rather than one per delta, and where the first words
    /// were typed, which is the part worth knowing when they went somewhere
    /// unexpected.
    private var sessionTranscript = ""
    private var sessionDestination: String?
    private var insertedCharacters = 0
    private var accessibilityFailureReported = false
    private var transcriptionFinalReceived = false
    /// Deltas and a final can still arrive while the Realtime socket closes.
    /// Dismissal stays instant by design — the panel leaves on the hotkey edge
    /// and teardown happens behind it — so this is what stops that tail from
    /// typing itself into whatever the user focuses next, with nothing on screen
    /// left to explain where the text came from.
    private var acceptsTranscript = false

    var hasAPIKey: Bool { KeychainStore.load() != nil }
    var usesEnvironmentKey: Bool { KeychainStore.environmentKey() != nil }
    var bufferedTextPreview: String { String(bufferedText.suffix(260)) }
    var recognitionPromptSummary: String {
        recognitionPrompt.isEmpty ? "Give Incant context about how you speak" : "Custom context added"
    }

    var statusText: String {
        switch phase {
        case .idle: return "Ready"
        case .connecting: return "Connecting"
        case .listening: return "Listening"
        case .finishing: return "Stopping"
        case .success: return "Done"
        case .error(let message): return message
        }
    }

    init() {
        // The hinge is horizontal, so swinging the lid throws the fluid up or down
        // the inside of the sphere. Free to watch and needs no permission, so it
        // runs whenever Incant does.
        lidAngle.onChange = { [weak self] _, degreesPerSecond in
            let energy = Float(min(abs(degreesPerSecond) / 80, 1.8))
            guard energy > 0.03 else { return }
            self?.injectAmbientMotion(
                direction: SIMD2(0, degreesPerSecond > 0 ? -1 : 1),
                energy: energy
            )
        }
        headphoneMotion.onMotion = { [weak self] direction, energy in
            self?.injectAmbientMotion(direction: direction, energy: energy)
        }
        lidAngle.start()
    }

    func toggleRecording() {
        switch phase {
        case .idle, .success, .error:
            startRecording()
        case .connecting, .listening:
            stopRecording()
        case .finishing:
            dismissFinishingSession()
        }
    }

    func saveAPIKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-") else {
            keySaved = false
            return
        }
        do {
            try KeychainStore.save(key)
            apiKeyDraft = ""
            keySaved = true
        } catch {
            keySaved = false
        }
    }

    func saveRecognitionPrompt(_ text: String) {
        recognitionPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(recognitionPrompt, forKey: Self.recognitionPromptDefaultsKey)
    }

    func updateShortcut(_ shortcut: GlobalHotKey.Shortcut) {
        if let error = applyShortcut?(shortcut) {
            shortcutError = error
            return
        }
        self.shortcut = shortcut
        shortcut.save()
        shortcutError = nil
    }

    func openSettings() {
        showSettings?()
    }

    func requestAccessibility() {
        TextInserter.requestAccessibilityPermission()
    }

    func setAutoInsertEnabled(_ enabled: Bool) {
        autoInsertEnabled = enabled
        if enabled {
            flushBufferedTextIfPossible()
        } else {
            bufferFlushTask?.cancel()
            bufferFlushTask = nil
        }
    }

    /// The most recent dictation worth going back for, if there is one.
    var lastTranscript: TranscriptRecord? { history.records.first }

    /// Puts a past dictation back into the staging box under the orb.
    ///
    /// Anything that streamed cleanly into another app belongs to that app — it
    /// is the editing surface and the place it persists. This exists only for the
    /// times the words went somewhere unintended, so the way back is into
    /// Incant's own box rather than into a list Incant keeps about you.
    func stage(_ record: TranscriptRecord) {
        bufferedText = bufferedText.isEmpty ? record.text : bufferedText + " " + record.text
    }

    func stageLastTranscript() {
        guard let record = lastTranscript else { return }
        stage(record)
    }

    func copyBufferedText() {
        guard !bufferedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bufferedText, forType: .string)
    }

    func injectWindowMotion(delta: CGSize, elapsed: TimeInterval) {
        let distance = hypot(delta.width, delta.height)
        guard distance > 0.15 else { return }
        let direction = SIMD2<Float>(Float(delta.width / distance), Float(delta.height / distance))
        let speed = Float(distance / elapsed)
        orbMotion = simd_normalize(orbMotion * 0.22 + direction * 0.78)
        orbMotionEnergy = max(orbMotionEnergy * 0.72, min(1.8, speed / 430))
        decayOrbMotion()
    }

    /// Motion that came from the world rather than from a hand on the window: the
    /// lid swinging, or the head the AirPods are on. It takes the same path as a
    /// window drag — the glass shell accelerates and the fluid lags behind it.
    func injectAmbientMotion(direction: SIMD2<Float>, energy: Float) {
        let length = simd_length(direction)
        guard length > 0.0001, energy > 0.004 else { return }
        orbMotion = simd_normalize(orbMotion * 0.25 + (direction / length) * 0.75)
        orbMotionEnergy = max(orbMotionEnergy, min(1.8, energy))
        decayOrbMotion()
    }

    private func decayOrbMotion() {
        motionDecayTask?.cancel()
        motionDecayTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.orbMotionEnergy > 0.004 {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                self.orbMotionEnergy *= 0.952
            }
            self?.orbMotionEnergy = 0
            self?.orbMotion = .zero
        }
    }

    func startVisualPreview(showPanel: Bool = true) {
        orbSeed = .random()
        phase = .listening
        if showPanel { showRecorder?() }
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            let started = Date.timeIntervalSinceReferenceDate
            while !Task.isCancelled {
                let time = Date.timeIntervalSinceReferenceDate - started
                let voice = 0.2 + abs(sin(time * 2.1)) * 0.48 + abs(sin(time * 5.7)) * 0.18
                self?.level = min(CGFloat(voice), 1)
                try? await Task.sleep(for: .milliseconds(32))
            }
        }
    }

    private func startRecording() {
        guard let apiKey = KeychainStore.load() else {
            showSettings?()
            return
        }

        guard TextInserter.isAccessibilityGranted else {
            fail("Allow Accessibility access")
            TextInserter.requestAccessibilityPermission()
            return
        }

        orbSeed = .random()
        phase = .connecting
        level = 0
        bufferedText = ""
        sessionTranscript = ""
        sessionDestination = nil
        bufferFlushTask?.cancel()
        bufferFlushTask = nil
        insertedCharacters = 0
        accessibilityFailureReported = false
        transcriptionFinalReceived = false
        acceptsTranscript = true
        headphoneMotion.start()
        showRecorder?()
        NSApplication.shared.dockTile.badgeLabel = "●"

        Task {
            let micGranted = await AudioCapture.requestPermission()
            guard micGranted else {
                fail("Microphone access needed")
                return
            }

            do {
                try await transcriber.connect(
                    apiKey: apiKey,
                    prompt: recognitionPrompt,
                    onDelta: { [weak self] delta in
                        Task { @MainActor in self?.receivedDelta(delta) }
                    },
                    onFinal: { [weak self] transcript in
                        Task { @MainActor in self?.receivedFinal(transcript) }
                    },
                    onError: { [weak self] message in
                        Task { @MainActor in self?.fail(message) }
                    }
                )

                try audio.start(
                    onAudio: { [transcriber] data in
                        Task { await transcriber.appendAudio(data) }
                    },
                    onLevel: { [weak self] value in
                        Task { @MainActor in
                            guard self?.phase == .listening else { return }
                            self?.level = CGFloat(value)
                        }
                    }
                )
                phase = .listening
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func stopRecording() {
        // Perceived latency matters more than network teardown here. Remove
        // the surface on the hotkey edge, then finish the Realtime session in
        // the background.
        hideRecorder?()
        NSApplication.shared.dockTile.badgeLabel = nil
        audio.stop()
        level = 0
        phase = .finishing

        Task { await transcriber.commit() }
        finishTimeout?.cancel()
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.fail("No transcript received")
        }
    }

    private func receivedFinal(_ transcript: String) {
        guard acceptsTranscript else { return }
        finishTimeout?.cancel()
        logger.info("Transcription completed after \(self.insertedCharacters, privacy: .public) live characters")
        transcriptionFinalReceived = true

        // Deltas are normally complete. If the service supplied only a final
        // transcript, preserve it in the same caret-aware buffer rather than
        // losing it or pasting it blindly.
        if insertedCharacters == 0, bufferedText.isEmpty, !transcript.isEmpty {
            bufferedText = transcript
            if sessionTranscript.isEmpty { sessionTranscript = transcript }
            if autoInsertEnabled { flushBufferedTextIfPossible() }
            if phase == .success { return }
        }

        if !bufferedText.isEmpty {
            if !autoInsertEnabled {
                completeTranscription()
                return
            }
            phase = .finishing
            if autoInsertEnabled { ensureBufferFlushLoop() }
            return
        }
        guard insertedCharacters > 0 else {
            fail("Nothing heard")
            return
        }
        completeTranscription()
    }

    private func completeTranscription() {
        phase = .success
        NSApplication.shared.dockTile.badgeLabel = nil
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(620))
            guard !Task.isCancelled else { return }
            self?.settleToIdle()
        }
        Task { await transcriber.disconnect() }
    }

    private func dismissFinishingSession() {
        acceptsTranscript = false
        hideRecorder?()
        finishTimeout?.cancel()
        bufferFlushTask?.cancel()
        bufferFlushTask = nil
        settleToIdle()
        Task { await transcriber.disconnect() }
    }

    private func receivedDelta(_ delta: String) {
        guard acceptsTranscript, phase == .listening || phase == .finishing, !delta.isEmpty else { return }
        sessionTranscript += delta
        bufferedText += delta
        if autoInsertEnabled { flushBufferedTextIfPossible() }
    }

    private func flushBufferedTextIfPossible(force: Bool = false) {
        guard force || autoInsertEnabled else { return }
        guard !bufferedText.isEmpty else { return }
        guard let currentTarget = TextInserter.captureTarget() else {
            ensureBufferFlushLoop()
            return
        }
        let pending = bufferedText
        switch TextInserter.insertLive(pending, target: currentTarget) {
        case .inserted:
            bufferedText = ""
            insertedCharacters += pending.count
            if sessionDestination == nil {
                sessionDestination = NSWorkspace.shared.frontmostApplication?.localizedName
            }
            logger.debug("Flushed \(pending.count, privacy: .public) buffered characters")
            bufferFlushTask?.cancel()
            bufferFlushTask = nil
            if transcriptionFinalReceived { completeTranscription() }
        case .noEditableTarget:
            ensureBufferFlushLoop()
        case .accessibilityDenied:
            logger.error("Live insertion lost Accessibility permission")
            guard !accessibilityFailureReported else { return }
            accessibilityFailureReported = true
            fail("Allow Accessibility access")
        }
    }

    private func ensureBufferFlushLoop() {
        guard acceptsTranscript, bufferFlushTask == nil, !bufferedText.isEmpty else { return }
        bufferFlushTask = Task { [weak self] in
            var attemptsAfterFinal = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self else { return }
                guard !self.bufferedText.isEmpty else {
                    self.bufferFlushTask = nil
                    return
                }
                self.flushBufferedTextIfPossible()

                // While the session is live the orb is on screen, so retrying
                // until a writable target appears is honest. Once the transcript
                // is final there is nothing left to look at, and retrying
                // forever would let the buffer type itself into whatever gets
                // focused minutes later. Give up and keep the text instead: the
                // composer still holds it, with its copy button.
                guard self.transcriptionFinalReceived else { continue }
                attemptsAfterFinal += 1
                guard attemptsAfterFinal >= 28 else { continue }
                self.logger.error(
                    "Gave up inserting \(self.bufferedText.count, privacy: .public) buffered characters"
                )
                self.settleToIdle()
                return
            }
        }
    }

    private func fail(_ message: String) {
        logger.error("Dictation failed: \(message, privacy: .public)")
        acceptsTranscript = false
        audio.stop()
        finishTimeout?.cancel()
        bufferFlushTask?.cancel()
        bufferFlushTask = nil
        phase = .error(message)
        NSApplication.shared.dockTile.badgeLabel = "!"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.settleToIdle()
        }
        Task { await transcriber.disconnect() }
    }

    private func settleToIdle() {
        acceptsTranscript = false
        headphoneMotion.stop()
        bufferFlushTask?.cancel()
        bufferFlushTask = nil
        // Every ending funnels through here — finished, failed, dismissed, or
        // given up on — so this is the one place the session can be written down.
        history.remember(
            sessionTranscript,
            destination: sessionDestination,
            delivered: insertedCharacters > 0
        )
        sessionTranscript = ""
        phase = .idle
        level = 0
        NSApplication.shared.dockTile.badgeLabel = nil
        hideRecorder?()
    }

    private static let recognitionPromptDefaultsKey = "transcriptionRecognitionPrompt"
    private static let legacyKeywordsDefaultsKey = "transcriptionKeywords"

    private static func loadRecognitionPrompt() -> String {
        if let prompt = UserDefaults.standard.string(forKey: recognitionPromptDefaultsKey) {
            return prompt
        }
        let legacyKeywords = UserDefaults.standard.stringArray(forKey: legacyKeywordsDefaultsKey) ?? []
        guard !legacyKeywords.isEmpty else { return "" }
        return "Words and names I frequently use include: \(legacyKeywords.joined(separator: ", "))."
    }
}
