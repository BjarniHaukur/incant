import Combine
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var accessibilityGranted = false
    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color(red: 0.005, green: 0.008, blue: 0.02)
            RadialGradient(
                colors: [Color(red: 0.035, green: 0.09, blue: 0.22).opacity(0.72), .clear],
                center: UnitPoint(x: 0.5, y: 0.2),
                startRadius: 0,
                endRadius: 380
            )

            VStack(spacing: 0) {
                RecorderOrbView(model: model, orbDiameter: 220, canvasSize: 270)
                    .frame(height: 250)

                Text("Incant")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .tracking(-0.8)
                Text("Your voice, directly at the cursor.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.52))
                    .padding(.top, 5)

                VStack(spacing: 1) {
                    apiKeyRow
                    Divider().overlay(.white.opacity(0.07)).padding(.leading, 54)
                    accessibilityRow
                }
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.075), lineWidth: 1)
                }
                .padding(.top, 28)

                HStack(spacing: 10) {
                    keycap("⌘")
                    keycap("⇧")
                    keycap("SPACE", wide: true)
                }
                .padding(.top, 24)
                Text("Press once to speak · press again to stop")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.top, 9)

                Spacer(minLength: 22)
            }
            .padding(.horizontal, 34)
            .padding(.top, 12)
        }
        .frame(width: 520, height: 650)
        .preferredColorScheme(.dark)
        .onAppear { accessibilityGranted = TextInserter.isAccessibilityGranted }
        .onReceive(permissionTimer) { _ in accessibilityGranted = TextInserter.isAccessibilityGranted }
    }

    @ViewBuilder
    private var apiKeyRow: some View {
        HStack(spacing: 14) {
            statusOrb(ready: model.hasAPIKey, color: .blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenAI API key").font(.system(size: 14, weight: .medium))
                if model.usesEnvironmentKey {
                    Text("Loaded from your environment")
                        .font(.caption).foregroundStyle(.white.opacity(0.42))
                } else if model.hasAPIKey && model.apiKeyDraft.isEmpty {
                    Text("Stored securely in Keychain")
                        .font(.caption).foregroundStyle(.white.opacity(0.42))
                } else {
                    SecureField("sk-…", text: $model.apiKeyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Spacer(minLength: 10)
            if !model.usesEnvironmentKey && (!model.hasAPIKey || !model.apiKeyDraft.isEmpty) {
                Button("Save") { model.saveAPIKey() }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.blue)
            } else {
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 16).frame(minHeight: 74)
    }

    private var accessibilityRow: some View {
        HStack(spacing: 14) {
            statusOrb(ready: accessibilityGranted, color: .cyan)
            VStack(alignment: .leading, spacing: 4) {
                Text("Type at the cursor").font(.system(size: 14, weight: .medium))
                Text(accessibilityGranted ? "Accessibility is ready" : "Allow Incant to insert live text")
                    .font(.caption).foregroundStyle(.white.opacity(0.42))
            }
            Spacer()
            if accessibilityGranted {
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.cyan)
            } else {
                Button("Allow") { model.requestAccessibility() }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.cyan)
            }
        }
        .padding(.horizontal, 16).frame(minHeight: 74)
    }

    private func statusOrb(ready: Bool, color: Color) -> some View {
        Circle()
            .fill(ready ? color : .white.opacity(0.12))
            .frame(width: 9, height: 9)
            .shadow(color: ready ? color.opacity(0.8) : .clear, radius: 6)
            .frame(width: 24)
    }

    private func keycap(_ text: String, wide: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.74))
            .frame(width: wide ? 64 : 34, height: 30)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.09)) }
    }
}
