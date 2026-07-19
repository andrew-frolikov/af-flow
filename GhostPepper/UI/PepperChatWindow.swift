import AppKit
import SwiftUI

private final class PepperChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class PepperChatWindowController: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private var isMinimized = false
    var onOpenInMeetings: ((URL) -> Void)?

    func show(session: PepperChatSession) {
        if let window {
            if isMinimized {
                popUp()
            } else {
                window.makeKeyAndOrderFront(nil)
            }
            return
        }

        let onMinimize: () -> Void = { [weak self] in self?.minimize() }
        let rootView = ContextBubbleView(
            session: session,
            onMinimize: onMinimize,
            onOpenInMeetings: { [weak self] url in
                self?.onOpenInMeetings?(url)
            }
        )
        let window = PepperChatPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentViewController = NSHostingController(rootView: rootView)

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - window.frame.width / 2
            let y = screenFrame.midY - window.frame.height / 2 + 50 // slightly above center
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)
        self.window = window
        isMinimized = false
    }

    func popUp() {
        guard let window else { return }
        isMinimized = false
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func minimize() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.isMinimized = true
        })
    }

    func showIfOpen() {
        if isMinimized {
            popUp()
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        minimize()
        return false
    }
}
