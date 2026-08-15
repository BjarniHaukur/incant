import SwiftUI

struct RecorderOrbView: View {
    /// The stone's own light, used wherever the chrome around it needs a colour.
    static let stoneLight = Color(red: 0.16, green: 0.4, blue: 0.95)

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
                    WindowDragSurface()
                        .frame(width: orbDiameter, height: orbDiameter)
                        .clipShape(Circle())
                }
                .frame(width: canvasSize, height: canvasSize)
                .contentShape(Circle())

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
        let hasText = !model.bufferedText.isEmpty
        return HStack(spacing: 7) {
            hoverButton(
                systemName: "gearshape.fill",
                active: false,
                help: "Open Incant settings"
            ) {
                model.openSettings()
            }

            transcriptField
                .frame(width: hasText ? 232 : 0)
                .opacity(hasText ? 1 : 0)
                .clipped()
                .allowsHitTesting(hasText)

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
        .frame(width: 290, height: composerHeight + 10)
        .opacity(composerHovered ? 1 : 0.88)
        .animation(.easeOut(duration: 0.15), value: composerHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.86), value: composerHeight)
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: hasText)
        .onHover { composerHovered = $0 }
    }

    private var transcriptField: some View {
        BufferedTranscriptEditor(text: $model.bufferedText, contentHeight: $composerHeight)
            .frame(width: 232, height: composerHeight)
            .background(.black.opacity(composerHovered ? 0.78 : 0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Self.stoneLight.opacity(composerHovered ? 0.34 : 0.16), lineWidth: 1)
            }
            .shadow(color: Self.stoneLight.opacity(composerHovered ? 0.09 : 0.03), radius: 16)
    }

    private func hoverButton(
        systemName: String,
        active: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: active
                            ? [Color(red: 0.3, green: 0.6, blue: 1).opacity(0.5), Self.stoneLight.opacity(0.32), Color.black.opacity(0.9)]
                            : [Color.white.opacity(0.18), Self.stoneLight.opacity(0.1), Color.black.opacity(0.92)],
                        center: UnitPoint(x: 0.36, y: 0.28),
                        startRadius: 0,
                        endRadius: 13
                    ))
                Image(systemName: systemName)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(active ? Color.white.opacity(0.94) : Color.white.opacity(0.66))
            }
            .frame(width: 20, height: 20)
            .overlay { Circle().stroke(.white.opacity(active ? 0.24 : 0.09), lineWidth: 0.7) }
            .shadow(color: active ? Color(red: 0.3, green: 0.6, blue: 1).opacity(0.28) : .black.opacity(0.5), radius: 5)
        }
        .buttonStyle(.plain)
        .opacity(composerHovered ? 1 : 0)
        .help(help)
    }

    private func ambientGlow(time: TimeInterval) -> some View {
        let voice = Double(model.level)
        let irregularBreath = sin(time * 0.73) * sin(time * 0.41 + 1.7)
        let loading = model.phase == .connecting ? 0.5 + 0.5 * sin(time * 2.4) : 0
        return Circle()
            .fill(glowColor.opacity(glowOpacity + voice * 0.16 + loading * 0.06))
            .frame(width: orbDiameter * 1.06, height: orbDiameter * 1.06)
            .blur(radius: 22 - voice * 5)
            .scaleEffect(1 + irregularBreath * 0.012 + voice * 0.07 + loading * 0.025)
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
        case .finishing: return Color(red: 0.15, green: 0.24, blue: 0.7)
        case .success: return Color(red: 0.05, green: 0.9, blue: 0.65)
        // The uncorrupted stone: what it throws on the desk while it waits.
        case .idle, .listening: return Color(red: 0.05, green: 0.28, blue: 0.9)
        }
    }
}
