import Foundation

enum TranscriptionMode: String, CaseIterable, Identifiable {
    case direct
    case intonation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: "Direct"
        case .intonation: "Expressive"
        }
    }

    var summary: String {
        switch self {
        case .direct:
            "Faster"
        case .intonation:
            "Slightly slower, more emotive"
        }
    }

    func transcriptionPrompt(recognitionContext: String) -> String {
        guard self == .intonation else { return recognitionContext }
        var prompt = """
        Transcribe exactly. Preserve audible emotion with punctuation. Mark
        stressed words as *italic* and forceful, angry, or shouted words as
        **bold**. Output only what was spoken.
        """
        if !recognitionContext.isEmpty {
            prompt += "\n\nVocabulary and speaker context:\n\(recognitionContext)"
        }
        return prompt
    }
}
