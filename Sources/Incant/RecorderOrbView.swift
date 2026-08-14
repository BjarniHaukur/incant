import SwiftUI

struct RecorderOrbView: View {
    @ObservedObject var model: AppModel
    var orbDiameter: CGFloat = 150
    var canvasSize: CGFloat = 220

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

                if !model.bufferedText.isEmpty {
                    Text(model.bufferedTextPreview)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 238, alignment: .leading)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(Color.blue.opacity(0.24), lineWidth: 1)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(width: max(canvasSize, 270))
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: model.bufferedText.isEmpty)
        }
        .allowsHitTesting(false)
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
        case .finishing: return Color(red: 0.15, green: 0.28, blue: 0.8)
        case .success: return Color(red: 0.05, green: 0.9, blue: 0.65)
        case .idle, .listening: return Color(red: 0.02, green: 0.38, blue: 1)
        }
    }
}
