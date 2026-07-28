import XCTest
import ApplicationServices
@testable import GhostPepper

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

    func testPasteSchedulesCommandVAndRestoresClipboardWhenFocusedInputIsAvailable() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        var scheduledActions: [() -> Void] = []
        var postedCommandV = 0
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            prepareCommandV: {
                { postedCommandV += 1 }
            },
            schedule: { _, action in
                scheduledActions.append(action)
            }
        )

        let result = paster.paste(text: "new content")

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")
        XCTAssertEqual(postedCommandV, 0)
        XCTAssertEqual(scheduledActions.count, 1)

        let postPasteAction = scheduledActions.removeFirst()
        postPasteAction()

        XCTAssertEqual(postedCommandV, 1)
        XCTAssertEqual(scheduledActions.count, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")

        let restoreClipboardAction = scheduledActions.removeFirst()
        restoreClipboardAction()

        XCTAssertEqual(pasteboard.string(forType: .string), "original content")

        pasteboard.releaseGlobally()
    }

    func testPasteCapturesSessionAfterPasteDelay() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        var currentSnapshot = "before paste"
        var scheduledActions: [() -> Void] = []
        let expectation = expectation(description: "paste session captured")
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
                focusedElementText: currentSnapshot
            )
            },
            schedule: { _, action in
                scheduledActions.append(action)
            }
        )
        paster.onPaste = { session in
            XCTAssertEqual(session.focusedElementText, "after paste")
            expectation.fulfill()
        }

        let result = paster.paste(text: "Jesse")
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(scheduledActions.count, 1)

        currentSnapshot = "after paste"

        let postPasteAction = scheduledActions.removeFirst()
        postPasteAction()

        XCTAssertEqual(scheduledActions.count, 1)

        let captureSessionAction = scheduledActions.removeFirst()
        captureSessionAction()

        wait(for: [expectation], timeout: 1)
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
    func testPasteRefusesToTypeWhileSecureInputIsActive() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            prepareCommandV: {
                XCTFail("No keystroke may be prepared while Secure Input is active: it can never land.")
                return nil
            },
            schedule: { _, _ in },
            isSecureInputEnabled: { true }
        )

        let result = paster.paste(text: "his dictated words")

        XCTAssertEqual(result, .blockedBySecureInput)
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "his dictated words",
            "The transcript must be left on the clipboard so he can paste it himself. Refusing to type AND losing the text would be the worse outcome."
        )

        pasteboard.releaseGlobally()
    }

    func testPastePreparesAKeystrokeWhenSecureInputIsNotActive() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        var prepared = false
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            prepareCommandV: {
                prepared = true
                return {}
            },
            schedule: { _, _ in },
            isSecureInputEnabled: { false }
        )

        _ = paster.paste(text: "his dictated words")

        XCTAssertTrue(prepared, "With Secure Input off, the normal paste must still happen.")
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

}
