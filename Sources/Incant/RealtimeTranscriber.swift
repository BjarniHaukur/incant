import Foundation
import OSLog

actor RealtimeTranscriber {
    private let logger = Logger(subsystem: "com.bjarni.Incant", category: "Realtime")
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    /// Every socket belongs to exactly one recording. A late disconnect or
    /// audio callback from an older recording must never touch its successor.
    private var recordingID: UUID?
    private var didDeliverFinal = false
    private var didLogFirstDelta = false

    func connect(
        recordingID: UUID,
        mode: TranscriptionMode,
        apiKey: String,
        prompt: String,
        onDelta: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {
        disconnectCurrent()
        // Both modes are transcription sessions. Accurate waits for more audio
        // context before emitting the same append-only transcript stream.
        let endpoint = "wss://eu.api.openai.com/v1/realtime?intent=transcription"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        self.recordingID = recordingID
        didDeliverFinal = false
        didLogFirstDelta = false
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
        didDeliverFinal = false
        didLogFirstDelta = false
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
        onDelta: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void,
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
        onDelta: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        guard self.recordingID == recordingID,
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        logger.debug("Received Realtime event: \(type, privacy: .public)")
        switch type {
        case "conversation.item.input_audio_transcription.delta":
            if let delta = event["delta"] as? String {
                logFirstDelta("live")
                onDelta(delta)
            }
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = event["transcript"] as? String {
                deliverFinal(transcript, to: onFinal)
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
        to onFinal: @escaping @Sendable (String) -> Void
    ) {
        guard !didDeliverFinal else { return }
        didDeliverFinal = true
        onFinal(text)
    }

    private func logFirstDelta(_ kind: String) {
        guard !didLogFirstDelta else { return }
        didLogFirstDelta = true
        logger.info("Receiving \(kind, privacy: .public) transcript deltas")
    }

    private static func sessionUpdate(
        mode: TranscriptionMode,
        recognitionPrompt: String
    ) -> [String: Any] {
        var input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": 24_000],
            "turn_detection": NSNull(),
        ]
        input["transcription"] = Self.transcriptionConfiguration(
            mode: mode,
            recognitionPrompt: recognitionPrompt
        )
        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": input],
            ],
        ]
    }

    static func transcriptionConfiguration(
        mode: TranscriptionMode,
        recognitionPrompt: String
    ) -> [String: Any] {
        var transcription: [String: Any] = [
            "model": "gpt-live-transcribe",
            "delay": mode.delay,
        ]
        if !recognitionPrompt.isEmpty {
            transcription["prompt"] = recognitionPrompt
        }
        return transcription
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
