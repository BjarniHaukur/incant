import Foundation
import OSLog

actor RealtimeTranscriber {
    private let logger = Logger(subsystem: "com.bjarni.PushType", category: "Realtime")
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var onDelta: (@Sendable (String) -> Void)?
    private var onFinal: (@Sendable (String) -> Void)?
    private var onError: (@Sendable (String) -> Void)?

    func connect(
        apiKey: String,
        onDelta: @escaping @Sendable (String) -> Void,
        onFinal: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {
        await disconnect()
        self.onDelta = onDelta
        self.onFinal = onFinal
        self.onError = onError

        // Transcription sessions are selected by intent; the speech-to-text
        // model itself belongs in session.audio.input.transcription.model.
        var request = URLRequest(url: URL(string: "wss://eu.api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        socket.resume()

        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        try await send([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": [
                            "model": "gpt-live-transcribe",
                            "delay": "low",
                        ],
                        "turn_detection": NSNull(),
                    ]
                ]
            ]
        ])
    }

    func appendAudio(_ data: Data) async {
        try? await send([
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ])
    }

    func commit() async {
        try? await send(["type": "input_audio_buffer.commit"])
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func send(_ object: [String: Any]) async throws {
        guard let socket else { throw URLError(.notConnectedToInternet) }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else { return }
        try await socket.send(.string(string))
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let string): data = Data(string.utf8)
                case .data(let value): data = value
                @unknown default: continue
                }
                handle(data)
            } catch {
                if !Task.isCancelled { onError?(Self.friendlyMessage(for: error)) }
                break
            }
        }
    }

    private func handle(_ data: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        logger.debug("Received Realtime event: \(type, privacy: .public)")
        switch type {
        case "conversation.item.input_audio_transcription.delta":
            if let delta = event["delta"] as? String { onDelta?(delta) }
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = event["transcript"] as? String { onFinal?(transcript) }
        case "error":
            let details = event["error"] as? [String: Any]
            onError?(details?["message"] as? String ?? "OpenAI connection error")
        default:
            break
        }
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
