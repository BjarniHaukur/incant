import Combine
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var accessibilityGranted = false
    @State private var showingRecognitionContext = false
    @State private var showingHistory = false
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
                RecorderOrbView(model: model, orbDiameter: 220, canvasSize: 270, showsBufferedText: false)
                    .frame(height: 250)

                Text("Incant")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .tracking(-0.8)

                VStack(spacing: 1) {
                    apiKeyRow
                    Divider().overlay(.white.opacity(0.07)).padding(.leading, 54)
                    accessibilityRow
                    Divider().overlay(.white.opacity(0.07)).padding(.leading, 54)
                    shortcutRow
                    Divider().overlay(.white.opacity(0.07)).padding(.leading, 54)
                    recognitionContextRow
                    Divider().overlay(.white.opacity(0.07)).padding(.leading, 54)
                    historyRow
                }
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.075), lineWidth: 1)
                }
                .padding(.top, 28)

                Text("Press once to speak · press again to stop")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.top, 18)

                Spacer(minLength: 22)
            }
            .padding(.horizontal, 34)
            .padding(.top, 12)
        }
        .frame(width: 520, height: 700)
        .preferredColorScheme(.dark)
        .onAppear { accessibilityGranted = TextInserter.isAccessibilityGranted }
        .onReceive(permissionTimer) { _ in accessibilityGranted = TextInserter.isAccessibilityGranted }
        .sheet(isPresented: $showingRecognitionContext) {
            RecognitionContextEditor(model: model)
        }
        .sheet(isPresented: $showingHistory) {
            TranscriptHistoryView(history: model.history)
        }
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
        .padding(.horizontal, 16).frame(minHeight: 68)
    }

    private var accessibilityRow: some View {
        HStack(spacing: 14) {
            statusOrb(ready: accessibilityGranted && model.autoInsertEnabled, color: .cyan)
            VStack(alignment: .leading, spacing: 4) {
                Text("Type at the cursor").font(.system(size: 14, weight: .medium))
                Text(cursorTypingDescription)
                    .font(.caption).foregroundStyle(.white.opacity(0.42))
            }
            Spacer()
            if accessibilityGranted {
                Button(model.autoInsertEnabled ? "On" : "Off") {
                    model.setAutoInsertEnabled(!model.autoInsertEnabled)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(model.autoInsertEnabled ? .cyan : .gray)
            } else {
                Button("Allow") { model.requestAccessibility() }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.cyan)
            }
        }
        .padding(.horizontal, 16).frame(minHeight: 68)
    }

    private var cursorTypingDescription: String {
        guard accessibilityGranted else { return "Allow Incant to insert live text" }
        return model.autoInsertEnabled ? "Stream words at the current cursor" : "Hold words in Incant for editing"
    }

    private var shortcutRow: some View {
        HStack(spacing: 14) {
            statusOrb(ready: model.shortcutError == nil, color: .purple)
            VStack(alignment: .leading, spacing: 4) {
                Text("Global shortcut").font(.system(size: 14, weight: .medium))
                Text(model.shortcutError ?? "Toggle Incant from anywhere")
                    .font(.caption)
                    .foregroundStyle(model.shortcutError == nil ? .white.opacity(0.42) : .red.opacity(0.8))
            }
            Spacer()
            ShortcutRecorder(shortcut: model.shortcut) { model.updateShortcut($0) }
        }
        .padding(.horizontal, 16).frame(minHeight: 64)
    }

    private var recognitionContextRow: some View {
        Button { showingRecognitionContext = true } label: {
            HStack(spacing: 14) {
                statusOrb(ready: !model.recognitionPrompt.isEmpty, color: .indigo)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recognition context").font(.system(size: 14, weight: .medium))
                    Text(model.recognitionPromptSummary)
                        .font(.caption).foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).frame(minHeight: 64)
    }

    private var historyRow: some View {
        Button { showingHistory = true } label: {
            HStack(spacing: 14) {
                statusOrb(ready: model.history.isWorthShowing, color: .teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("History").font(.system(size: 14, weight: .medium))
                    Text(historySummary)
                        .font(.caption).foregroundStyle(.white.opacity(0.42))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).frame(minHeight: 64)
    }

    private var historySummary: String {
        let count = model.history.records.count
        switch count {
        case 0: return "Dictations you can go back and find"
        case 1: return "1 dictation kept"
        default: return "\(count) dictations kept"
        }
    }

    private func statusOrb(ready: Bool, color: Color) -> some View {
        Circle()
            .fill(ready ? color : .white.opacity(0.12))
            .frame(width: 9, height: 9)
            .shadow(color: ready ? color.opacity(0.8) : .clear, radius: 6)
            .frame(width: 24)
    }

}

private struct RecognitionContextEditor: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Recognition context")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("Tell Incant anything that helps it understand you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $draft)
                .font(.system(size: 14, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.09), lineWidth: 1)
                }

            HStack {
                Text("For example: “I discuss cmux, Codex, and Verse. My name is Bjarni.”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveRecognitionPrompt(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480, height: 390)
        .background(Color(red: 0.008, green: 0.012, blue: 0.026))
        .preferredColorScheme(.dark)
        .onAppear { draft = model.recognitionPrompt }
    }
}
