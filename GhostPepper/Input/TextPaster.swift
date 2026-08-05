import Carbon.HIToolbox
import Cocoa
import ApplicationServices
import CoreGraphics

/// Represents a saved clipboard state, preserving all pasteboard items with all type representations.
struct ClipboardState {
    let data: [[(NSPasteboard.PasteboardType, Data)]]
}

enum PasteResult: Equatable {
    case pasted
    case copiedToClipboard
    /// The clipboard write itself failed, so his words did not arrive anywhere.
    /// Its own case because reporting it as success is the one outcome worse
    /// than failing: the clipboard is now the only copy there is.
    case deliveryFailed
    /// Secure Input is active, so no keystroke this app posts can reach the
    /// focused field. The text is on the clipboard and he can paste it himself.
    case blockedBySecureInput

    /// What the log says. Each case names the consequence rather than the state,
    /// because the reader of that line is trying to explain something he just saw
    /// happen on screen.
    var logDescription: String {
        switch self {
        case .pasted:
            return "landed in the focused field"
        case .copiedToClipboard:
            return "is on the clipboard, ready for Cmd-V"
        case .deliveryFailed:
            return "COULD NOT BE PUT ON THE CLIPBOARD. The words are lost"
        case .blockedBySecureInput:
            return "was blocked by Secure Input, so the text is on the clipboard only"
        }
    }
}

/// Pastes transcribed text into the focused text field by simulating Cmd+V.
/// Saves and restores the clipboard around the paste operation to avoid clobbering user data.
/// Requires Accessibility permission for CGEvent posting.
final class TextPaster {
    typealias PasteSessionProvider = @Sendable (String, Date) -> PasteSession?
    typealias PasteScheduler = (TimeInterval, @escaping () -> Void) -> Void

    /// Why a paste was refused. Two refusals share one log sentence otherwise.
    var onPasteRefused: ((String) -> Void)?

    struct AccessibilitySnapshot {
        let role: String?
        let isEnabled: Bool?
        let isEditable: Bool?
        let isFocused: Bool?
        let hasSelectedTextRange: Bool
        let valueIsSettable: Bool
        let children: [AccessibilitySnapshot]

        init(
            role: String?,
            isEnabled: Bool?,
            isEditable: Bool?,
            isFocused: Bool?,
            hasSelectedTextRange: Bool,
            valueIsSettable: Bool,
            children: [AccessibilitySnapshot] = []
        ) {
            self.role = role
            self.isEnabled = isEnabled
            self.isEditable = isEditable
            self.isFocused = isFocused
            self.hasSelectedTextRange = hasSelectedTextRange
            self.valueIsSettable = valueIsSettable
            self.children = children
        }
    }

    private struct PasteTargetAttributes {
        let role: String?
        let isEnabled: Bool?
        let isEditable: Bool?
        let isFocused: Bool?
        let hasSelectedTextRange: Bool
        let valueIsSettable: Bool
    }

    // MARK: - Timing Constants

    /// Delay after writing text to clipboard before simulating Cmd+V.
    static let preKeystrokeDelay: TimeInterval = 0.05

    /// Delay after simulating Cmd+V before restoring the original clipboard.
    static let postKeystrokeDelay: TimeInterval = 0.1

    // MARK: - Virtual Key Codes

    private static let vKeyCode: CGKeyCode = 0x09
    var onPaste: ((PasteSession) -> Void)?
    var onPasteStart: (() -> Void)?
    var onPasteEnd: (() -> Void)?

    private let pasteSessionProvider: PasteSessionProvider
    private let pasteboard: NSPasteboard
    private let pastePreflight: () -> PastePreflight
    private let prepareCommandV: () -> (() -> Void)?
    private let schedule: PasteScheduler
    /// Whether the system is in Secure Input mode. Injected like every other
    /// seam in this class rather than being a mutable property set afterwards.
    private let isSecureInputEnabled: () -> Bool

    /// - Parameter canPasteIntoFocusedElement: Overrides the Accessibility preflight with a
    ///   definite answer. `nil` uses the real preflight, which can also report that it could not
    ///   tell.
    /// - Parameter pastePreflightOverride: Overrides the preflight with any of its three answers,
    ///   including `.focusUnknown`. `canPasteIntoFocusedElement` cannot express that third state,
    ///   and `.focusUnknown` is the one the 2026-08-05 outage lived in, so it needs a seam of its
    ///   own. Takes precedence over `canPasteIntoFocusedElement` when both are given.
    init(
        pasteboard: NSPasteboard = .general,
        canPasteIntoFocusedElement: (() -> Bool)? = nil,
        pastePreflightOverride: (() -> PastePreflight)? = nil,
        prepareCommandV: @escaping () -> (() -> Void)? = { TextPaster.defaultCommandVPasteAction() },
        pasteSessionProvider: @escaping PasteSessionProvider = { text, date in
            FocusedElementLocator().capturePasteSession(for: text, at: date)
        },
        schedule: @escaping PasteScheduler = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        },
        isSecureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() }
    ) {
        self.pasteboard = pasteboard
        if let pastePreflightOverride {
            self.pastePreflight = pastePreflightOverride
        } else if let canPasteIntoFocusedElement {
            self.pastePreflight = { canPasteIntoFocusedElement() ? .focusedInputAvailable : .noFocusedInput }
        } else {
            self.pastePreflight = { FocusedElementLocator().pastePreflight() }
        }
        self.prepareCommandV = prepareCommandV
        self.pasteSessionProvider = pasteSessionProvider
        self.schedule = schedule
        self.isSecureInputEnabled = isSecureInputEnabled
    }

    // MARK: - Clipboard Operations

    /// Saves all pasteboard items with all their type representations.
    /// - Returns: A `ClipboardState` capturing the full clipboard contents, or `nil` if the clipboard is empty.
    /// The representation types worth preserving across a paste.
    ///
    /// Filtering by TYPE, before fetching. The first version of this checked
    /// `data.count` after calling `item.data(forType:)`, which had already
    /// pulled the whole representation across process boundaries and allocated
    /// it. So it avoided RETAINING the 30 MB screenshot and paid the entire cost
    /// of fetching it anyway, on the path between him releasing the key and his
    /// text appearing. The change did not do the thing it existed to do.
    ///
    /// These are what a clipboard restore is actually for. An image or a PDF is
    /// not preserved, and that is the deliberate trade: he loses the ability to
    /// re-paste a screenshot he had copied before dictating, and gains the
    /// latency back on every single dictation.
    private static let preservedTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .rtf,
        .rtfd,
        .html,
        .URL,
        .fileURL,
        .tabularText,
    ]

    func saveClipboard() -> ClipboardState? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return nil
        }

        var allItems: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in items {
            var itemData: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types where Self.preservedTypes.contains(type) {
                if let data = item.data(forType: type) {
                    itemData.append((type, data))
                }
            }

            // Per ITEM, not per representation.
            //
            // Keeping an item that kept only some of its types can be worse than
            // not restoring it: an image reduced to a bare file-url, or a
            // proprietary marker type without its payload, is something an app
            // may read as empty or paste as the wrong thing. An honest absence
            // beats a misleading partial.
            if !itemData.isEmpty {
                allItems.append(itemData)
            }
        }

        return allItems.isEmpty ? nil : ClipboardState(data: allItems)
    }

    /// Restores a previously saved clipboard state.
    /// All `NSPasteboardItem` objects are collected first, then written in a single `writeObjects` call.
    /// - Parameter state: The clipboard state to restore.
    func restoreClipboard(_ state: ClipboardState) {
        pasteboard.clearContents()

        var pasteboardItems: [NSPasteboardItem] = []
        for itemData in state.data {
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            pasteboardItems.append(item)
        }

        pasteboard.writeObjects(pasteboardItems)
    }

    // MARK: - Delivery

    /// Puts the transcript on the clipboard. **It does not press Cmd-V.**
    ///
    /// ANDREW CHANGED THE PRODUCT HERE ON 2026-08-05, and the reason is worth
    /// keeping because it is not a workaround. Auto-insertion was in the spec
    /// from 2026-07-18 ("cleaned text lands at the cursor of the frontmost app")
    /// because AF Flow was framed as a replacement for Wispr Flow, which does
    /// that. Asked directly, after three days of the paste refusing, he said he
    /// WANTS to press Cmd-V himself, because he wants to choose the field the
    /// text goes into rather than have it go wherever the cursor happened to be
    /// when he released the key.
    ///
    /// So the whole Accessibility insertion path is no longer the product. What
    /// remains is one job: get his words onto the clipboard, quickly, and never
    /// let the clipboard hold the WRONG dictation when he presses Cmd-V.
    ///
    /// That last clause is now the load-bearing one, and it is why the clipboard
    /// is no longer saved and restored around this call. Restoring it existed to
    /// undo an insertion that no longer happens, and it would now overwrite the
    /// one copy of what he just said.
    ///
    /// The preflight, the Cmd-V event, and the Secure Input branch are all
    /// deliberately still here and are deliberately no longer consulted for the
    /// insertion decision. Deleting them is the next commit, after he has used
    /// this for a day and confirmed he wants it. Reversing a behaviour is cheap;
    /// reversing a deletion of the code that implemented it is not.
    ///
    /// - Parameter text: The transcript to make available.
    func paste(text: String) -> PasteResult {
        onPasteStart?()

        pasteboard.clearContents()
        // THE RETURN VALUE IS CHECKED. Codex found this on 2026-08-05: ignoring
        // it meant a failed write cleared his old clipboard, delivered nothing,
        // and still reported success. With the clipboard now the ONLY copy of
        // what he said, a delivery that silently did not happen is the worst
        // failure this class can have.
        guard pasteboard.setString(text, forType: .string) else {
            onPasteEnd?()
            return .deliveryFailed
        }

        deliveredText = text
        deliveredChangeCount = pasteboard.changeCount
        // A new transcript has arrived, so the one held for recovery is no
        // longer the most recent thing he said and must not come back later.
        recoverableText = nil

        // Still captured, because post-paste learning reads what he edits after
        // the text arrives and that is unaffected by who pressed the keys.
        if let pasteSession = pasteSessionProvider(text, Date()) {
            onPaste?(pasteSession)
        }

        onPasteEnd?()
        return .copiedToClipboard
    }

    /// The last transcript this class put on the clipboard.
    private var deliveredText: String?

    /// `NSPasteboard.changeCount` immediately after that write. **This, not
    /// string equality, is what proves the clipboard is still ours.**
    ///
    /// Codex, 2026-08-05: comparing strings deletes HIS content whenever it
    /// happens to match, and it matches more often than it sounds. He copies
    /// the same sentence from somewhere else; a clipboard manager rewrites the
    /// identical string; rich text carries the same plain representation. Every
    /// one of those would have been read as "this is mine to throw away". The
    /// change count cannot be spoofed by content: any write by anyone bumps it.
    private var deliveredChangeCount: Int?

    /// What `clearStaleDictationFromClipboard` took away, kept so it can be put
    /// back. See that method and `restoreClearedDictation` for why.
    private var recoverableText: String?

    /// Removes the PREVIOUS dictation from the clipboard, called when a new
    /// recording starts.
    ///
    /// The bug this exists for, measured across 237 of his real dictations on
    /// 2026-08-05: it takes a median of 1.59 seconds from him releasing the key
    /// to the transcript reaching the clipboard, 4.0 at the 90th percentile and
    /// 11.8 at the worst. For that whole window the clipboard still holds the
    /// last dictation, so a Cmd-V pressed a moment early pastes the wrong words
    /// and looks exactly like the right ones arriving. He reported precisely
    /// this. 93 of the 237 gave him over two seconds to lose that race.
    ///
    /// Clearing turns a silent wrong answer into an obvious empty one. Pasting
    /// nothing is a mistake he can see; pasting last time's paragraph into a
    /// message is one he cannot.
    ///
    /// It is deliberately conservative: it clears ONLY when the clipboard still
    /// holds the exact text this class last wrote. If he has copied anything at
    /// all since, his clipboard is his and is left alone.
    @discardableResult
    func clearStaleDictationFromClipboard() -> Bool {
        guard let deliveredText,
              let deliveredChangeCount,
              pasteboard.changeCount == deliveredChangeCount else {
            return false
        }

        // KEPT, NOT DESTROYED. Codex's third finding, and it was the sharpest:
        // if the new recording produces nothing, an unconditional clear leaves
        // him with an empty clipboard and the previous dictation gone for good.
        // Transcript archiving is off by default, so there is no other copy.
        // `restoreClearedDictation` puts it back in exactly that case.
        recoverableText = deliveredText
        pasteboard.clearContents()
        self.deliveredText = nil
        self.deliveredChangeCount = nil
        return true
    }

    /// Puts the previous dictation back after a recording that produced nothing.
    ///
    /// Clearing at recording start is a bet that a new transcript is coming. When
    /// that bet loses, on silence, a failed transcription, or a cancelled
    /// recording, this pays it back. Without it, starting a dictation and
    /// getting no sound would silently destroy the words he had not pasted yet.
    ///
    /// It refuses if anything has touched the clipboard since, because by then
    /// whatever is there is newer than what we removed and is not ours to
    /// overwrite.
    @discardableResult
    func restoreClearedDictation() -> Bool {
        guard let recoverableText,
              pasteboard.string(forType: .string) == nil else {
            self.recoverableText = nil
            return false
        }

        pasteboard.clearContents()
        guard pasteboard.setString(recoverableText, forType: .string) else {
            return false
        }

        deliveredText = recoverableText
        deliveredChangeCount = pasteboard.changeCount
        self.recoverableText = nil
        return true
    }

    // MARK: - Accessibility Preflight

    /// The Accessibility preflight is authoritative. The menu-bar duck-type answers "can this app
    /// paste at all", a per-app fact, so it may only break the tie when Accessibility saw no
    /// focused element; it must never overturn an answer of "there is no focused input right now".
    ///
    /// **The blind branch, added 2026-08-05 on Andrew's decision.** When the
    /// Accessibility grant has gone stale, `AXIsProcessTrusted()` keeps saying
    /// yes while every real query returns nothing. The preflight then reports
    /// `.focusUnknown` and the menu-bar duck-type, which is itself an AX query,
    /// also returns false. Both tie-breakers are blind at once and the paste is
    /// refused. That is what happened to 235 consecutive dictations between
    /// 08-02 and 08-05.
    ///
    /// So a proven-dead Accessibility connection is treated as "I cannot look",
    /// not as "there is nothing there", and Cmd-V is posted anyway. The cost if
    /// the keystroke lands nowhere is a stale clipboard, which is what he had
    /// anyway; the cost of refusing is his words. Codex's 2026-07-27 objection
    /// to widening this still stands for the case it was about, an app with no
    /// Paste command, and is not what this branch does: it fires only on
    /// `.broken`, never on `.notTrusted` or `.inconclusive`, so an honestly
    /// missing grant and an unanswerable question both still refuse.
    private static func shouldAttemptPaste(
        for preflight: PastePreflight,
        accessibility: AccessibilityFunctionCheck.Verdict
    ) -> Bool {
        switch preflight {
        case .focusedInputAvailable:
            return true
        case .noFocusedInput:
            return false
        case .focusUnknown:
            return frontmostAppHasPasteMenuItem()
                || AccessibilityFunctionCheck.isStaleGrant(accessibility)
        }
    }

    static func containsLikelyPasteTarget(
        startingAt snapshot: AccessibilitySnapshot,
        maxDepth: Int = 12
    ) -> Bool {
        containsLikelyPasteTarget(
            startingAt: snapshot,
            maxDepth: maxDepth,
            attributesProvider: {
                PasteTargetAttributes(
                    role: $0.role,
                    isEnabled: $0.isEnabled,
                    isEditable: $0.isEditable,
                    isFocused: $0.isFocused,
                    hasSelectedTextRange: $0.hasSelectedTextRange,
                    valueIsSettable: $0.valueIsSettable
                )
            },
            childrenProvider: { $0.children }
        )
    }

    private static func containsLikelyPasteTarget<Element>(
        startingAt element: Element,
        maxDepth: Int = 12,
        hasFocusContext: Bool = false,
        attributesProvider: (Element) -> PasteTargetAttributes,
        childrenProvider: (Element) -> [Element]
    ) -> Bool {
        guard maxDepth >= 0 else {
            return false
        }

        let currentAttributes = attributesProvider(element)
        let currentHasFocusContext = hasFocusContext || currentAttributes.isFocused == true

        if isLikelyPasteTarget(currentAttributes, hasFocusContext: currentHasFocusContext) {
            return true
        }

        guard maxDepth > 0 else {
            return false
        }

        let children = childrenProvider(element)
        let focusedChildren = children.filter { attributesProvider($0).isFocused == true }
        for child in focusedChildren {
            if containsLikelyPasteTarget(
                startingAt: child,
                maxDepth: maxDepth - 1,
                hasFocusContext: currentHasFocusContext,
                attributesProvider: attributesProvider,
                childrenProvider: childrenProvider
            ) {
                return true
            }
        }

        for child in children where attributesProvider(child).isFocused != true {
            if containsLikelyPasteTarget(
                startingAt: child,
                maxDepth: maxDepth - 1,
                hasFocusContext: currentHasFocusContext,
                attributesProvider: attributesProvider,
                childrenProvider: childrenProvider
            ) {
                return true
            }
        }

        return false
    }

    private static func isLikelyPasteTarget(
        _ attributes: PasteTargetAttributes,
        hasFocusContext: Bool
    ) -> Bool {
        guard attributes.isEnabled ?? true else {
            return false
        }

        if !hasFocusContext {
            return attributes.hasSelectedTextRange && attributes.valueIsSettable
        }

        if attributes.isEditable == true {
            return true
        }

        if attributes.valueIsSettable {
            return true
        }

        let hasTextRole = isTextEntryRole(attributes.role)

        if attributes.hasSelectedTextRange {
            return hasTextRole
        }

        if hasTextRole {
            return true
        }

        return false
    }

    private static func isTextEntryRole(_ role: String?) -> Bool {
        guard let role else {
            return false
        }

        return role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
    }

    private static func attributes(for element: AXUIElement) -> PasteTargetAttributes {
        PasteTargetAttributes(
            role: stringAttribute(kAXRoleAttribute as CFString, on: element),
            isEnabled: boolAttribute(kAXEnabledAttribute as CFString, on: element),
            isEditable: boolAttribute("AXEditable" as CFString, on: element),
            isFocused: boolAttribute(kAXFocusedAttribute as CFString, on: element),
            hasSelectedTextRange: hasAttribute(kAXSelectedTextRangeAttribute as CFString, on: element),
            valueIsSettable: isAttributeSettable(kAXValueAttribute as CFString, on: element)
        )
    }

    private static func axElementAttribute(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(_ attribute: CFString, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private static func boolAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? Bool
    }

    private static func hasAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute, &value) == .success
    }

    private static func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute, &isSettable) == .success else {
            return false
        }

        return isSettable.boolValue
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [Any] else {
            return []
        }

        return children.compactMap {
            let value = $0 as CFTypeRef
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }

            return unsafeBitCast(value, to: AXUIElement.self)
        }
    }

    // MARK: - Menu Bar Inspection

    /// Duck-typing check: returns true if the frontmost app has an enabled Paste
    /// menu item (Cmd+V). Apps that expose this command support pasting even when
    /// their editor doesn't advertise standard AX text-editing attributes.
    static func frontmostAppHasPasteMenuItem() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        guard let menuBar = axElementAttribute(kAXMenuBarAttribute as CFString, on: appElement) else {
            return false
        }

        let menuBarItems = children(of: menuBar)
        for menuBarItem in menuBarItems {
            let submenus = children(of: menuBarItem)
            for submenu in submenus {
                let menuItems = children(of: submenu)
                for menuItem in menuItems {
                    if isPasteMenuItem(menuItem) {
                        return boolAttribute(kAXEnabledAttribute as CFString, on: menuItem) ?? true
                    }
                }
            }
        }

        return false
    }

    private static func isPasteMenuItem(_ element: AXUIElement) -> Bool {
        var cmdCharRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXMenuItemCmdChar" as CFString, &cmdCharRef) == .success,
              let cmdChar = cmdCharRef as? String,
              cmdChar.lowercased() == "v" else {
            return false
        }

        // AXMenuItemCmdModifiers: 0 = Command only (no Shift/Option/Control)
        var modRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXMenuItemCmdModifiers" as CFString, &modRef) == .success,
           let modifiers = modRef as? Int,
           modifiers != 0 {
            return false
        }

        return true
    }

    // MARK: - Key Simulation

    private static func defaultCommandVPasteAction() -> (() -> Void)? {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: Self.vKeyCode, keyDown: false) else {
            return nil
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        return {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
