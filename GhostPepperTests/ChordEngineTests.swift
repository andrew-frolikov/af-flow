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

/// GLOBE ALONE, restored 2026-08-02.
///
/// His debug log for 2026-08-01 and 2026-08-02 holds about ten solitary Globe presses
/// that started nothing, and he confirmed they were dictation attempts. His stored
/// binding had become Left Control PLUS Globe, so the one key he reaches for did
/// nothing and the app said nothing about it. The v1 spec asked for Globe as the
/// primary trigger from the beginning.
final class GlobeAlonePushToTalkTests: XCTestCase {
    private let globe = PhysicalKey(keyCode: 63)
    private let leftControl = PhysicalKey(keyCode: 59)

    private func engine() -> ChordEngine {
        ChordEngine(bindings: [
            .pushToTalk: AppState.defaultPushToTalkChord,
            .toggleToTalk: AppState.defaultToggleToTalkChord,
            .pepperChat: AppState.defaultPepperChatChord
        ])
    }

    func testTheShippedPushToTalkBindingIsGlobeOnItsOwn() {
        XCTAssertEqual(AppState.defaultPushToTalkChord.keys, Set([globe]))
    }

    /// The one key, on its own, starts a recording. This is the whole point.
    func testPressingGlobeAloneStartsARecording() {
        var chords = engine()
        XCTAssertEqual(
            chords.handle(.flagsChanged(globe)),
            [.startRecording],
            "Globe on its own did not start a recording."
        )
    }

    /// His existing muscle memory still works, because his log shows him pressing Globe
    /// first and adding Control afterwards in five cases out of six. The extra key must
    /// not cancel what Globe started.
    func testAddingControlAfterGlobeDoesNotStopTheRecording() {
        var chords = engine()
        XCTAssertEqual(chords.handle(.flagsChanged(globe)), [.startRecording])
        XCTAssertFalse(
            chords.handle(.flagsChanged(leftControl)).contains(.stopRecording),
            "Holding his old second key cancelled the recording."
        )
        XCTAssertEqual(chords.activeRecordingAction, .pushToTalk)
    }

    /// Releasing it stops the recording, which is what push to talk means.
    func testReleasingGlobeStopsTheRecording() {
        var chords = engine()
        XCTAssertEqual(chords.handle(.flagsChanged(globe)), [.startRecording])
        XCTAssertEqual(chords.handle(.flagsChanged(globe)), [.stopRecording])
    }

    /// THE EDGE THIS CREATES, pinned rather than discovered later.
    ///
    /// Pressing Control BEFORE Globe no longer starts anything, because the engine
    /// matches chords exactly and {Control, Globe} is not {Globe}. His log shows him
    /// doing that once in six. Recorded here so it is a known trade rather than a
    /// surprise, and so a future change that fixes it has something to flip.
    func testPressingControlFirstNoLongerStartsARecording() {
        var chords = engine()
        XCTAssertEqual(chords.handle(.flagsChanged(leftControl)), [])
        XCTAssertFalse(chords.handle(.flagsChanged(globe)).contains(.startRecording))
    }
}
