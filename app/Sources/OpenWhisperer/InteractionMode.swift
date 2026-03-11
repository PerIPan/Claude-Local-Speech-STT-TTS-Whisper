import Foundation

/// Voice interaction mode — determines how recording is triggered.
enum InteractionMode: String, CaseIterable {
    case pressToTalk = "pressToTalk"
    case holdToTalk = "holdToTalk"
    case handsFree = "handsFree"

    var label: String {
        switch self {
        case .pressToTalk: return "Press-to-Talk"
        case .holdToTalk: return "Hold-to-Talk"
        case .handsFree: return "Hands-Free"
        }
    }

    var description: String {
        switch self {
        case .pressToTalk: return "press key to start, press again to stop"
        case .holdToTalk: return "hold key to record, release to transcribe"
        case .handsFree: return "say \"initiate\" to record, \"hold on\" to interrupt, simply keep silent to transcribe"
        }
    }

    func save() {
        try? rawValue.write(to: Paths.interactionMode, atomically: true, encoding: .utf8)
    }

    static func load() -> InteractionMode {
        guard let raw = try? String(contentsOf: Paths.interactionMode, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let mode = InteractionMode(rawValue: raw) else {
            return .holdToTalk
        }
        return mode
    }
}
