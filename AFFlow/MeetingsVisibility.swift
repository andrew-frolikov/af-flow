import Foundation

/// One place decides whether any meeting surface exists in this build.
///
/// v1 ships DICTATION ONLY. `docs/launch-v1-plan.md`, settled 2026-08-29:
/// meetings are hidden behind an internal flag, their tests keep running, and
/// they return in v1.x. The reason is not that meetings are broken; it is that
/// a friend installing a dictation app should not meet a half-finished second
/// product, and STATE.md still lists three open meeting defects.
///
/// **THE FLAG IS THE KEY THAT ALREADY EXISTED, and reusing it is the point.**
/// `meetingTranscriptEnabled` already defaults to false, so a fresh install
/// already hid everything; Andrew's own stored value is true, so his meetings
/// keep working with no migration and without asking him to run anything. What
/// changes for v1 is that the only control that WROTE it, the Settings toggle,
/// is gone. That is what "internal flag, no UI to enable it" means here, and
/// `MeetingsHiddenInV1Tests` fails if a control to write it comes back.
///
/// A second key would have been a second thing to keep in step, and this
/// project has already paid for that once: three `legacy*` constants and a
/// folder name that disagreed with itself for 24 days.
///
/// Turning it on by hand, which is the documented internal route:
///
///     defaults write com.frolikov.afflow meetingTranscriptEnabled -bool true
///
/// Read through `UserDefaults` rather than through `AppState` because
/// `AFFlowSection.visible` is a static on an enum and has no app state to ask.
///
/// **Only `MenuBarView` declares its own `@AppStorage` for this key, and that
/// is on purpose rather than an oversight.** `@AppStorage` on an
/// ObservableObject class never fires `objectWillChange`, so a view gated on
/// `appState.meetingTranscriptEnabled` would not redraw when the key changes;
/// the menu bar needs that redraw because it is rebuilt while the app runs.
/// Every other consumer here reads the static and therefore picks the new value
/// up at the next launch, not the next render. That is the right trade for a
/// flag flipped by `defaults write` roughly never, and stating it beats an
/// earlier version of this comment which claimed a discipline the consumers did
/// not keep. Review caught that on 2026-08-30.
enum MeetingsVisibility {
    /// The one spelling of the key. Nothing else may write this string.
    static let defaultsKey = "meetingTranscriptEnabled"

    /// False when the key has never been written, which is every fresh install.
    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    // MARK: - Copy that has to change when meetings are hidden
    //
    // Hiding a section does not hide the words. A sweep on 2026-08-30 found
    // three places outside any meeting view that still named meetings to a
    // dictation-only user: the History search box, and two labels in the Models
    // sidebar. They live here rather than at their call sites so the guarantee
    // is a test over two values instead of a scan over two files, and so the
    // next one has an obvious home.

    /// Placeholder in the History search box, a section every dictation user opens.
    static var historySearchPlaceholder: String {
        isOn ? "Search dictations and meetings" : "Search dictations"
    }

    /// The capability chips on a cleanup model's card in the Models sidebar.
    /// A v1 user choosing a model should not be sold a capability v1 hides.
    static var cleanupModelCapabilities: [String] {
        isOn ? ["cleanup", "meeting summary"] : ["cleanup"]
    }
}
