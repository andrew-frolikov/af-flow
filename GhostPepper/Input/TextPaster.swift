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
            return "could not confirm a target, so the text is on the clipboard and Cmd-V will paste it again"
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
    init(
        pasteboard: NSPasteboard = .general,
        canPasteIntoFocusedElement: (() -> Bool)? = nil,
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
        if let canPasteIntoFocusedElement {
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

    // MARK: - Paste Flow

    /// Pastes the given text into the currently focused text field.
    ///
    /// Flow:
    /// 1. Save current clipboard
    /// 2. Write text to clipboard
    /// 3. After a short delay, simulate Cmd+V
    /// 4. After another delay, restore the original clipboard, but only if the preflight found a
    ///    real focused input to paste into
    ///
    /// - Parameter text: The text to paste.
    func paste(text: String) -> PasteResult {
        onPasteStart?()

        // Secure Input is checked BEFORE preserving the clipboard, because the
        // preservation exists only to survive a paste that is about to be
        // refused. Doing it first spent the very latency this path was tuned to
        // remove, on work guaranteed to be thrown away.
        if isSecureInputEnabled() {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            print("TextPaster: Secure Input is active, so no synthetic keystroke can land. Text left on the clipboard.")
            onPasteEnd?()
            return .blockedBySecureInput
        }

        let savedState = saveClipboard()

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let preflight = pastePreflight()

        guard Self.shouldAttemptPaste(for: preflight), let postCommandV = prepareCommandV() else {
            onPasteEnd?()
            return .copiedToClipboard
        }

        // Restoring the clipboard destroys the transcript, so it is only safe when the preflight
        // found the input the keystroke lands in. After a duck-typed paste the text stays on the
        // clipboard: a stale clipboard is an annoyance, losing dictated words is not.
        let pasteTargetIsConfirmed = preflight == .focusedInputAvailable

        schedule(Self.preKeystrokeDelay) { [weak self] in
            postCommandV()

            self?.schedule(Self.postKeystrokeDelay) { [weak self] in
                guard let self else { return }

                if let pasteSession = self.pasteSessionProvider(text, Date()) {
                    self.onPaste?(pasteSession)
                }

                if pasteTargetIsConfirmed, let savedState = savedState {
                    self.restoreClipboard(savedState)
                }

                self.onPasteEnd?()
            }
        }

        return .pasted
    }

    // MARK: - Accessibility Preflight

    /// The Accessibility preflight is authoritative. The menu-bar duck-type answers "can this app
    /// paste at all", a per-app fact, so it may only break the tie when Accessibility saw no
    /// focused element; it must never overturn an answer of "there is no focused input right now".
    private static func shouldAttemptPaste(for preflight: PastePreflight) -> Bool {
        switch preflight {
        case .focusedInputAvailable:
            return true
        case .noFocusedInput:
            return false
        case .focusUnknown:
            return frontmostAppHasPasteMenuItem()
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
