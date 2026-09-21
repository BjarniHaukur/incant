import AppKit
import OSLog

/// One stretch of continuous speech, as it appears in the log file.
struct TranscriptChapter: Identifiable, Equatable {
    let id: UUID
    /// When the first words of the chapter were heard.
    let date: Date
    var text: String
}

/// Everything ever said to Incant, in one plain-text file, appended to as the
/// words arrive.
///
/// Incant types into whatever holds the caret, and the caret's app is the only
/// copy that used to exist once a session ended. One ⌘⌫ in a terminal could take
/// half an hour of speech with it. So every delta is written here the moment it
/// is accepted, not when the session ends, and nothing is ever dropped for being
/// short. The file is broken into chapters only by time: a pause longer than
/// `chapterGap` between two deltas starts a new timestamped chapter, whether or
/// not a session boundary fell in between.
///
/// The file is the source of truth and is meant to be opened directly. The
/// chapters kept in memory are a view of it for the recovery list.
@MainActor
final class TranscriptLog: ObservableObject {
    @Published private(set) var chapters: [TranscriptChapter] = []

    /// Silence longer than this between two deltas closes the chapter.
    static let chapterGap: TimeInterval = 10
    nonisolated static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Incant", isDirectory: true)
            .appendingPathComponent("transcript.txt")
    }()

    private static let legacyDefaultsKey = "transcriptHistory"
    nonisolated private static let headerFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private let logger = Logger(subsystem: "com.bjarni.Incant", category: "Transcript")
    private let fileURL: URL
    private var handle: FileHandle?
    private var lastAppend: Date?

    init(fileURL: URL = TranscriptLog.fileURL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        migrateLegacyHistory(from: defaults)
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            chapters = Self.parse(text)
        }
    }

    var lastChapter: TranscriptChapter? { chapters.last }

    /// Writes words that were just heard, opening a new chapter after a pause.
    func append(_ delta: String, at now: Date = .now) {
        let continues = lastAppend.map { now.timeIntervalSince($0) <= Self.chapterGap } ?? false
        if continues, !chapters.isEmpty {
            guard !delta.isEmpty else { return }
            chapters[chapters.count - 1].text += delta
            write(delta)
        } else {
            // Deltas usually lead with the space that joined them to the previous
            // word. At the top of a chapter there is nothing to join to.
            let text = String(delta.drop(while: \.isWhitespace))
            guard !text.isEmpty else { return }
            chapters.append(TranscriptChapter(id: UUID(), date: now, text: text))
            write(Self.header(for: now, first: fileIsEmpty) + text)
        }
        lastAppend = now
    }

    func copy(_ chapter: TranscriptChapter) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chapter.text, forType: .string)
    }

    func openFile() {
        ensureFile()
        NSWorkspace.shared.open(fileURL)
    }

    func revealFile() {
        ensureFile()
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: - File

    private var fileIsEmpty: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        return size == 0
    }

    private static func header(for date: Date, first: Bool) -> String {
        (first ? "" : "\n\n") + "[" + headerFormatter.string(from: date) + "]\n"
    }

    private func ensureFile() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    private func write(_ text: String) {
        if handle == nil {
            ensureFile()
            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                self.handle = handle
            } catch {
                logger.error("Could not open transcript log: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        do {
            try handle?.write(contentsOf: Data(text.utf8))
        } catch {
            logger.error("Could not append to transcript log: \(error.localizedDescription, privacy: .public)")
            handle = nil
        }
    }

    /// The file as chapters. Header lines are the only structure; everything
    /// between two of them is one chapter's text.
    static func parse(_ text: String) -> [TranscriptChapter] {
        var chapters: [TranscriptChapter] = []
        var date: Date?
        var lines: [Substring] = []
        func close() {
            guard let date else { return }
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                chapters.append(TranscriptChapter(id: UUID(), date: date, text: body))
            }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let headerDate = headerDate(of: line) {
                close()
                date = headerDate
                lines = []
            } else if date != nil {
                lines.append(line)
            }
        }
        close()
        return chapters
    }

    private static func headerDate(of line: Substring) -> Date? {
        guard line.count == 21, line.hasPrefix("["), line.hasSuffix("]") else { return nil }
        return headerFormatter.date(from: String(line.dropFirst().dropLast()))
    }

    // MARK: - Legacy

    private struct LegacyRecord: Decodable {
        let text: String
        let date: Date
    }

    /// The dictations kept in UserDefaults by earlier builds become the first
    /// chapters of the file, oldest first, so nothing already recovered once is
    /// lost to the change of format.
    private func migrateLegacyHistory(from defaults: UserDefaults) {
        guard let data = defaults.data(forKey: Self.legacyDefaultsKey) else { return }
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            return
        }
        guard let records = try? JSONDecoder().decode([LegacyRecord].self, from: data),
              !records.isEmpty else {
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            return
        }
        var text = ""
        for record in records.reversed() {
            text += Self.header(for: record.date, first: text.isEmpty) + record.text
        }
        ensureFile()
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            logger.info("Moved \(records.count, privacy: .public) earlier dictations into the transcript log")
        } catch {
            logger.error("Could not migrate transcript history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
