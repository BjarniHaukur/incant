import Foundation

enum TranscriptionMode: String, CaseIterable, Identifiable {
    case direct
    case accurate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: "Live"
        case .accurate: "Accurate"
        }
    }

    var summary: String {
        switch self {
        case .direct:
            "Responsive live text"
        case .accurate:
            "More context, can reduce mishearing"
        }
    }

    var delay: String {
        switch self {
        case .direct: "low"
        case .accurate: "medium"
        }
    }
}
