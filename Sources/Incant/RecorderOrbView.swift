import SwiftUI

struct RecorderOrbView: View {
    @ObservedObject var model: AppModel
    var orbDiameter: CGFloat = 150
    var canvasSize: CGFloat = 220
    var showsBufferedText = true
    @State private var composerHovered = false
    @State private var copied = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            VStack(spacing: -20) {
                ZStack {
                    ambientGlow(time: time)
                    MetalFluidOrbView(model: model)
                        .frame(width: orbDiameter, height: orbDiameter)
                        .clipShape(Circle())
                        .scaleEffect(orbScale(at: time))
                }
                .frame(width: canvasSize, height: canvasSize)
                .allowsHitTesting(false)

                if showsBufferedText {
                    transcriptComposer
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(width: max(canvasSize, 290))
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: showsBufferedText && model.bufferedText.isEmpty)
        }
    }

    private var transcriptComposer: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                BufferedTranscriptEditor(text: $model.bufferedText)
                    .frame(width: 264, height: 76)

                Button {
                    model.copyBufferedText()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(900))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.78))
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 7))
                .opacity(composerHovered && !model.bufferedText.isEmpty ? 1 : 0)
                .padding(6)
                .help("Copy transcript")
            }

            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { model.autoInsertEnabled },
                    set: { model.setAutoInsertEnabled($0) }
                )) {
                    Text("Auto type")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .foregroundStyle(.white.opacity(0.58))

                Spacer(minLength: 4)

                Button("Insert") { model.insertBufferedText() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .tint(.blue.opacity(0.82))
                    .disabled(model.bufferedText.isEmpty || !model.hasInsertionTarget)
                    .help(model.hasInsertionTarget ? "Insert at the last text cursor" : "Click a text field first")
            }
            .frame(width: 264)
        }
        .padding(10)
        .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.blue.opacity(0.24), lineWidth: 1)
        }
        .onHover { composerHovered = $0 }
    }

    private func ambientGlow(time: TimeInterval) -> some View {
        let voice = Double(model.level)
        let irregularBreath = sin(time * 0.73) * sin(time * 0.41 + 1.7)
        let loading = model.phase == .connecting ? 0.5 + 0.5 * sin(time * 2.4) : 0
        return Circle()
            .fill(glowColor.opacity(glowOpacity + voice * 0.035 + loading * 0.06))
            .frame(width: orbDiameter * 1.06, height: orbDiameter * 1.06)
            .blur(radius: 22 - voice * 2)
            .scaleEffect(1 + irregularBreath * 0.012 + voice * 0.025 + loading * 0.025)
    }

    private func orbScale(at time: TimeInterval) -> CGFloat {
        switch model.phase {
        case .connecting:
            return 0.988 + CGFloat(0.5 + 0.5 * sin(time * 2.4)) * 0.018
        case .finishing: return 0.978
        case .success: return 0.95
        case .idle, .listening, .error: return 1
        }
    }

    private var glowOpacity: Double {
        switch model.phase {
        case .error: return 0.22
        case .connecting: return 0.14
        case .success: return 0.18
        case .idle, .listening, .finishing: return 0.1
        }
    }

    private var glowColor: Color {
        switch model.phase {
        case .error: return Color(red: 1, green: 0.08, blue: 0.03)
        case .connecting: return Color(red: 0.33, green: 0.24, blue: 1)
        case .finishing: return Color(red: 0.15, green: 0.28, blue: 0.8)
        case .success: return Color(red: 0.05, green: 0.9, blue: 0.65)
        case .idle, .listening: return Color(red: 0.02, green: 0.38, blue: 1)
        }
    }
}
