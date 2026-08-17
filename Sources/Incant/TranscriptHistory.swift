import AppKit
import OSLog

/// What was said, where it went, and whether it arrived.
struct TranscriptRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let date: Date
    /// The app the words were typed into, as far as Incant could tell.
    let destination: String
    /// False when the words never reached anything and only exist here.
    let delivered: Bool
}

/// A short, local record of finished dictations, kept so a transcript that lands
/// somewhere unexpected can still be recovered. Incant types into whatever holds
/// the caret, which is occasionally not what the user meant, and until now the
/// words were gone the moment they left the buffer.
///
/// Only whole dictations are kept, never the individual deltas they arrive in,
/// and only ones long enough to be worth going back for.
@MainActor
final class TranscriptHistory: ObservableObject {
    @Published private(set) var records: [TranscriptRecord] = []

    /// Below this a transcript is a "yes", a "delete that", a false start — never
    /// something anyone returns to look for.
    static let minimumCharacters = 24
    private static let limit = 60
    private static let defaultsKey = "transcriptHistory"

    private let logger = Logger(subsystem: "com.bjarni.Incant", category: "History")
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let stored = try? JSONDecoder().decode([TranscriptRecord].self, from: data) else { return }
        records = stored
    }

    var isWorthShowing: Bool { !records.isEmpty }

    func remember(_ transcript: String, destination: String?, delivered: Bool) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minimumCharacters else { return }
        // A session that ends without new words — the user pressed the shortcut
        // twice, or nothing was heard — should not push older transcripts out.
        guard text != records.first?.text else { return }

        records.insert(
            TranscriptRecord(
                id: UUID(),
                text: text,
                date: .now,
                destination: destination ?? "",
                delivered: delivered
            ),
            at: 0
        )
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        persist()
    }

    func copy(_ record: TranscriptRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.text, forType: .string)
    }

    func forget(_ record: TranscriptRecord) {
        records.removeAll { $0.id == record.id }
        persist()
    }

    func forgetEverything() {
        records = []
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else {
            logger.error("Could not write transcript history")
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
