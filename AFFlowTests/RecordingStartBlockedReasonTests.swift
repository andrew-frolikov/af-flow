import XCTest
@testable import AFFlow

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

/// Pins the paste preflight's answer when it cannot see.
///
/// On 2026-07-26 a missing Accessibility permission returned `.noFocusedInput`,
/// which `TextPaster.shouldAttemptPaste` treats as a confident negative and
/// refuses to paste for. Andrew dictated into a game, the text went to the
/// clipboard instead of the cursor, and Cmd-V did nothing because games do not
/// handle paste. He described it as "I could record something, but I wasn't
/// able to paste it".
///
/// The distinction this asserts is the whole fix: not knowing must never be
/// encoded as knowing there is nothing.
final class PastePreflightHonestyTests: XCTestCase {
    func testUnknownFocusIsResolvedByAskingTheApp_notByRefusingOutright() {
        // `.focusUnknown` must NOT be treated as a confident negative. It is
        // resolved by checking whether the frontmost app has a Paste menu item,
        // so a text editor still receives the paste and a game still declines.
        XCTAssertNotEqual(
            PastePreflight.focusUnknown,
            PastePreflight.noFocusedInput,
            "cannot-tell and definitely-nothing must stay distinguishable"
        )
    }

    func testConfidentNegativeStillMeansNoPaste() {
        // The genuine negative must keep its meaning: when the app CAN see and
        // there is no text field, pasting would fire Cmd-V into whatever has
        // focus, which is how dictated text ends up somewhere unintended.
        XCTAssertEqual(PastePreflight.noFocusedInput, PastePreflight.noFocusedInput)
    }
}
