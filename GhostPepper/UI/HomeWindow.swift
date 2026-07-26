import AppKit
import SwiftUI

/// AF Flow's front door.
///
/// **Why this exists, and it is the whole of the 2026-07-25 design work.**
/// Opening AF Flow used to show `MeetingTranscriptWindow`, a 9850-line surface
/// belonging to Ghost Pepper, the meeting-transcription and wiki tool this was
/// forked from. Andrew's verdict on his own app, dictated through it: "the
/// design there sucks and it's not usable... it's so chaotic". He was right,
/// and the cause was not styling. He opened a dictation app and was handed a
/// different product.
///
/// He asked for exactly one thing: "simply one first layer... one first screen
/// so I can open and say, this is how it works, and this is how it looks, I'm
/// still working on it." So this is deliberately ONE screen with no navigation.
/// Everything it shows answers "how do I use this", and nothing else is on it.
///
/// **The look is his, not invented here.** The palette, the Georgia-against-ink
/// pairing and the warm rules are lifted from his own house style at
/// `AndrewFrolikov OS/Resources/report-style/base.html`, at his instruction to
/// use his design from the vault as much as possible. Committing to the warm
/// paper look rather than following the system appearance is a deliberate
/// choice: it is his brand, and one confident look beats two hedged ones.
struct AFFlowHomeView: View {
    @ObservedObject var appState: AppState

    /// Read from the LIVE binding rather than from the product spec.
    ///
    /// The spec in CLAUDE.md says fn/globe, and the first mockup said so too.
    /// Andrew corrected it: "right now it's not Fn and speak, it's command and
    /// option." His stored binding is Right Command plus Right Option, and the
    /// screen has to say what is actually bound, or the first thing the app
    /// tells him is a lie. Reading the chord means it can never drift again.
    private var pushToTalk: String { appState.pushToTalkChord.displayString }
    private var toggleToTalk: String { appState.toggleToTalkChord.displayString }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)

            Text("AF FLOW")
                .font(.custom("Georgia", size: 14))
                .tracking(4)
                .foregroundColor(Palette.muted)

            StatusPill(status: appState.status)
                .padding(.top, 18)
                .padding(.bottom, 26)

            instruction

            Text("Release, and your words land where the cursor is")
                .font(.system(size: 13.5))
                .foregroundColor(Palette.inkSoft)
                .padding(.top, 14)

            if !toggleToTalk.isEmpty {
                Text("\(toggleToTalk) keeps it running hands-free")
                    .font(.system(size: 12))
                    .foregroundColor(Palette.muted)
                    .padding(.top, 18)
            }

            if let error = appState.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
            }

            Spacer(minLength: 28)
            footer
        }
        .frame(minWidth: 460, minHeight: 380)
        .background(Palette.paper)
    }

    /// The single most important sentence in the app, so it gets the display
    /// face and the keycaps rather than a settings row somewhere.
    private var instruction: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("Hold")
                    .font(.custom("Georgia", size: 23))
                    .foregroundColor(Palette.ink)
                Keycap(text: pushToTalk)
            }
            Text("and speak")
                .font(.custom("Georgia", size: 23))
                .foregroundColor(Palette.ink)
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            FooterCell(label: "Language", value: "English, Russian, auto")
            Divider().overlay(Palette.line)
            FooterCell(label: "Model", value: SpeechModelCatalog.currentDisplayName)
            Divider().overlay(Palette.line)
            FooterCell(label: "Privacy", value: "Never leaves this Mac", tint: Palette.teal)
        }
        .frame(height: 52)
        .background(Palette.band)
        .overlay(Palette.line.frame(height: 1), alignment: .top)
    }

    // MARK: - Pieces

    private struct Keycap: View {
        let text: String
        var body: some View {
            Text(text.isEmpty ? "no shortcut set" : text)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Palette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Palette.card)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line, lineWidth: 1))
                )
        }
    }

    private struct StatusPill: View {
        let status: AppStatus

        /// One tint per state, so the pill is readable at a glance from across
        /// a screen-share rather than needing the label read.
        private var tint: (dot: Color, text: Color, background: Color) {
            switch status {
            case .ready: return (Palette.teal, Palette.tealInk, Palette.tealTint)
            case .recording: return (Palette.red, Palette.redInk, Palette.redTint)
            case .error: return (Palette.red, Palette.redInk, Palette.redTint)
            default: return (Palette.gold, Palette.goldInk, Palette.goldTint)
            }
        }

        var body: some View {
            HStack(spacing: 8) {
                Circle().fill(tint.dot).frame(width: 7, height: 7)
                Text(status.rawValue.replacingOccurrences(of: "...", with: ""))
                    .font(.system(size: 13))
            }
            .foregroundColor(tint.text)
            .padding(.horizontal, 15)
            .padding(.vertical, 7)
            .background(Capsule().fill(tint.background))
        }
    }

    private struct FooterCell: View {
        let label: String
        let value: String
        var tint: Color = Palette.inkSoft

        var body: some View {
            VStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundColor(Palette.muted)
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Andrew's house palette, from `Resources/report-style/base.html`.
    /// Hard-coded rather than pulled from the system so the app looks like his
    /// brand rather than like every other macOS app.
    enum Palette {
        static let paper = Color(red: 0.984, green: 0.973, blue: 0.953)   // #FBF8F3
        static let band = Color(red: 0.957, green: 0.937, blue: 0.906)    // #F4EFE7
        static let card = Color.white
        static let ink = Color(red: 0.106, green: 0.165, blue: 0.231)     // #1B2A3B
        static let inkSoft = Color(red: 0.259, green: 0.329, blue: 0.416) // #42546A
        static let muted = Color(red: 0.486, green: 0.529, blue: 0.592)   // #7C8797
        static let line = Color(red: 0.910, green: 0.878, blue: 0.824)    // #E8E0D2
        static let teal = Color(red: 0.180, green: 0.545, blue: 0.478)    // #2E8B7A
        static let tealTint = Color(red: 0.882, green: 0.945, blue: 0.925)
        static let tealInk = Color(red: 0.122, green: 0.392, blue: 0.333)
        static let red = Color(red: 0.690, green: 0.278, blue: 0.184)     // #B0472F
        static let redTint = Color(red: 0.973, green: 0.910, blue: 0.886)
        static let redInk = Color(red: 0.557, green: 0.208, blue: 0.141)
        static let gold = Color(red: 0.725, green: 0.510, blue: 0.169)    // #B9822B
        static let goldTint = Color(red: 0.965, green: 0.925, blue: 0.851)
        static let goldInk = Color(red: 0.541, green: 0.373, blue: 0.094)
    }
}

/// A small, self-contained window controller.
///
/// Deliberately NOT reusing `MeetingTranscriptWindowController`, which carries
/// fourteen closure properties for meetings, wikis, speaker prints and index
/// building. Borrowing it would tie the front door to the surface being removed
/// after the demo.
@MainActor
final class HomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(appState: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: false)
            return
        }

        let hosting = NSHostingController(rootView: AFFlowHomeView(appState: appState))
        let created = NSWindow(contentViewController: hosting)
        created.title = "AF Flow"
        created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        created.setContentSize(NSSize(width: 500, height: 400))
        created.isReleasedWhenClosed = false
        created.center()
        created.delegate = self
        // No `.canJoinAllSpaces`, no `.fullScreenAuxiliary`, and no
        // `activate(ignoringOtherApps: true)`. Those flags were on the old main
        // window and are why Andrew reported it appearing "on top of
        // everything, over my game" on 2026-07-21. A document window should sit
        // where it was put.
        window = created
        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
    }

    func windowWillClose(_ notification: Notification) {
        // Kept alive rather than torn down, so reopening is instant and the
        // window remembers where he left it. `isReleasedWhenClosed = false`
        // above is what makes that safe.
    }
}
