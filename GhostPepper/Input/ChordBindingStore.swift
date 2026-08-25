import Foundation

final class ChordBindingStore {
    enum StoreError: Error, Equatable {
        /// **Carries the action it collided with**, so the interface can say
        /// whose shortcut it already is rather than only that something is
        /// wrong. The onboarding capture field needs to name the owner.
        case duplicateBinding(owner: ChordAction)
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func binding(for action: ChordAction) -> KeyChord? {
        guard let data = defaults.data(forKey: defaultsKey(for: action)) else { return nil }
        return try? decoder.decode(KeyChord.self, from: data)
    }

    func setBinding(_ chord: KeyChord?, for action: ChordAction) throws {
        if let chord {
            for otherAction in ChordAction.allCases where otherAction != action {
                if binding(for: otherAction) == chord {
                    throw StoreError.duplicateBinding(owner: otherAction)
                }
            }

            defaults.set(try encoder.encode(chord), forKey: defaultsKey(for: action))
            return
        }

        defaults.removeObject(forKey: defaultsKey(for: action))
    }

    private func defaultsKey(for action: ChordAction) -> String {
        "chordBinding.\(action.rawValue)"
    }
}
