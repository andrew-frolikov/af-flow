import XCTest
@testable import GhostPepper

final class ChordEngineTests: XCTestCase {
    private let rightCommand = PhysicalKey(keyCode: 54)
    private let rightOption = PhysicalKey(keyCode: 61)
    private let space = PhysicalKey(keyCode: 49)
    private let leftCommand = PhysicalKey(keyCode: 55)

    func testPushToTalkStartsWhenChordMatchesEvenIfToggleExtendsIt() throws {
        var engine = ChordEngine(bindings: [
            .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption]))),
            .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [.startRecording])
        XCTAssertEqual(engine.activeRecordingAction, .pushToTalk)
    }

    func testPushToTalkPromotesToToggleByRestarting() throws {
        var engine = ChordEngine(bindings: [
            .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption]))),
            .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [.startRecording])
        XCTAssertEqual(engine.activeRecordingAction, .pushToTalk)

        XCTAssertEqual(engine.handle(.keyDown(space)), [.restartRecording])
        XCTAssertEqual(engine.activeRecordingAction, .toggleToTalk)

        XCTAssertEqual(engine.handle(.keyUp(space)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [])
        XCTAssertEqual(engine.handle(.keyDown(space)), [.stopRecording])
        XCTAssertNil(engine.activeRecordingAction)
    }

    func testPushToTalkStartsImmediatelyWhenExactChordMatches() throws {
        var engine = ChordEngine(bindings: [
            .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption]))),
            .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([leftCommand, space])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [.startRecording])
        XCTAssertEqual(engine.activeRecordingAction, .pushToTalk)
    }

    func testToggleToTalkTogglesOnSecondMatch() throws {
        var engine = ChordEngine(bindings: [
            .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([leftCommand, space]))),
            .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption, space])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [])
        XCTAssertEqual(engine.handle(.keyDown(space)), [.startRecording])
        XCTAssertEqual(engine.activeRecordingAction, .toggleToTalk)

        XCTAssertEqual(engine.handle(.keyUp(space)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [])
        XCTAssertEqual(engine.handle(.keyDown(space)), [.stopRecording])
        XCTAssertNil(engine.activeRecordingAction)
    }

    func testPushToTalkStopsWhenAnyRequiredKeyReleases() throws {
        var engine = ChordEngine(bindings: [
            .pushToTalk: try XCTUnwrap(KeyChord(keys: Set([rightCommand, rightOption]))),
            .toggleToTalk: try XCTUnwrap(KeyChord(keys: Set([leftCommand, space])))
        ])

        XCTAssertEqual(engine.handle(.flagsChanged(rightCommand)), [])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [.startRecording])
        XCTAssertEqual(engine.handle(.flagsChanged(rightOption)), [.stopRecording])
        XCTAssertNil(engine.activeRecordingAction)
    }
}

/// GLOBE PLUS LEFT CONTROL, and why it is not Globe alone.
///
/// I moved him to Globe on its own on 2026-08-02, because the v1 spec says "hold
/// fn/globe primary" and his log held about ten solitary Globe presses that started
/// nothing. That reasoning was wrong and he corrected it within the hour.
///
/// **He has three keyboard layouts installed: Canadian, Russian and Ukrainian-PC. With
/// more than one layout, macOS's own default for the Globe key is to cycle between
/// them.** A bare Globe press therefore starts a dictation AND rotates his keyboard,
/// and he would only discover it when the next thing he typed came out in Cyrillic.
/// The chord exists to avoid exactly that collision.
///
/// His configuration encoded a constraint the spec was written without, and I trusted
/// the spec over the machine. Pinned here so the next agent reading that spec line does
/// not repeat it.
final class PushToTalkChordTests: XCTestCase {
    private let globe = PhysicalKey(keyCode: 63)
    private let leftControl = PhysicalKey(keyCode: 59)

    private func engine() -> ChordEngine {
        ChordEngine(bindings: [
            .pushToTalk: AppState.defaultPushToTalkChord,
            .toggleToTalk: AppState.defaultToggleToTalkChord,
            .pepperChat: AppState.defaultPepperChatChord
        ])
    }

    func testTheShippedBindingIsGlobePlusLeftControl() {
        XCTAssertEqual(AppState.defaultPushToTalkChord.keys, Set([globe, leftControl]))
    }

    /// GLOBE ON ITS OWN MUST NOT START A RECORDING. That is the whole point of the
    /// second key: a bare Globe press belongs to macOS on his machine.
    func testGlobeAloneDoesNotStartARecording() {
        var chords = engine()
        XCTAssertFalse(
            chords.handle(.flagsChanged(globe)).contains(.startRecording),
            "A bare Globe press started a recording, which on his Mac also cycles his keyboard layout."
        )
    }

    /// Both orders work, because the engine matches on the SET of pressed keys. This is
    /// the mechanical advantage the chord has over Globe alone, which only ever started
    /// when Globe was pressed first.
    func testGlobeThenControlStartsARecording() {
        var chords = engine()
        XCTAssertEqual(chords.handle(.flagsChanged(globe)), [])
        XCTAssertEqual(chords.handle(.flagsChanged(leftControl)), [.startRecording])
        XCTAssertEqual(chords.activeRecordingAction, .pushToTalk)
    }

    func testControlThenGlobeAlsoStartsARecording() {
        var chords = engine()
        XCTAssertEqual(chords.handle(.flagsChanged(leftControl)), [])
        XCTAssertEqual(
            chords.handle(.flagsChanged(globe)),
            [.startRecording],
            "Control first must work too; Globe alone failed this and his log shows him doing it."
        )
    }

    /// Releasing either key stops it, which is what push to talk means.
    func testReleasingEitherKeyStopsTheRecording() {
        var chords = engine()
        _ = chords.handle(.flagsChanged(globe))
        XCTAssertEqual(chords.handle(.flagsChanged(leftControl)), [.startRecording])
        XCTAssertEqual(chords.handle(.flagsChanged(leftControl)), [.stopRecording])
    }

    /// And the migration must move anyone still carrying Globe alone back off it, since
    /// this session briefly wrote that into his defaults.
    func testGlobeAloneIsOneOfTheBindingsTheMigrationReplaces() {
        XCTAssertTrue(AppState.supersededPushToTalkChords.contains(KeyChord(keys: Set([globe]))!))
        XCTAssertFalse(
            AppState.supersededPushToTalkChords.contains(AppState.defaultPushToTalkChord),
            "The migration must never list its own target, or it would loop."
        )
    }
}
