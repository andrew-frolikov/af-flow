import XCTest
import ApplicationServices
@testable import AFFlow

final class TextPasterTests: XCTestCase {
    func testContainsLikelyPasteTargetAcceptsTerminalStyleFocusedTextArea() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXTextAreaRole as String,
            isEnabled: nil,
            isEditable: nil,
            isFocused: true,
            hasSelectedTextRange: true,
            valueIsSettable: false
        )

        XCTAssertTrue(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testContainsLikelyPasteTargetAcceptsWindowWithFocusedTextDescendant() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXWindowRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: false,
            hasSelectedTextRange: false,
            valueIsSettable: false,
            children: [
                TextPaster.AccessibilitySnapshot(
                    role: kAXGroupRole as String,
                    isEnabled: nil,
                    isEditable: nil,
                    isFocused: false,
                    hasSelectedTextRange: false,
                    valueIsSettable: false,
                    children: [
                        TextPaster.AccessibilitySnapshot(
                            role: kAXTextAreaRole as String,
                            isEnabled: nil,
                            isEditable: nil,
                            isFocused: true,
                            hasSelectedTextRange: true,
                            valueIsSettable: false
                        )
                    ]
                )
            ]
        )

        XCTAssertTrue(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testContainsLikelyPasteTargetRejectsCodexStyleGroupedWindowWithoutFocusedInput() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXWindowRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: false,
            hasSelectedTextRange: false,
            valueIsSettable: false,
            children: [
                TextPaster.AccessibilitySnapshot(
                    role: kAXGroupRole as String,
                    isEnabled: nil,
                    isEditable: nil,
                    isFocused: false,
                    hasSelectedTextRange: true,
                    valueIsSettable: false,
                    children: [
                        TextPaster.AccessibilitySnapshot(
                            role: kAXGroupRole as String,
                            isEnabled: nil,
                            isEditable: nil,
                            isFocused: false,
                            hasSelectedTextRange: true,
                            valueIsSettable: false
                        )
                    ]
                )
            ]
        )

        XCTAssertFalse(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testContainsLikelyPasteTargetAcceptsCodexStyleGroupedEditorWithSettableValue() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXWindowRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: false,
            hasSelectedTextRange: false,
            valueIsSettable: false,
            children: [
                TextPaster.AccessibilitySnapshot(
                    role: kAXGroupRole as String,
                    isEnabled: true,
                    isEditable: nil,
                    isFocused: false,
                    hasSelectedTextRange: true,
                    valueIsSettable: true,
                    children: [
                        TextPaster.AccessibilitySnapshot(
                            role: kAXGroupRole as String,
                            isEnabled: true,
                            isEditable: nil,
                            isFocused: false,
                            hasSelectedTextRange: true,
                            valueIsSettable: true
                        )
                    ]
                )
            ]
        )

        XCTAssertTrue(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testContainsLikelyPasteTargetRejectsFocusedCodexBackgroundGroupWithoutSettableValue() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXGroupRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: true,
            hasSelectedTextRange: true,
            valueIsSettable: false
        )

        XCTAssertFalse(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testContainsLikelyPasteTargetRejectsWindowWithoutEditableSignals() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXWindowRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: false,
            hasSelectedTextRange: false,
            valueIsSettable: false,
            children: [
                TextPaster.AccessibilitySnapshot(
                    role: kAXButtonRole as String,
                    isEnabled: true,
                    isEditable: nil,
                    isFocused: false,
                    hasSelectedTextRange: false,
                    valueIsSettable: false
                )
            ]
        )

        XCTAssertFalse(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testSaveAndRestoreClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        let paster = TextPaster(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        let saved = paster.saveClipboard()
        XCTAssertNotNil(saved)

        pasteboard.clearContents()
        pasteboard.setString("new content", forType: .string)

        paster.restoreClipboard(saved!)
        XCTAssertEqual(pasteboard.string(forType: .string), "original content")

        pasteboard.releaseGlobally()
    }

    func testPasteLeavesTranscriptOnClipboardWhenFocusedInputIsUnavailable() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        var scheduledActions = 0
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { false },
            prepareCommandV: {
                XCTFail("prepareCommandV should not be called when no focused input is available")
                return nil
            },
            schedule: { _, _ in
                scheduledActions += 1
            }
        )

        let result = paster.paste(text: "new content")

        XCTAssertEqual(result, .copiedToClipboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")
        XCTAssertEqual(scheduledActions, 0)

        pasteboard.releaseGlobally()
    }

    // MARK: - Clipboard only, Andrew's decision of 2026-08-05

    /// THE CONTRACT CHANGED. Auto-insertion was in the spec from 2026-07-18;
    /// asked directly after three days of the paste refusing, he said he wants
    /// to press Cmd-V himself so that HE chooses the field. So no keystroke is
    /// posted, ever, even when a focused text input is sitting right there.
    func testNoKeystrokeIsPostedEvenWithAConfirmedFocusedInput() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        var scheduledActions = 0
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            prepareCommandV: {
                XCTFail("AF Flow no longer types for him. He presses Cmd-V himself.")
                return nil
            },
            schedule: { _, _ in scheduledActions += 1 }
        )

        let result = paster.paste(text: "new content")

        XCTAssertEqual(result, .copiedToClipboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")
        XCTAssertEqual(scheduledActions, 0, "Nothing is deferred: the clipboard is loaded and that is the whole job.")

        pasteboard.releaseGlobally()
    }

    /// THE CLIPBOARD IS NOW THE ONLY COPY OF WHAT HE SAID, so the restore that
    /// used to undo the insertion must never run. It existed to put back what
    /// Cmd-V had already consumed; with no Cmd-V it would simply delete his
    /// words a tenth of a second after they arrived.
    func testTheClipboardIsNeverRestoredOverTheTranscript() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("something he copied earlier", forType: .string)

        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            prepareCommandV: { {} },
            schedule: { _, action in action() }
        )

        _ = paster.paste(text: "his dictated words")

        XCTAssertEqual(pasteboard.string(forType: .string), "his dictated words")
        pasteboard.releaseGlobally()
    }

    /// Post-paste learning still needs the session. It reads what he edits after
    /// the text arrives, which does not depend on who pressed the keys, so it
    /// survives the change and is now captured immediately rather than after a
    /// keystroke delay that no longer exists.
    func testThePasteSessionIsStillCapturedForLearning() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        var captured: PasteSession?
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            prepareCommandV: { {} },
            pasteSessionProvider: { text, date in
                PasteSession(
                    pastedText: text,
                    pastedAt: date,
                    frontmostAppBundleIdentifier: "com.example.app",
                    frontmostWindowID: 42,
                    frontmostWindowFrame: nil,
                    focusedElementFrame: nil,
                    focusedElementText: "whatever was there"
                )
            },
            schedule: { _, action in action() }
        )
        paster.onPaste = { captured = $0 }

        XCTAssertEqual(paster.paste(text: "Jesse"), .copiedToClipboard)
        XCTAssertEqual(captured?.pastedText, "Jesse")

        pasteboard.releaseGlobally()
    }

    // MARK: - Clearing the PREVIOUS dictation

    /// The bug he reported on 2026-08-05: Cmd-V pasted the previous dictation.
    /// Measured cause, across 237 real dictations: a median 1.59s gap between
    /// releasing the key and the transcript reaching the clipboard, 11.8s at
    /// worst, during which the clipboard still holds last time's words. Clearing
    /// at recording start turns a silent wrong paste into an obvious empty one.
    func testStartingANewRecordingClearsThePreviousDictation() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        let paster = TextPaster(pasteboard: pasteboard, canPasteIntoFocusedElement: { true })
        _ = paster.paste(text: "the previous dictation")
        XCTAssertEqual(pasteboard.string(forType: .string), "the previous dictation")

        XCTAssertTrue(paster.clearStaleDictationFromClipboard())
        XCTAssertNil(pasteboard.string(forType: .string))

        pasteboard.releaseGlobally()
    }

    /// HIS CLIPBOARD IS HIS. If he copied anything at all since the last
    /// dictation, that is not ours to delete, and a guard that cleared
    /// unconditionally would destroy whatever he was carrying between apps.
    func testAnythingHeCopiedHimselfIsLeftAlone() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        let paster = TextPaster(pasteboard: pasteboard, canPasteIntoFocusedElement: { true })
        _ = paster.paste(text: "the previous dictation")

        pasteboard.clearContents()
        pasteboard.setString("a link he copied from a browser", forType: .string)

        XCTAssertFalse(paster.clearStaleDictationFromClipboard())
        XCTAssertEqual(pasteboard.string(forType: .string), "a link he copied from a browser")

        pasteboard.releaseGlobally()
    }

    /// Clearing twice must not clear something that arrived in between. The
    /// second call has nothing of ours to remove and must say so.
    func testClearingIsNotRepeatable() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        let paster = TextPaster(pasteboard: pasteboard, canPasteIntoFocusedElement: { true })
        _ = paster.paste(text: "the previous dictation")
        XCTAssertTrue(paster.clearStaleDictationFromClipboard())

        pasteboard.setString("something new", forType: .string)
        XCTAssertFalse(paster.clearStaleDictationFromClipboard())
        XCTAssertEqual(pasteboard.string(forType: .string), "something new")

        pasteboard.releaseGlobally()
    }

    /// With nothing ever delivered there is nothing of ours on the clipboard,
    /// so a clear at the first recording of the session must be a no-op.
    func testClearingBeforeAnyDictationDoesNothing() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("his existing clipboard", forType: .string)

        let paster = TextPaster(pasteboard: pasteboard, canPasteIntoFocusedElement: { true })

        XCTAssertFalse(paster.clearStaleDictationFromClipboard())
        XCTAssertEqual(pasteboard.string(forType: .string), "his existing clipboard")

        pasteboard.releaseGlobally()
    }

    func testPasteMenuItemDetectsCommandV() {
        // isPasteMenuItem is tested indirectly through frontmostAppHasPasteMenuItem.
        // The method checks for Cmd+V (AXMenuItemCmdChar == "v", modifiers == 0).
        // In CI, there may not be a frontmost app with a menu bar, so we verify
        // the method returns a Bool without crashing.
        _ = TextPaster.frontmostAppHasPasteMenuItem()
    }
    // MARK: - Secure Input

    /// While a password field anywhere on the system holds Secure Input, the
    /// window server silently swallows every synthetic keystroke. Cmd-V is
    /// posted, nothing happens, and his dictation disappears with no message
    /// and no way to guess why. The product spec asked for this check by name
    /// and it had never been written.
    /// Secure Input blocks SYNTHETIC keystrokes, and there are no longer any.
    /// His own Cmd-V is a real keypress and is unaffected, so the state that
    /// used to be a blocking failure is now simply not this app's problem: the
    /// transcript reaches the clipboard exactly as it always does.
    func testSecureInputNoLongerBlocksAnythingBecauseNothingIsTyped() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            prepareCommandV: {
                XCTFail("Nothing is ever typed, with or without Secure Input.")
                return nil
            },
            schedule: { _, _ in },
            isSecureInputEnabled: { true }
        )

        let result = paster.paste(text: "his dictated words")

        XCTAssertEqual(result, .copiedToClipboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "his dictated words")

        pasteboard.releaseGlobally()
    }

    // MARK: - Clipboard preservation size limit

    /// Clipboard preservation runs between him releasing the key and his text
    /// appearing. It used to copy every representation of every item, so a
    /// screenshot on the clipboard added its full size to that wait, purely to
    /// restore something about to be overwritten anyway.
    /// Renamed from "OversizedRepresentationsAreNotPreserved", which claimed
    /// more than it checked: it only observed that the type was absent after a
    /// restore, and passed even while the implementation fetched all 8 MB. The
    /// saving comes from never asking for the image at all.
    func testImageRepresentationsAreNotFetchedOrPreserved() {
        let pasteboard = NSPasteboard.withUniqueName()
        let paster = TextPaster(pasteboard: pasteboard)
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setString("the text he actually wants back", forType: .string)
        item.setData(Data(count: 8 * 1024 * 1024), forType: .tiff)
        pasteboard.writeObjects([item])

        let saved = paster.saveClipboard()
        XCTAssertNotNil(saved, "An item with an oversized image must still be preserved for its text.")

        pasteboard.clearContents()
        pasteboard.setString("something else entirely", forType: .string)

        paster.restoreClipboard(saved!)

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "the text he actually wants back",
            "The text half of the clipboard is what a restore is for and must survive the size limit."
        )
        XCTAssertNil(
            pasteboard.data(forType: .tiff),
            "The oversized image must have been skipped rather than copied on the paste path."
        )

        pasteboard.releaseGlobally()
    }

    /// The trade is deliberate and worth stating: an image on the clipboard is
    /// NOT restored after a dictation, at any size.
    ///
    /// This test previously asserted that a small image survived, because the
    /// first implementation filtered by byte count. The review showed that
    /// approach saved nothing: the data had already been fetched across process
    /// boundaries before its size could be measured. Filtering by type is what
    /// actually removes the cost, and it cannot make an exception for small
    /// images without asking for them first.
    ///
    /// So he loses the ability to re-paste a screenshot he copied before
    /// dictating, and gains that time back on every dictation.
    func testTextIsPreservedAndImagesAreNotAtAnySize() {
        let pasteboard = NSPasteboard.withUniqueName()
        let paster = TextPaster(pasteboard: pasteboard)
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setString("plain text", forType: .string)
        item.setData(Data(count: 1024), forType: .tiff)
        pasteboard.writeObjects([item])

        let saved = paster.saveClipboard()
        XCTAssertNotNil(saved)

        pasteboard.clearContents()
        paster.restoreClipboard(saved!)

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "plain text",
            "Text is what a clipboard restore is for and must always survive."
        )
        XCTAssertNil(
            pasteboard.data(forType: .tiff),
            "Images are not preserved at any size. Making an exception for small ones would mean fetching every image to measure it, which is the cost this exists to avoid."
        )

        pasteboard.releaseGlobally()
    }


    // MARK: - Codex's three data-loss findings, 2026-08-05

    /// STRING EQUALITY WAS THE WRONG OWNERSHIP TEST. He copies the same sentence
    /// from somewhere else, or a clipboard manager rewrites the identical
    /// string, and the old guard would read that as "mine, throw it away". The
    /// change count cannot be spoofed by content: any write by anyone bumps it.
    func testIdenticalTextCopiedAgainByHimIsNotTreatedAsOurs() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        let paster = TextPaster(pasteboard: pasteboard, canPasteIntoFocusedElement: { true })
        _ = paster.paste(text: "the same words")

        // He copies the very same string himself. Content matches; ownership does not.
        pasteboard.clearContents()
        pasteboard.setString("the same words", forType: .string)

        XCTAssertFalse(paster.clearStaleDictationFromClipboard())
        XCTAssertEqual(pasteboard.string(forType: .string), "the same words")

        pasteboard.releaseGlobally()
    }

    /// A recording that produces nothing must not cost him the dictation he had
    /// not pasted yet. Transcript archiving is off by default, so the clipboard
    /// really is the only copy.
    func testAFailedRecordingPutsThePreviousDictationBack() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        let paster = TextPaster(pasteboard: pasteboard, canPasteIntoFocusedElement: { true })
        _ = paster.paste(text: "the words he has not pasted yet")
        XCTAssertTrue(paster.clearStaleDictationFromClipboard())
        XCTAssertNil(pasteboard.string(forType: .string))

        XCTAssertTrue(paster.restoreClearedDictation())
        XCTAssertEqual(pasteboard.string(forType: .string), "the words he has not pasted yet")

        pasteboard.releaseGlobally()
    }

    /// Restoring must never overwrite something newer. If anything reached the
    /// clipboard while the recording ran, that is his and it wins.
    func testRestoreRefusesWhenSomethingElseArrivedMeanwhile() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        let paster = TextPaster(pasteboard: pasteboard, canPasteIntoFocusedElement: { true })
        _ = paster.paste(text: "the previous dictation")
        XCTAssertTrue(paster.clearStaleDictationFromClipboard())

        pasteboard.setString("something he copied while speaking", forType: .string)

        XCTAssertFalse(paster.restoreClearedDictation())
        XCTAssertEqual(pasteboard.string(forType: .string), "something he copied while speaking")

        pasteboard.releaseGlobally()
    }

    /// A successful delivery must retire the recovery copy, or a later failed
    /// recording would resurrect words from two dictations ago.
    func testANewDictationRetiresTheRecoveryCopy() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        let paster = TextPaster(pasteboard: pasteboard, canPasteIntoFocusedElement: { true })
        _ = paster.paste(text: "dictation one")
        XCTAssertTrue(paster.clearStaleDictationFromClipboard())
        _ = paster.paste(text: "dictation two")

        pasteboard.clearContents()
        XCTAssertFalse(paster.restoreClearedDictation(), "Only the immediately previous dictation is ever restored.")

        pasteboard.releaseGlobally()
    }

    /// A clipboard write that fails must be reported as a failure. Reporting it
    /// as success is the one outcome worse than failing, because the clipboard
    /// is the only copy and he would never know it was not there.
    func testAFailedClipboardWriteIsReportedAsFailure() {
        let pasteboard = RefusingPasteboard.withUniqueName() as! RefusingPasteboard
        pasteboard.clearContents()

        let paster = TextPaster(pasteboard: pasteboard, canPasteIntoFocusedElement: { true })
        let result = paster.paste(text: "his dictated words")

        XCTAssertEqual(result, .deliveryFailed, "A write that did not land must not report success.")
        pasteboard.releaseGlobally()
    }

    /// A pasteboard whose writes always fail. `NSPasteboard` has no injectable
    /// failure mode and a released one still accepts strings, so the only honest
    /// way to exercise the failure branch is to refuse the write here.
    private final class RefusingPasteboard: NSPasteboard {
        override func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
            false
        }
    }
}
