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
    @Published private(set) var hasInsertionTarget = false
    @Published var apiKeyDraft = ""
    @Published private(set) var keySaved = false

    var showRecorder: (() -> Void)?
    var hideRecorder: (() -> Void)?
    var showSettings: (() -> Void)?

    private let audio = AudioCapture()
    private let transcriber = RealtimeTranscriber()
    private let logger = Logger(subsystem: "com.bjarni.Incant", category: "Dictation")
    private var finishTimeout: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var bufferFlushTask: Task<Void, Never>?
    private var targetTrackingTask: Task<Void, Never>?
    private var insertionTarget: TextInserter.Target?
    private var insertedCharacters = 0
    private var accessibilityFailureReported = false
    private var transcriptionFinalReceived = false

    var hasAPIKey: Bool { KeychainStore.load() != nil }
    var usesEnvironmentKey: Bool { KeychainStore.environmentKey() != nil }
    var bufferedTextPreview: String { String(bufferedText.suffix(260)) }

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

    func toggleRecording() {
        switch phase {
        case .idle, .success, .error:
            startRecording()
        case .connecting, .listening:
            stopRecording()
        case .finishing:
            break
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

    func insertBufferedText() {
        flushBufferedTextIfPossible(force: true)
    }

    func copyBufferedText() {
        guard !bufferedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bufferedText, forType: .string)
    }

    func startVisualPreview(showPanel: Bool = true) {
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

        phase = .connecting
        level = 0
        bufferedText = ""
        bufferFlushTask?.cancel()
        bufferFlushTask = nil
        insertedCharacters = 0
        accessibilityFailureReported = false
        transcriptionFinalReceived = false
        insertionTarget = TextInserter.captureTarget()
        hasInsertionTarget = insertionTarget != nil
        startTargetTracking()
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
        finishTimeout?.cancel()
        logger.info("Transcription completed after \(self.insertedCharacters, privacy: .public) live characters")
        transcriptionFinalReceived = true

        // Deltas are normally complete. If the service supplied only a final
        // transcript, preserve it in the same caret-aware buffer rather than
        // losing it or pasting it blindly.
        if insertedCharacters == 0, bufferedText.isEmpty, !transcript.isEmpty {
            bufferedText = transcript
            if autoInsertEnabled { flushBufferedTextIfPossible() }
            if phase == .success { return }
        }

        if !bufferedText.isEmpty {
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

    private func receivedDelta(_ delta: String) {
        guard phase == .listening || phase == .finishing, !delta.isEmpty else { return }
        bufferedText += delta
        if autoInsertEnabled { flushBufferedTextIfPossible() }
    }

    private func flushBufferedTextIfPossible(force: Bool = false) {
        guard force || autoInsertEnabled else { return }
        guard !bufferedText.isEmpty else { return }
        if let currentTarget = TextInserter.captureTarget() {
            insertionTarget = currentTarget
            hasInsertionTarget = true
        }
        let pending = bufferedText
        switch TextInserter.insertLive(pending, target: insertionTarget) {
        case .inserted:
            bufferedText = ""
            insertedCharacters += pending.count
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

    private func startTargetTracking() {
        targetTrackingTask?.cancel()
        targetTrackingTask = Task { [weak self] in
            while !Task.isCancelled {
                if let target = TextInserter.captureTarget() {
                    self?.insertionTarget = target
                    self?.hasInsertionTarget = true
                }
                try? await Task.sleep(for: .milliseconds(140))
            }
        }
    }

    private func ensureBufferFlushLoop() {
        guard bufferFlushTask == nil, !bufferedText.isEmpty else { return }
        bufferFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self else { return }
                guard !self.bufferedText.isEmpty else {
                    self.bufferFlushTask = nil
                    return
                }
                self.flushBufferedTextIfPossible()
            }
        }
    }

    private func fail(_ message: String) {
        logger.error("Dictation failed: \(message, privacy: .public)")
        audio.stop()
        finishTimeout?.cancel()
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
        bufferFlushTask?.cancel()
        bufferFlushTask = nil
        targetTrackingTask?.cancel()
        targetTrackingTask = nil
        insertionTarget = nil
        hasInsertionTarget = false
        phase = .idle
        level = 0
        NSApplication.shared.dockTile.badgeLabel = nil
        hideRecorder?()
    }
}
