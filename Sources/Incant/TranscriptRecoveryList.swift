import SwiftUI

/// The earlier dictations, as a way back into the box under the orb — not as an
/// archive Incant keeps about you. Picking one stages it and closes.
struct TranscriptRecoveryList: View {
    @ObservedObject var history: TranscriptHistory
    let stage: (TranscriptRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(history.records) { record in
                        Button { stage(record) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(record.date, format: .relative(presentation: .numeric))
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.45))
                                    if record.delivered, !record.destination.isEmpty {
                                        Text(record.destination)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.white.opacity(0.3))
                                    } else if !record.delivered {
                                        // The reason any of this exists.
                                        Text("never landed")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Color.orange.opacity(0.7))
                                    }
                                    Spacer()
                                }
                                Text(record.text)
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
                    }
                }
                .padding(8)
            }

            Divider().overlay(.white.opacity(0.08))
            HStack {
                Text("\(history.records.count) kept")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                Button("Forget all") { history.forgetEverything() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: 280, height: min(320, 60 + Double(history.records.count) * 52))
        .background(Color(red: 0.01, green: 0.014, blue: 0.03))
        .preferredColorScheme(.dark)
    }
}
