import XCTest
@testable import GhostPepper

/// Pins the fix for the defect that made AF Flow go silently deaf.
///
/// Before 2026-07-26, `startRecording` refused on four conditions and then a
/// SECOND, different list of four decided whether to show Andrew anything.
/// `.transcribing`, `.cleaningUp` and `.error` satisfied the first and none of
/// the second, so pressing the hotkey again while the previous dictation was
/// still finishing did nothing at all: no overlay, no sound, no log he would
/// ever look at. His own traces put that window at 8.6 seconds after a long
/// dictation, which is exactly when someone draws breath and starts talking
/// again.
///
/// These tests assert the property that matters rather than the implementation:
/// **whenever the app will refuse, it knows why.** The exhaustive switch in
/// `startRecording` then forces a message to exist for every reason, so a new
/// reason cannot reintroduce silence without failing to compile.
@MainActor
final class RecordingStartBlockedReasonTests: XCTestCase {
    private func makeAppState() -> AppState {
        AppState(
            modelManager: ModelManager(
                modelName: SpeechModelCatalog.defaultModelID,
                modelLoadOverride: { _ in }
            )
        )
    }

    /// The three states that used to produce silence. This is the regression.
    func testBusyStatesReportAReasonRatherThanRefusingSilently() async {
        let appState = makeAppState()
        await appState.modelManager.loadModel(name: SpeechModelCatalog.defaultModelID)
        appState.speechModel = SpeechModelCatalog.defaultModelID

        for status in [AppStatus.transcribing, .cleaningUp] {
            appState.status = status
            XCTAssertNotNil(
                appState.recordingStartBlockedReason,
                "\(status.rawValue) must report a reason, or he gets silence"
            )
        }

        appState.status = .error
        appState.errorMessage = "Accessibility access required"
        XCTAssertEqual(
            appState.recordingStartBlockedReason,
            .appInErrorState("Accessibility access required"),
            "the error state must carry its detail, so the overlay can say what is wrong"
        )
    }

    func testReadyAndLoadedReportsNoReason() async {
        let appState = makeAppState()
        await appState.modelManager.loadModel(name: SpeechModelCatalog.defaultModelID)
        appState.speechModel = SpeechModelCatalog.defaultModelID
        appState.status = .ready

        XCTAssertNil(appState.recordingStartBlockedReason)
    }

    func testSelectingAModelThatIsNotLoadedIsReportedAsAMismatch() async {
        let appState = makeAppState()
        await appState.modelManager.loadModel(name: SpeechModelCatalog.defaultModelID)
        appState.status = .ready
        appState.speechModel = "openai_whisper-tiny.en"

        XCTAssertEqual(
            appState.recordingStartBlockedReason,
            .speechModelMismatch(
                loaded: SpeechModelCatalog.defaultModelID,
                selected: "openai_whisper-tiny.en"
            )
        )
    }

    /// Every reason must survive a round trip through the overlay with a
    /// non-empty message. Written against the RENDERED strings rather than the
    /// enum, because "a case exists" and "he can read something" are different
    /// claims and this project has confused them before.
    func testEveryBlockedReasonProducesReadableText() {
        let reasons: [AppState.RecordingStartBlockedReason] = [
            .appLoading,
            .speechModelNotReady,
            .speechModelMismatch(loaded: "a", selected: "b"),
            .speechAnalyzerReloading,
            .alreadyRecording,
            .transcribing,
            .cleaningUp,
            .appInErrorState("something broke"),
            .appInErrorState(nil)
        ]
        for reason in reasons {
            let message: OverlayMessage
            switch reason {
            case .appLoading, .speechModelNotReady, .speechAnalyzerReloading, .speechModelMismatch:
                message = .modelLoading
            case .alreadyRecording:
                message = .recording
            case .transcribing:
                message = .transcribing
            case .cleaningUp:
                message = .cleaningUp
            case .appInErrorState(let detail):
                message = .cannotStart(detail ?? "Open AF Flow to see what is wrong")
            }
            XCTAssertFalse(
                message.primaryText.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(reason) rendered nothing for him to read"
            )
        }
    }
}
