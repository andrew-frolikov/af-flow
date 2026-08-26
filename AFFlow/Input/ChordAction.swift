import Foundation

enum ChordAction: String, CaseIterable, Codable {
    case pushToTalk
    case toggleToTalk

    /// What to call this action when telling someone their chosen chord is
    /// already taken. "That's already your hands-free shortcut" is actionable;
    /// "duplicateBinding" is not.
    var spokenName: String {
        switch self {
        case .pushToTalk: "push-to-talk shortcut"
        case .toggleToTalk: "hands-free shortcut"
        }
    }
}
