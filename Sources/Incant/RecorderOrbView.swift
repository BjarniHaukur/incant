import SwiftUI

struct RecorderOrbView: View {
    @ObservedObject var model: AppModel
    var orbDiameter: CGFloat = 150
    var canvasSize: CGFloat = 220
    var showsBufferedText = true
    @State private var composerHovered = false
    @State private var copied = false
    @State private var composerHeight: CGFloat = 36

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
        ZStack {
            BufferedTranscriptEditor(text: $model.bufferedText, contentHeight: $composerHeight)
                .frame(width: 272, height: composerHeight)

            HStack {
                hoverButton(
                    systemName: model.autoInsertEnabled ? "text.cursor" : "pause.fill",
                    active: model.autoInsertEnabled,
                    help: model.autoInsertEnabled
                        ? "Auto type is on — click to hold text in Incant"
                        : "Auto type is off — click to type the draft at the cursor"
                ) {
                    model.setAutoInsertEnabled(!model.autoInsertEnabled)
                }

                Spacer()

                hoverButton(
                    systemName: copied ? "checkmark" : "doc.on.doc",
                    active: copied,
                    help: "Copy transcript"
                ) {
                    model.copyBufferedText()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(900))
                        copied = false
                    }
                }
                .disabled(model.bufferedText.isEmpty)
            }
            .padding(.horizontal, 7)
            .opacity(composerHovered ? 1 : 0)
        }
        .frame(width: 284, height: composerHeight + 10)
        .background(.black.opacity(composerHovered ? 0.78 : 0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.blue.opacity(composerHovered ? 0.34 : 0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 12, y: 5)
        .animation(.easeOut(duration: 0.15), value: composerHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.86), value: composerHeight)
        .onHover { composerHovered = $0 }
    }

    private func hoverButton(
        systemName: String,
        active: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? Color.cyan : Color.white.opacity(0.7))
                .frame(width: 24, height: 24)
                .background(
                    active ? Color.blue.opacity(0.2) : Color.white.opacity(0.055),
                    in: Circle()
                )
                .overlay {
                    Circle().stroke(active ? Color.cyan.opacity(0.32) : .white.opacity(0.06))
                }
        }
        .buttonStyle(.plain)
        .help(help)
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
