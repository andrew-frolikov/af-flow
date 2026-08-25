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

            StatusPill(status: appState.status)
                .padding(.bottom, appState.permissionWarning == nil ? 26 : 10)

            // Ledger item 23: a missing grant used to produce a log line and
            // nothing else, while the pill above still said Ready. The pill is
            // deliberately left alone, because the app may genuinely still work;
            // this says what is missing instead of overruling it.
            if let permissionWarning = appState.permissionWarning {
                Text(permissionWarning)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
            }

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
        // `maxWidth`/`maxHeight` as well as the minimums, and the background
        // comes AFTER: as a section this has to fill the detail pane, and a view
        // whose background was sized to its content leaves the rest of the pane
        // in the shell's colour.
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .background(Palette.paper)
    }

    /// **The three-word menu that used to sit here is gone, 2026-08-24.**
    ///
    /// It existed because this window was one of four: Andrew opened the new home
    /// window on 2026-07-26 and said "there is no menu bar, nothing", so it got a
    /// row of words that opened the other three windows. He then asked for the
    /// opposite of four windows: "I do not want history and other menu options to
    /// pop up in the different window, let it be in one."
    ///
    /// Home is a SECTION of that one window now, and the sidebar beside it is the
    /// navigation. A second navigation layer inside the pane would be two ways to
    /// reach the same place, which is how they drift apart.
    ///
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

    /// The languages the app can actually return, read from the allowlist that
    /// decides it rather than written out by hand.
    ///
    /// This said "English, Russian, auto" until 2026-08-02, as a hardcoded
    /// string. The word "auto" stopped being true when `detectLanguage = true`
    /// was deleted and en/ru became the only possible answers, and the front
    /// page of his app went on claiming otherwise. **The literal is the bug**:
    /// a label that restates a policy instead of reading it is a label that
    /// goes stale silently, which is this project's signature defect wearing a
    /// label rather than a comment or a test.
    static var languageSummary: String {
        let names = [
            "en": "English",
            "ru": "Russian",
            "uk": "Ukrainian"
        ]
        return ModelManager.supportedAutoDetectLanguages
            .map { names[$0] ?? $0.uppercased() }
            .joined(separator: ", ")
    }

    private var footer: some View {
        HStack(spacing: 0) {
            FooterCell(label: "Language", value: Self.languageSummary)
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

    typealias Palette = AFFlowPalette
}

/// Andrew's house palette, from `Resources/report-style/base.html`.
/// Hard-coded rather than pulled from the system so the app looks like his
/// brand rather than like every other macOS app.
///
/// Top-level rather than nested in the home view, and that is the point: the
/// menu bar and the recording overlay are the other two surfaces visible while
/// he dictates on camera, and three surfaces holding three private copies of
/// the same hex values is how they drift apart. One definition, three readers.
enum AFFlowPalette {
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

    /// The overlay floats over whatever app he is dictating into, so it cannot
    /// be paper: it would vanish against a light document. It is his ink
    /// instead, which reads as the same family as the home window while staying
    /// legible on any background.
    static let overlayFill = Color(red: 0.086, green: 0.133, blue: 0.192)
    static let overlayText = Color(red: 0.973, green: 0.961, blue: 0.941)
    static let overlayRule = Color(red: 0.290, green: 0.353, blue: 0.435)
}

/// **AF Flow's one window.**
///
/// Until 2026-08-24 this owned a 500x440 window showing only the home screen,
/// and Settings, History and the Debug log were three more `NSWindow`s reached
/// from a row of words across the top of it. Andrew: "I do not want history and
/// other menu options to pop up in the different window, let it be in one."
///
/// So it hosts `SettingsView` now — the sidebar shell that already existed — with
/// Home as its first section. `showHomeWindow`, `showSettings` and `showDebugLog`
/// all arrive here and differ only in which section they land on.
///
/// **The meeting transcript viewer is deliberately NOT folded in.** His decision,
/// because he reads a transcript alongside other things and wants it as a window
/// he can put somewhere.
///
/// Still deliberately NOT `MeetingTranscriptWindowController`, which carries
/// fourteen closure properties for meetings, wikis, speaker prints and index
/// building.
extension Notification.Name {
    /// Posted with `object: Bool` when AF Flow's one window becomes visible or
    /// stops being visible.
    ///
    /// **This exists because `orderOut` does not unmount SwiftUI.** Codex,
    /// 2026-08-24: the debug log streams while it is on screen, and as a section
    /// its `onDisappear` never fires — the hosting view stays mounted when the
    /// window is hidden or minimised. `DebugLogStore.recordSensitive` writes his
    /// RAW transcriptions and OCR context only while a viewer is live, so a
    /// viewer count stuck above zero means every later dictation persists that to
    /// disk with nothing on screen. The window's own lifecycle is the only honest
    /// signal for whether anyone is looking.
    static let afFlowWindowVisibilityChanged = Notification.Name("afFlowWindowVisibilityChanged")
}

@MainActor
final class HomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// `activating` is FALSE for Home and TRUE for the places he navigated to on
    /// purpose, and the split is deliberate.
    ///
    /// Home opens on launch and on a Dock click, and `activate(ignoringOtherApps:
    /// true)` there is what put it "on top of everything, over my game" on
    /// 2026-07-21. But Settings and the debug log are reached from the menu bar
    /// while another app is frontmost, and the two controllers deleted here both
    /// passed `true`: without it those menu items appear to do nothing. Codex
    /// caught the regression, 2026-08-24.
    func show(appState: AppState, section: AFFlowSection = .home, activating: Bool = false) {
        if let window {
            // DEMINIATURIZE FIRST. `makeKeyAndOrderFront` does not restore a
            // minimised window, so choosing Debug log from the menu bar while it
            // sits in the Dock would announce the window as visible and take a
            // live-viewing claim on the log with nothing on screen — the same
            // privacy leak as round 1, by a different route. Codex, round 4.
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: activating)
            NotificationCenter.default.post(name: .afFlowWindowVisibilityChanged, object: true)
            // The window already exists, so the section is changed in place
            // rather than by rebuilding the view: rebuilding would throw away
            // every piece of @State in it, including a history entry he had open.
            NotificationCenter.default.post(name: .showSettingsSection, object: section)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(appState: appState, initialSection: section))
        let created = NSWindow(contentViewController: hosting)
        created.title = "AF Flow"
        created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        created.setContentSize(NSSize(width: 1000, height: 720))
        created.minSize = NSSize(width: 900, height: 680)
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
        NSApp.activate(ignoringOtherApps: activating)
        NotificationCenter.default.post(name: .afFlowWindowVisibilityChanged, object: true)
    }

    /// Hidden, not torn down, so reopening is instant and it remembers where he
    /// left it and which section he was on.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NotificationCenter.default.post(name: .afFlowWindowVisibilityChanged, object: false)
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        NotificationCenter.default.post(name: .afFlowWindowVisibilityChanged, object: false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        NotificationCenter.default.post(name: .afFlowWindowVisibilityChanged, object: true)
    }
}
