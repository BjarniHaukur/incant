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
    @Published private(set) var transcriptionMode = AppModel.loadTranscriptionMode()
    @Published var apiKeyDraft = ""
    @Published private(set) var keySaved = false
    @Published private(set) var apiKeyError: String?

    var showRecorder: (() -> Void)?
    var hideRecorder: (() -> Void)?
    var showSettings: (() -> Void)?
    var applyShortcut: ((GlobalHotKey.Shortcut) -> String?)?

    private let audio = AudioCapture()
    private let transcriber = RealtimeTranscriber()
    private let lidAngle = LidAngleSensor()
    private let logger = Logger(subsystem: "com.bjarni.Incant", category: "Dictation")
    private var startTask: Task<Void, Never>?
    private var finishTimeout: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
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
    private var sessionInsertionTarget: TextInserter.Target?
    /// The exact low-latency draft successfully written by Expressive mode.
    /// The expressive pass may replace it only if it is still directly behind
    /// the caret, so a user edit can never be overwritten speculatively.
    private var insertedIncantationDraft = ""
    private var expressiveTranscript = ""
    private var insertedCharacters = 0
    private var accessibilityFailureReported = false
    private var transcriptionFinalReceived = false
    private var activeTranscriptionMode: TranscriptionMode = .direct
    /// Async work is tagged with the recording that created it. Rapid toggles
    /// can otherwise let an old connect, callback, disconnect, or timer mutate
    /// the new recording without producing an error state.
    private var activeRecordingID: UUID?
    /// Deltas and a final can still arrive while the Realtime socket closes.
    /// Dismissal stays instant by design — the panel leaves on the hotkey edge
    /// and teardown happens behind it — so this is what stops that tail from
    /// typing itself into whatever the user focuses next, with nothing on screen
    /// left to explain where the text came from.
    private var acceptsTranscript = false

    // Both answered without opening the Keychain, because the settings row asks
    // them on every redraw and opening it can raise a system prompt.
    var hasAPIKey: Bool { KeychainStore.hasStoredKey || KeychainStore.environmentKey() != nil }
    var hasStoredKey: Bool { KeychainStore.hasStoredKey }
    var hasEnvironmentKey: Bool { KeychainStore.environmentKey() != nil }
    /// True only when the key actually in use came from the environment, which is
    /// no longer the same as "the environment has one".
    var usesEnvironmentKey: Bool { !hasStoredKey && hasEnvironmentKey }
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

    /// Says why it refused. Saving used to fail in silence, which on a fresh
    /// install is indistinguishable from a button that does nothing.
    func saveAPIKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            keySaved = false
            apiKeyError = "Paste a key first"
            return
        }
        guard key.hasPrefix("sk-") else {
            keySaved = false
            apiKeyError = "Keys begin with sk-"
            return
        }
        do {
            try KeychainStore.save(key)
            apiKeyDraft = ""
            keySaved = true
            apiKeyError = nil
        } catch {
            keySaved = false
            apiKeyError = "Could not write to the Keychain"
            logger.error("Keychain save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops the key typed into Incant, which hands the job back to whatever the
    /// environment provides — the way out of an override.
    func useEnvironmentKey() {
        KeychainStore.forgetStoredKey()
        apiKeyDraft = ""
        keySaved = false
        apiKeyError = nil
    }

    func saveRecognitionPrompt(_ text: String) {
        recognitionPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(recognitionPrompt, forKey: Self.recognitionPromptDefaultsKey)
    }

    func setTranscriptionMode(_ mode: TranscriptionMode) {
        transcriptionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.transcriptionModeDefaultsKey)
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

    /// Asks for Accessibility, having first thrown away whatever answer the
    /// system is holding.
    ///
    /// The three states a refused Incant can be in — never asked, asked and
    /// refused, and approved under a build that no longer exists — look identical
    /// from here and only the first of them will produce a prompt. Since all
    /// three mean Incant is untrusted, there is no approval to lose by clearing
    /// the record, and clearing it is what makes the system willing to ask again.
    /// That is why this is the only button in the row: nothing is left for a
    /// second one to do.
    func requestAccessibility() {
        guard !TextInserter.isAccessibilityGranted else { return }
        TextInserter.resetAccessibilityApproval()
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

    /// Motion that came from the world rather than from a hand on the window —
    /// which today means the lid swinging. It takes the same path as a window
    /// drag: the glass shell accelerates and the fluid lags behind it.
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

        // Starting directly from the brief success/error state is intentional.
        // Finish archiving that session now and invalidate all delayed work it
        // left behind before the new recording owns the UI.
        settleTask?.cancel()
        if let previousRecordingID = activeRecordingID {
            settleToIdle(recordingID: previousRecordingID)
        }

        let recordingID = UUID()
        activeRecordingID = recordingID
        activeTranscriptionMode = transcriptionMode
        finishTimeout?.cancel()
        startTask?.cancel()
        level = 0
        bufferedText = ""
        sessionTranscript = ""
        sessionDestination = nil
        insertedIncantationDraft = ""
        expressiveTranscript = ""
        // Preserve the editor that owns the caret for both live writing and the
        // safe Incantation refinement after recording stops.
        sessionInsertionTarget = TextInserter.captureTarget()
        bufferFlushTask?.cancel()
        bufferFlushTask = nil
        insertedCharacters = 0
        accessibilityFailureReported = false
        transcriptionFinalReceived = false
        acceptsTranscript = true

        guard TextInserter.isAccessibilityGranted else {
            fail("Allow Accessibility access", recordingID: recordingID)
            TextInserter.requestAccessibilityPermission()
            return
        }

        orbSeed = .random()
        phase = .connecting
        showRecorder?()
        NSApplication.shared.dockTile.badgeLabel = "●"

        startTask = Task { [weak self] in
            guard let self else { return }
            let micGranted = await AudioCapture.requestPermission()
            guard !Task.isCancelled,
                  self.activeRecordingID == recordingID,
                  self.phase == .connecting else { return }
            guard micGranted else {
                self.fail("Microphone access needed", recordingID: recordingID)
                return
            }

            do {
                try await self.transcriber.connect(
                    recordingID: recordingID,
                    mode: self.activeTranscriptionMode,
                    apiKey: apiKey,
                    prompt: self.recognitionPrompt,
                    onDelta: { [weak self] delta, kind in
                        Task { @MainActor in
                            self?.receivedDelta(delta, kind: kind, recordingID: recordingID)
                        }
                    },
                    onFinal: { [weak self] transcript, kind in
                        Task { @MainActor in
                            self?.receivedFinal(transcript, kind: kind, recordingID: recordingID)
                        }
                    },
                    onError: { [weak self] message in
                        Task { @MainActor in
                            self?.fail(message, recordingID: recordingID)
                        }
                    }
                )

                guard !Task.isCancelled,
                      self.activeRecordingID == recordingID,
                      self.phase == .connecting else {
                    await self.transcriber.disconnect(recordingID: recordingID)
                    return
                }

                try self.audio.start(
                    onAudio: { [transcriber = self.transcriber] data in
                        Task { await transcriber.appendAudio(data, recordingID: recordingID) }
                    },
                    onLevel: { [weak self] value in
                        Task { @MainActor in
                            guard self?.activeRecordingID == recordingID,
                                  self?.phase == .listening else { return }
                            self?.level = CGFloat(value)
                        }
                    }
                )
                self.phase = .listening
            } catch is CancellationError {
                // A quick stop or a newer recording deliberately invalidated
                // this connection. Its teardown is scoped by recordingID.
                await self.transcriber.disconnect(recordingID: recordingID)
            } catch {
                self.fail(error.localizedDescription, recordingID: recordingID)
            }
        }
    }

    private func stopRecording() {
        guard let recordingID = activeRecordingID else { return }
        // Both modes have already streamed a draft. Incantation keeps the orb
        // present briefly while that same text is refined from the full audio.
        if activeTranscriptionMode == .direct {
            hideRecorder?()
            NSApplication.shared.dockTile.badgeLabel = nil
        } else {
            NSApplication.shared.dockTile.badgeLabel = "…"
        }
        startTask?.cancel()
        audio.stop()
        level = 0

        // If stop beats connection setup there is no committed audio to wait
        // for. End this attempt immediately; the tagged teardown cannot cancel
        // a recording started on the next hotkey press.
        if phase == .connecting {
            acceptsTranscript = false
            settleToIdle(recordingID: recordingID)
            Task { await transcriber.disconnect(recordingID: recordingID) }
            return
        }

        phase = .finishing

        Task { await transcriber.commit(recordingID: recordingID) }
        finishTimeout?.cancel()
        let timeout: Duration = activeTranscriptionMode == .intonation ? .seconds(6) : .seconds(10)
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            // Incantation already delivered a usable live transcript. If its
            // optional expressive refinement is slow, keep those words and get
            // out of the user's way instead of turning success into an error.
            if self.activeTranscriptionMode == .intonation,
               self.insertedCharacters > 0 || !self.bufferedText.isEmpty {
                self.logger.info("Expressive refinement timed out; kept live transcript")
                self.transcriptionFinalReceived = true
                self.completeTranscription(recordingID: recordingID)
            } else {
                self.fail("No transcript received", recordingID: recordingID)
            }
        }
    }

    private func receivedFinal(
        _ transcript: String,
        kind: RealtimeTranscriber.StreamKind,
        recordingID: UUID
    ) {
        guard activeRecordingID == recordingID, acceptsTranscript else { return }
        if activeTranscriptionMode == .intonation, kind == .expressive {
            finishIncantation(with: transcript, recordingID: recordingID)
            return
        }
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
                completeTranscription(recordingID: recordingID)
                return
            }
            phase = .finishing
            if autoInsertEnabled { ensureBufferFlushLoop() }
            return
        }
        guard insertedCharacters > 0 else {
            fail("Nothing heard", recordingID: recordingID)
            return
        }
        completeTranscription(recordingID: recordingID)
    }

    private func completeTranscription(recordingID: UUID) {
        guard activeRecordingID == recordingID else { return }
        phase = .success
        NSApplication.shared.dockTile.badgeLabel = nil
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(620))
            guard !Task.isCancelled else { return }
            self?.settleToIdle(recordingID: recordingID)
        }
        Task { await transcriber.disconnect(recordingID: recordingID) }
    }

    private func dismissFinishingSession() {
        guard let recordingID = activeRecordingID else { return }
        acceptsTranscript = false
        hideRecorder?()
        finishTimeout?.cancel()
        bufferFlushTask?.cancel()
        bufferFlushTask = nil
        settleToIdle(recordingID: recordingID)
        Task { await transcriber.disconnect(recordingID: recordingID) }
    }

    private func receivedDelta(
        _ delta: String,
        kind: RealtimeTranscriber.StreamKind,
        recordingID: UUID
    ) {
        guard activeRecordingID == recordingID,
              acceptsTranscript,
              phase == .listening || phase == .finishing,
              !delta.isEmpty else { return }
        if activeTranscriptionMode == .intonation, kind == .expressive {
            expressiveTranscript += delta
            return
        }
        sessionTranscript += delta
        bufferedText += delta
        if autoInsertEnabled {
            flushBufferedTextIfPossible()
        }
    }

    private func flushBufferedTextIfPossible(force: Bool = false) {
        guard force || autoInsertEnabled else { return }
        guard !bufferedText.isEmpty else { return }
        guard let currentTarget = sessionInsertionTarget ?? TextInserter.captureTarget() else {
            ensureBufferFlushLoop()
            return
        }
        let pending = bufferedText
        switch TextInserter.insertLive(pending, target: currentTarget) {
        case .inserted:
            bufferedText = ""
            insertedCharacters += pending.count
            if activeTranscriptionMode == .intonation, !transcriptionFinalReceived {
                insertedIncantationDraft += pending
            }
            if sessionDestination == nil {
                sessionDestination = NSWorkspace.shared.frontmostApplication?.localizedName
            }
            logger.debug("Flushed \(pending.count, privacy: .public) buffered characters")
            bufferFlushTask?.cancel()
            bufferFlushTask = nil
            if transcriptionFinalReceived, let recordingID = activeRecordingID {
                completeTranscription(recordingID: recordingID)
            }
        case .noEditableTarget:
            ensureBufferFlushLoop()
        case .accessibilityDenied:
            logger.error("Live insertion lost Accessibility permission")
            guard !accessibilityFailureReported else { return }
            accessibilityFailureReported = true
            guard let recordingID = activeRecordingID else { return }
            fail("Allow Accessibility access", recordingID: recordingID)
        }
    }

    private func finishIncantation(with finalText: String, recordingID: UUID) {
        finishTimeout?.cancel()
        transcriptionFinalReceived = true
        let styled = finalText.isEmpty ? expressiveTranscript : finalText
        guard !styled.isEmpty else {
            fail("Nothing heard", recordingID: recordingID)
            return
        }
        expressiveTranscript = styled
        sessionTranscript = styled

        // Any live draft still buffered was never visible, so discard it in
        // favor of the complete styled transcript. If some draft was inserted,
        // replace it only when the exact text is still immediately behind the
        // caret. Moving the caret or editing the draft makes this safely leave
        // the live words alone instead of touching unrelated text.
        bufferedText = ""
        if !insertedIncantationDraft.isEmpty,
           let target = sessionInsertionTarget,
           TextInserter.replaceRecentlyInserted(
               insertedIncantationDraft,
               with: styled,
               target: target
           ) {
            insertedCharacters += styled.count - insertedIncantationDraft.count
            insertedIncantationDraft = styled
            completeTranscription(recordingID: recordingID)
            return
        }

        if insertedIncantationDraft.isEmpty {
            bufferedText = styled
            if autoInsertEnabled {
                flushBufferedTextIfPossible()
                if bufferedText.isEmpty { return }
                ensureBufferFlushLoop()
            } else {
                completeTranscription(recordingID: recordingID)
            }
            return
        }

        logger.info("Kept edited live draft; expressive version remains in history")
        completeTranscription(recordingID: recordingID)
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
                guard let recordingID = self.activeRecordingID else { return }
                self.settleToIdle(recordingID: recordingID)
                return
            }
        }
    }

    private func fail(_ message: String, recordingID: UUID) {
        guard activeRecordingID == recordingID else { return }
        logger.error("Dictation failed: \(message, privacy: .public)")
        acceptsTranscript = false
        startTask?.cancel()
        audio.stop()
        finishTimeout?.cancel()
        bufferFlushTask?.cancel()
        bufferFlushTask = nil
        phase = .error(message)
        NSApplication.shared.dockTile.badgeLabel = "!"
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.settleToIdle(recordingID: recordingID)
        }
        Task { await transcriber.disconnect(recordingID: recordingID) }
    }

    private func settleToIdle(recordingID: UUID) {
        guard activeRecordingID == recordingID else { return }
        acceptsTranscript = false
        startTask?.cancel()
        startTask = nil
        finishTimeout?.cancel()
        finishTimeout = nil
        settleTask?.cancel()
        settleTask = nil
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
        insertedIncantationDraft = ""
        expressiveTranscript = ""
        sessionInsertionTarget = nil
        activeRecordingID = nil
        phase = .idle
        level = 0
        NSApplication.shared.dockTile.badgeLabel = nil
        hideRecorder?()
    }

    private static let recognitionPromptDefaultsKey = "transcriptionRecognitionPrompt"
    private static let legacyKeywordsDefaultsKey = "transcriptionKeywords"
    private static let transcriptionModeDefaultsKey = "transcriptionMode"

    private static func loadTranscriptionMode() -> TranscriptionMode {
        guard let stored = UserDefaults.standard.string(forKey: transcriptionModeDefaultsKey),
              let mode = TranscriptionMode(rawValue: stored) else { return .direct }
        return mode
    }

    private static func loadRecognitionPrompt() -> String {
        if let prompt = UserDefaults.standard.string(forKey: recognitionPromptDefaultsKey) {
            return prompt
        }
        let legacyKeywords = UserDefaults.standard.stringArray(forKey: legacyKeywordsDefaultsKey) ?? []
        guard !legacyKeywords.isEmpty else { return "" }
        return "Words and names I frequently use include: \(legacyKeywords.joined(separator: ", "))."
    }
}
