import Combine
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var accessibilityGranted = false
    @State private var showingRecognitionContext = false
    @State private var editingAPIKey = false
    @State private var hoveringAPIKeyStatus = false
    @FocusState private var apiKeyFieldFocused: Bool
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
        .onAppear {
            accessibilityGranted = TextInserter.isAccessibilityGranted
            // On a first run the field is the only thing to do here, so a pasted
            // key should land without hunting for the caret first.
            apiKeyFieldFocused = !model.hasAPIKey
        }
        .onReceive(permissionTimer) { _ in accessibilityGranted = TextInserter.isAccessibilityGranted }
        .sheet(isPresented: $showingRecognitionContext) {
            RecognitionContextEditor(model: model)
        }
    }

    /// A settled key used to be a dead end: the row showed a line of text and a
    /// checkmark, and the field only came back when the draft was non-empty, which
    /// needed a field to type into. The checkmark is now the way back in.
    private var isEditingAPIKey: Bool {
        editingAPIKey || !model.hasAPIKey || !model.apiKeyDraft.isEmpty
    }

    /// Where the key in use is coming from, said plainly, because an environment
    /// variable and a Keychain entry are easy to confuse when only one can win.
    private var apiKeySource: String {
        if model.hasStoredKey {
            return model.hasEnvironmentKey
                ? "Stored in Keychain, overriding your environment"
                : "Stored securely in Keychain"
        }
        return "Loaded from your environment"
    }

    @ViewBuilder
    private var apiKeyRow: some View {
        HStack(spacing: 14) {
            statusOrb(ready: model.hasAPIKey, color: .blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenAI API key").font(.system(size: 14, weight: .medium))
                if isEditingAPIKey {
                    SecureField("sk-…", text: $model.apiKeyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        .focused($apiKeyFieldFocused)
                        .onSubmit { saveAPIKey() }
                    if let error = model.apiKeyError {
                        Text(error)
                            .font(.caption).foregroundStyle(.orange.opacity(0.85))
                    }
                } else {
                    Text(apiKeySource)
                        .font(.caption).foregroundStyle(.white.opacity(0.42))
                }
            }
            Spacer(minLength: 10)
            if isEditingAPIKey {
                if model.hasStoredKey, model.hasEnvironmentKey {
                    Button("Use environment") {
                        model.useEnvironmentKey()
                        editingAPIKey = false
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .help("Forget the stored key and fall back to OPENAI_API_KEY")
                }
                if model.hasAPIKey {
                    Button("Cancel") {
                        model.apiKeyDraft = ""
                        editingAPIKey = false
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                }
                // Never disabled: a greyed-out Save with no explanation is how a
                // first run dead-ends. Pressing it always answers.
                Button("Save") { saveAPIKey() }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.blue)
            } else {
                // The checkmark is the way back in: hovering it offers the pencil,
                // so a settled key can be replaced without a control sitting there
                // asking to be used.
                Button { editingAPIKey = true } label: {
                    Image(systemName: hoveringAPIKeyStatus ? "pencil" : "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(hoveringAPIKeyStatus ? .white.opacity(0.85) : .white.opacity(0.42))
                        .frame(width: 26, height: 22)
                        .background(
                            .white.opacity(hoveringAPIKeyStatus ? 0.14 : 0),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(.white.opacity(hoveringAPIKeyStatus ? 0.16 : 0), lineWidth: 0.7)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveringAPIKeyStatus = $0 }
                .help("Use a different key")
            }
        }
        .padding(.horizontal, 16).frame(minHeight: 68)
    }

    private func saveAPIKey() {
        model.saveAPIKey()
        if model.keySaved { editingAPIKey = false }
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
