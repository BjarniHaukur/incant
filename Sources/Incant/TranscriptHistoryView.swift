import SwiftUI

/// The list of kept dictations. Exists for one situation: a transcript went
/// somewhere unexpected and the words need to be found again.
struct TranscriptHistoryView: View {
    @ObservedObject var history: TranscriptHistory
    @Environment(\.dismiss) private var dismiss
    @State private var copied: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("History")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("Every dictation long enough to come back for, and where it went.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if history.records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.25))
                    Text("Nothing kept yet")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Dictations under \(TranscriptHistory.minimumCharacters) characters are never kept.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.28))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(history.records) { record in
                            row(record)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }

            HStack {
                if !history.records.isEmpty {
                    Button("Clear all") { history.forgetEverything() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
        .background(Color(red: 0.008, green: 0.012, blue: 0.026))
        .preferredColorScheme(.dark)
    }

    private func row(_ record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(record.date, format: .relative(presentation: .numeric))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.5))
                if record.delivered, !record.destination.isEmpty {
                    Text("→ \(record.destination)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                } else if !record.delivered {
                    // The case this whole screen was built for.
                    Text("never delivered")
                        .font(.caption)
                        .foregroundStyle(Color.orange.opacity(0.75))
                }
                Spacer()
                Text("\(record.text.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.25))
                Button {
                    history.copy(record)
                    copied = record.id
                    Task {
                        try? await Task.sleep(for: .milliseconds(1100))
                        if copied == record.id { copied = nil }
                    }
                } label: {
                    Image(systemName: copied == record.id ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(copied == record.id ? Color.teal : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Copy this transcript")
                Button {
                    history.forget(record)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
                .help("Forget this transcript")
            }

            Text(record.text)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(record.delivered ? 0.07 : 0.16), lineWidth: 1)
        }
    }
}
