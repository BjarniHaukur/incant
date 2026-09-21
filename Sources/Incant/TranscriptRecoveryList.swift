import SwiftUI

/// The transcript log, newest chapter first, as a way back into the box under
/// the orb. Picking a chapter stages it and closes; the file itself is a click
/// away for anything longer than the box wants to hold.
struct TranscriptRecoveryList: View {
    @ObservedObject var log: TranscriptLog
    let stage: (TranscriptChapter) -> Void

    private var chapters: [TranscriptChapter] { log.chapters.suffix(200).reversed() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(chapters) { chapter in
                        Button { stage(chapter) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(chapter.date, format: .relative(presentation: .numeric))
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.45))
                                    Text(chapter.date, format: .dateTime.hour().minute())
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.3))
                                    Spacer()
                                    Text("\(chapter.text.count)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.25))
                                }
                                Text(chapter.text)
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Put back into the box")
                    }
                }
                .padding(8)
            }

            Divider().overlay(.white.opacity(0.08))
            HStack {
                Text("\(log.chapters.count) chapters")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                Button("Open log") { log.openFile() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.5))
                    .help(TranscriptLog.fileURL.path)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: 280, height: min(320, 60 + Double(chapters.count) * 52))
        .background(Color(red: 0.01, green: 0.014, blue: 0.03))
        .preferredColorScheme(.dark)
    }
}
