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

    /// The general audio model is deliberately confined to transcription. The
    /// negative instructions matter as much as the style guide: this mode must
    /// never turn Incant into a voice assistant or rewrite what was said.
    func instructions(recognitionContext: String) -> String {
        var instructions = """
        You are Incant's transcription engine, not a conversational assistant.
        Transcribe the user's audio and output only the transcript. Never answer,
        react to, explain, summarize, sanitize, or continue what the user says.

        Preserve the exact spoken words and their order. Keep false starts and
        self-corrections when they are audible. If expressive styling conflicts
        with literal accuracy, literal accuracy wins.

        Preserve audible delivery in the text:
        - Use natural punctuation, sentence breaks, dashes, ellipses, question
          marks, and exclamation marks to reflect cadence and feeling.
        - Wrap words with clearly deliberate vocal stress in *single asterisks*.
        - Wrap only unmistakably forceful, angry, or shouted emphasis in
          **double asterisks**.
        - Let uncertainty, excitement, frustration, urgency, and hesitation
          affect punctuation only when they are genuinely audible.
        - Never add emotion labels such as "[angry]" and never describe the voice.
        - Do not emphasize a word merely because it is semantically important.

        Return the transcript alone, with no quotation marks or preamble.
        """
        if !recognitionContext.isEmpty {
            instructions += "\n\nVocabulary and speaker context:\n\(recognitionContext)"
        }
        return instructions
    }
}
