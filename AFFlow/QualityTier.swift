import Foundation

/// One quality ladder, two rungs, and one place that says what each rung runs.
///
/// `docs/launch-v1-plan.md`, settled 2026-08-29. A non-technical friend should
/// not have to choose between seven speech models and four cleanup models on
/// their first run; they should be offered **Starter**, which works the moment
/// the app opens because the DMG carries it, and **Full**, which is the best
/// their machine handles. Per-model control stays in Settings for anyone who
/// wants it, and this type does not replace it.
///
/// **This file is the only place that says which models a tier runs.** Same
/// discipline as `AppSupportDirectory` for the data folder and
/// `MeetingsVisibility` for the v1 scope gate: a second copy is a second thing
/// to update, and the copy that does not get updated is the one that ships.
///
/// THREE MISTAKES THIS LADDER COULD MAKE, all of which this project has already
/// made once, and all of which `QualityTierTests` now pins:
///
///   1. **An English-only Starter.** The fork's default was `whisper-small.en`
///      and until 2026-07-19 a fresh install silently failed roughly a quarter
///      of Andrew's real dictation, because a quarter of it is Russian.
///      Starter is what a stranger gets before choosing anything, so an
///      English-only Starter would ship that regression to every friend.
///   2. **Sorting the ladder by file size.** Ledger item 16: the 954 MB
///      `large-v3-turbo` build fails Russian language identification where the
///      632 MB build does not. Bigger is not better, and the top rung is
///      chosen on evidence rather than on megabytes.
///   3. **Bundling something the downloader cannot verify.** The DMG carries
///      Starter, so Starter's cleanup model must be one `model_catalogue.py`
///      can pin by URL, SHA-256 and exact byte count.
enum QualityTier: String, CaseIterable, Identifiable {
    case starter
    case full

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .starter: "Starter"
        case .full: "Full"
        }
    }

    /// One sentence, in the register the model screen uses: what it does for
    /// you, not what it is made of.
    var oneLine: String {
        switch self {
        case .starter:
            "Works right now, offline. It came with the app."
        case .full:
            "The best quality this Mac handles. It downloads once."
        }
    }

    // MARK: - Speech

    /// Starter speaks both his languages, deliberately.
    ///
    /// `whisperSmallMultilingual`, never `whisperSmallEnglish`. They are the
    /// same size on disk, so the English-only build buys nothing and costs a
    /// quarter of the dictation of anyone who speaks Russian.
    static let starterSpeechModelID = SpeechModelCatalog.whisperSmallMultilingual.id

    /// Which speech model a launch-type load uses: app start, the walkthrough, and
    /// its Retry.
    ///
    /// A fresh install asks for turbo, the catalog default, which the DMG does not
    /// carry and the app cannot download. Until 2026-09-10 that failed on the first
    /// launch of every friend's Mac with the one model that WAS installed sitting
    /// unused. So when NO model has ever been chosen, the default cannot load, and
    /// Starter is installed, the answer is Starter.
    ///
    /// **A saved choice is never overridden**, even one that cannot load. An
    /// independent review found the first version replacing it permanently: one
    /// launch with his turbo folder missing would have left him on whisper-small for
    /// good, recorded only in a log line. A choice that cannot load now fails with
    /// its reason on screen, and he decides.
    ///
    /// Pure over plain values on purpose: the caller asks the disk and the saved
    /// settings, so this can be tested without either and holds no actor isolation.
    static func launchSpeechModelID(
        preferred: String,
        hasSavedChoice: Bool,
        preferredIsLoadable: Bool,
        starterIsInstalled: Bool
    ) -> String {
        (hasSavedChoice || preferredIsLoadable || !starterIsInstalled) ? preferred : starterSpeechModelID
    }

    /// **Open item 1 of the launch plan. RATIFIED by Andrew on 2026-08-30, on
    /// his own 26 days of dictation rather than on a fresh benchmark.**
    ///
    /// `large-v3-turbo` at 632 MB is the model he has actually been running:
    /// the runtime probe covers 3,620 dictations, 2,374 of them Russian, and
    /// none of them fell open to unrestricted language detection. The 954 MB
    /// build is the obvious "bigger" candidate and ledger item 16 records it
    /// failing Russian language identification, so the ladder would get worse
    /// by climbing.
    ///
    /// The evidence is real and at scale, and it is not a controlled bench: it
    /// compares one model against his history, not against alternatives on
    /// the same fixtures. He ratified it on that basis, so this is a settled
    /// answer, and a future bench that beats it re-opens the item rather than
    /// the item staying open until one exists.
    static let fullSpeechModelID = SpeechModelCatalog.whisperLargeV3Turbo.id

    var speechModelID: String {
        switch self {
        case .starter: Self.starterSpeechModelID
        case .full: Self.fullSpeechModelID
        }
    }

    // MARK: - Cleanup, which is the part that depends on the machine

    /// The same on every machine, because it ships inside the DMG. A tier whose
    /// bundled payload varied by host would not be a bundled payload.
    static let starterCleanupModel: LocalCleanupModelKind = .qwen35_0_8b_q4_k_m

    /// Below this, Full runs the 2B; at or above it, the 4B.
    ///
    /// **A THRESHOLD, NOT A MEASUREMENT.** The 4B weighs 2.74 GB on disk and
    /// wants roughly that again resident while it generates, so 16 GB is the
    /// first rung where it is comfortable beside a browser, a video call and
    /// the speech model. This is reasoning, not a benchmark, and the Phase 3
    /// harness is what will replace it with a measured number on Andrew's own
    /// Macs. Until then the screen says "estimated" and means it.
    static let fullTierLargeModelMinimumMemory: UInt64 = 16 * 1024 * 1024 * 1024

    func cleanupModel(physicalMemory: UInt64) -> LocalCleanupModelKind {
        switch self {
        case .starter:
            return Self.starterCleanupModel
        case .full:
            return physicalMemory >= Self.fullTierLargeModelMinimumMemory
                ? .qwen35_4b_q4_k_m
                : .qwen35_2b_q4_k_m
        }
    }

    func cleanupModel() -> LocalCleanupModelKind {
        cleanupModel(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    // MARK: - What to suggest

    /// What the model screen puts forward before the benchmark has run.
    ///
    /// Deliberately conservative: a machine that cannot comfortably hold the
    /// larger cleanup model is offered Starter. Full is never HIDDEN from it,
    /// per the launch plan's edge-case table; it is shown with its estimated
    /// number and discouraged, because a friend on an 8 GB MacBook Air should
    /// be told the truth rather than have the option taken away.
    static func recommended(physicalMemory: UInt64) -> QualityTier {
        physicalMemory >= fullTierLargeModelMinimumMemory ? .full : .starter
    }

    static func recommended() -> QualityTier {
        recommended(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }
}
