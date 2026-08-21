import Foundation
import OSLog

actor RealtimeTranscriber {
    enum StreamKind: Sendable, Equatable {
        /// Low-latency speech-to-text used while the microphone is open.
        case live
        /// Audio-aware text generated from the committed, complete delivery.
        case expressive
    }

    private let logger = Logger(subsystem: "com.bjarni.Incant", category: "Realtime")
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    /// Every socket belongs to exactly one recording. A late disconnect or
    /// audio callback from an older recording must never touch its successor.
    private var recordingID: UUID?
    private var mode: TranscriptionMode?
    private var didDeliverFinal = false

    func connect(
        recordingID: UUID,
        mode: TranscriptionMode,
        apiKey: String,
        prompt: String,
        onDelta: @escaping @Sendable (String, StreamKind) -> Void,
        onFinal: @escaping @Sendable (String, StreamKind) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {
        disconnectCurrent()
        let endpoint: String
        switch mode {
        case .direct:
            // Transcription sessions are selected by intent; the speech-to-text
            // model itself belongs in session.audio.input.transcription.model.
            endpoint = "wss://eu.api.openai.com/v1/realtime?intent=transcription"
        case .intonation:
            endpoint = "wss://eu.api.openai.com/v1/realtime?model=gpt-realtime-2.1"
        }
        var request = URLRequest(url: URL(string: endpoint)!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        self.recordingID = recordingID
        self.mode = mode
        didDeliverFinal = false
        socket.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(
                socket: socket,
                recordingID: recordingID,
                onDelta: onDelta,
                onFinal: onFinal,
                onError: onError
            )
        }
        try await send(
            Self.sessionUpdate(mode: mode, recognitionPrompt: prompt),
            recordingID: recordingID
        )
        try Task.checkCancellation()
        guard self.recordingID == recordingID else { throw CancellationError() }
    }

    func appendAudio(_ data: Data, recordingID: UUID) async {
        try? await send([
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ], recordingID: recordingID)
    }

    func commit(recordingID: UUID) async {
        try? await send(["type": "input_audio_buffer.commit"], recordingID: recordingID)
        guard self.recordingID == recordingID, mode == .intonation else { return }
        try? await send([
            "type": "response.create",
            "response": [
                "output_modalities": ["text"],
            ],
        ], recordingID: recordingID)
    }

    func disconnect(recordingID: UUID) async {
        guard self.recordingID == recordingID else { return }
        disconnectCurrent()
    }

    private func disconnectCurrent() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        recordingID = nil
        mode = nil
        didDeliverFinal = false
    }

    private func send(_ object: [String: Any], recordingID: UUID) async throws {
        guard self.recordingID == recordingID, let socket else {
            throw CancellationError()
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else { return }
        try await socket.send(.string(string))
    }

    private func receiveLoop(
        socket: URLSessionWebSocketTask,
        recordingID: UUID,
        onDelta: @escaping @Sendable (String, StreamKind) -> Void,
        onFinal: @escaping @Sendable (String, StreamKind) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async {
        while !Task.isCancelled, self.recordingID == recordingID {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let string): data = Data(string.utf8)
                case .data(let value): data = value
                @unknown default: continue
                }
                handle(
                    data,
                    recordingID: recordingID,
                    onDelta: onDelta,
                    onFinal: onFinal,
                    onError: onError
                )
            } catch {
                if !Task.isCancelled, self.recordingID == recordingID {
                    onError(Self.friendlyMessage(for: error))
                }
                break
            }
        }
    }

    private func handle(
        _ data: Data,
        recordingID: UUID,
        onDelta: @escaping @Sendable (String, StreamKind) -> Void,
        onFinal: @escaping @Sendable (String, StreamKind) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        guard self.recordingID == recordingID,
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        logger.debug("Received Realtime event: \(type, privacy: .public)")
        switch type {
        case "conversation.item.input_audio_transcription.delta":
            if let delta = event["delta"] as? String { onDelta(delta, .live) }
        case "conversation.item.input_audio_transcription.completed":
            // In Incantation this is the completion of the live draft, not the
            // completion of the audio-aware expressive pass requested below.
            if mode == .direct, let transcript = event["transcript"] as? String {
                deliverFinal(transcript, kind: .live, to: onFinal)
            }
        case "response.output_text.delta", "response.text.delta":
            if let delta = event["delta"] as? String { onDelta(delta, .expressive) }
        case "response.output_text.done", "response.text.done":
            if let text = event["text"] as? String {
                deliverFinal(text, kind: .expressive, to: onFinal)
            }
        case "response.done":
            if !didDeliverFinal, let text = Self.outputText(from: event) {
                deliverFinal(text, kind: .expressive, to: onFinal)
            } else if let response = event["response"] as? [String: Any],
                      let status = response["status"] as? String,
                      status == "failed" || status == "incomplete" {
                onError("Expressive transcription did not complete")
            }
        case "error":
            let details = event["error"] as? [String: Any]
            onError(details?["message"] as? String ?? "OpenAI connection error")
        default:
            break
        }
    }

    private func deliverFinal(
        _ text: String,
        kind: StreamKind,
        to onFinal: @escaping @Sendable (String, StreamKind) -> Void
    ) {
        guard !didDeliverFinal else { return }
        didDeliverFinal = true
        onFinal(text, kind)
    }

    private static func sessionUpdate(
        mode: TranscriptionMode,
        recognitionPrompt: String
    ) -> [String: Any] {
        let input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": 24_000],
            "turn_detection": NSNull(),
        ]

        switch mode {
        case .direct:
            var directInput = input
            directInput["transcription"] = Self.transcriptionConfiguration(
                recognitionPrompt: recognitionPrompt
            )
            return [
                "type": "session.update",
                "session": [
                    "type": "transcription",
                    "audio": ["input": directInput],
                ],
            ]

        case .intonation:
            var incantationInput = input
            incantationInput["transcription"] = Self.transcriptionConfiguration(
                recognitionPrompt: recognitionPrompt
            )
            return [
                "type": "session.update",
                "session": [
                    "type": "realtime",
                    "output_modalities": ["text"],
                    "instructions": mode.instructions(recognitionContext: recognitionPrompt),
                    "max_output_tokens": 4_096,
                    // The input transcription supplies live draft deltas while
                    // the Realtime model retains the same audio for the
                    // expressive response created when the user stops.
                    "audio": ["input": incantationInput],
                ],
            ]
        }
    }

    private static func transcriptionConfiguration(recognitionPrompt: String) -> [String: Any] {
        var transcription: [String: Any] = [
            "model": "gpt-live-transcribe",
            "delay": "low",
        ]
        if !recognitionPrompt.isEmpty {
            transcription["prompt"] = recognitionPrompt
        }
        return transcription
    }

    private static func outputText(from event: [String: Any]) -> String? {
        guard let response = event["response"] as? [String: Any],
              let output = response["output"] as? [[String: Any]] else { return nil }
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content where part["type"] as? String == "output_text" {
                if let text = part["text"] as? String { return text }
            }
        }
        return nil
    }

    private static func friendlyMessage(for error: Error) -> String {
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorUserAuthenticationRequired, NSURLErrorNoPermissionsToReadFile:
                return "Check API key"
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "Network unavailable"
            case NSURLErrorTimedOut:
                return "Connection timed out"
            case NSURLErrorCancelled:
                return "Connection cancelled"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
