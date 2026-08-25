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
/// **The look is his, not invented here.** As of 2026-08-25 it is the canonical
/// brand: pine on warm paper, Fraunces for the app's own words and Inter for
/// everything else, from `AndrewFrolikov OS/Context/brand-visual.md` by way of
/// `docs/design/af-flow-visual-system.md`. It was a Georgia-against-ink lift
/// from his report style before that, which is what this paragraph used to
/// describe. Committing to the paper look rather than following the system
/// appearance is deliberate: it is his brand, and one confident look beats two
/// hedged ones.
struct AFFlowHomeView: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var appState: AppState

    /// Read from the LIVE binding rather than from the product spec.
    ///
    /// The spec in CLAUDE.md says fn/globe, and the first mockup said so too.
    /// Andrew corrected it: "right now it's not Fn and speak, it's command and
    /// option." His stored binding is Right Command plus Right Option, and the
    /// screen has to say what is actually bound, or the first thing the app
    /// tells him is a lie. Reading the chord means it can never drift again.
    /// The hero is the brand skin's treatment. Windows 95 and Space keep their
    /// own grounds: a fog clip under a novelty skin would be neither.
    private var wearsHero: Bool { theme.id == .current }

    private var pushToTalk: String { appState.pushToTalkChord.displayString }
    private var toggleToTalk: String { appState.toggleToTalkChord.displayString }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)

            StatusPill(status: appState.status, onHero: wearsHero)
                .padding(.bottom, appState.permissionWarning == nil ? 26 : 10)

            // Ledger item 23: a missing grant used to produce a log line and
            // nothing else, while the pill above still said Ready. The pill is
            // deliberately left alone, because the app may genuinely still work;
            // this says what is missing instead of overruling it.
            if let permissionWarning = appState.permissionWarning {
                Text(permissionWarning)
                    .font(theme.textFont(size: 12))
                    .foregroundStyle(wearsHero ? Brand.secondaryOnDark : theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
            }

            instruction

            Text("Release, and your words land where the cursor is")
                .font(theme.textFont(size: 13.5))
                .foregroundColor(wearsHero ? Brand.textOnDark : theme.textPrimary)
                .padding(.top, 14)

            if !toggleToTalk.isEmpty {
                Text("\(toggleToTalk) keeps it running hands-free")
                    .font(theme.textFont(size: 12))
                    .foregroundColor(wearsHero ? Brand.secondaryOnDark : theme.textSecondary)
                    .padding(.top, 18)
            }

            if let error = appState.errorMessage, !error.isEmpty {
                // **Clay is banned as body text on the fog.** `#E8836B`
                // measures 3.78:1 on the plate floor, below the 4.5 minimum, so
                // the message is set in paper and a clay dot carries the alarm
                // at the 3:1 non-text minimum. The pill above has already gone
                // red; the dot ties the two together. On paper the ordinary
                // rule (error text in statusLive) is unchanged.
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if wearsHero {
                        Circle()
                            .fill(Brand.statusLiveOnDark)
                            .frame(width: 7, height: 7)
                    }
                    Text(error)
                        .font(theme.textFont(size: 12))
                        .foregroundColor(wearsHero ? Brand.textOnDark : theme.statusLive)
                        .multilineTextAlignment(wearsHero ? .leading : .center)
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
            }

            Spacer(minLength: 28)
            footer
        }
        // `maxWidth`/`maxHeight` as well as the minimums: as a section this
        // has to fill the detail pane. On the brand skin it paints NO ground of
        // its own, because the fog runs edge to edge behind the whole window.
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .background {
            if wearsHero {
                ZStack {
                    // The website's own two scrims, carried over verbatim.
                    // MOOD, not guarantee: measured over real frames this alone
                    // falls to 1.76:1 for paper text at its weak end.
                    HeroSurface.diagonalScrim
                    HeroSurface.groundingScrim
                    // The guarantee. Ink at an effective 0.84 under the text,
                    // feathered out. Because compositing is monotone per
                    // channel, 0.84 over any SDR pixel is darker than 0.84 over
                    // pure white, which is `#3C4441`: paper 8.92:1, muted
                    // 5.56:1, mist 7.18:1, on EVERY frame rather than on one.
                    HeroSurface.softPlate
                }
                .ignoresSafeArea()
            } else {
                theme.windowBackground
            }
        }
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
                    .font(theme.displayFont)
                    .tracking(-0.48)
                    .foregroundColor(wearsHero ? Brand.textOnDark : theme.textPrimary)
                Keycap(text: pushToTalk, onHero: wearsHero)
            }
            Text("and speak")
                .font(theme.displayFont)
                .tracking(-0.48)
                .foregroundColor(wearsHero ? Brand.textOnDark : theme.textPrimary)
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
            FooterCell(label: "Language", value: Self.languageSummary, onHero: wearsHero)
            Divider().overlay(wearsHero ? Brand.textOnDark.opacity(0.30) : theme.separator)
            FooterCell(label: "Model", value: SpeechModelCatalog.currentDisplayName, onHero: wearsHero)
            Divider().overlay(wearsHero ? Brand.textOnDark.opacity(0.30) : theme.separator)
            FooterCell(label: "Privacy", value: "Never leaves this Mac",
                       tint: wearsHero ? Brand.mist : theme.accent, onHero: wearsHero)
        }
        .frame(height: 52)
        // On the hero the footer sits on a flat ink band at 0.88, which
        // composites to `#333B38` over pure white: eyebrows 6.39:1, values
        // 10.25:1, the privacy value in mist 8.25:1. A gradient here would make
        // the footer's contrast depend on what the fog is doing.
        .background(wearsHero ? Color(hex: 0x17201D).opacity(HeroSurface.footerBandAlpha) : theme.windowBackground)
        .overlay(
            (wearsHero ? Brand.textOnDark.opacity(0.30) : theme.separator).frame(height: 1),
            alignment: .top
        )
    }

    // MARK: - Pieces

    private struct Keycap: View {
        @Environment(\.appTheme) private var theme
        let text: String
        var onHero: Bool = false
        var body: some View {
            // **The single lightest object on the plate, deliberately.** The
            // chord is what the eye has to find first, and a solid `well` fill
            // gives it 16.37:1 regardless of what the fog is doing underneath.
            // It is one of only two paper-side fills allowed on the fog; a
            // translucent one would let contrast drift with the video.
            // On the hero it drops its border: on ink the edge articulates
            // itself, and the light-surface keycap keeps its hairline.
            Text(text.isEmpty ? "no shortcut set" : text)
                .font(theme.textFont(size: 15, weight: 500))
                .foregroundColor(Brand.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Brand.well)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(onHero ? Color.clear : theme.separator, lineWidth: 1)
                        )
                )
        }
    }

    private struct StatusPill: View {
        @Environment(\.appTheme) private var theme
        let status: AppStatus

        /// One tint per state, so the pill is readable at a glance from across
        /// a screen-share rather than needing the label read.
        var onHero: Bool = false

        /// One tint per state, so the pill is readable at a glance from across
        /// a screen-share rather than needing the label read.
        private var tint: (dot: Color, text: Color, background: Color) {
            if onHero {
                // **The recording overlay's vocabulary, which already solved
                // status on ink**: a SOLID capsule, so the two-second glance
                // ("is it ready") never depends on the frame underneath.
                // Label 14.78:1; dots 11.90, 7.90 and 6.26 against 3:1.
                let dot: Color
                switch status {
                case .ready: dot = Brand.statusReadyOnDark
                case .recording, .error: dot = Brand.statusLiveOnDark
                default: dot = Brand.statusBusyOnDark
                }
                return (dot, Brand.textOnDark, Brand.surfaceDark)
            }
            switch status {
            case .ready: return (theme.statusReady, theme.statusReady, theme.statusReady.opacity(Brand.selectedOpacity))
            case .recording: return (theme.statusLive, theme.statusLive, theme.statusLive.opacity(Brand.selectedOpacity))
            case .error: return (theme.statusLive, theme.statusLive, theme.statusLive.opacity(Brand.selectedOpacity))
            default: return (theme.statusBusy, theme.statusBusy, theme.statusBusy.opacity(Brand.selectedOpacity))
            }
        }

        var body: some View {
            HStack(spacing: 8) {
                Circle().fill(tint.dot).frame(width: 7, height: 7)
                Text(status.rawValue.replacingOccurrences(of: "...", with: ""))
                    .font(theme.textFont(size: 13))
            }
            .foregroundColor(tint.text)
            .padding(.horizontal, 15)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(tint.background)
                    .overlay(
                        Capsule().stroke(onHero ? Brand.textOnDark.opacity(0.30) : Color.clear, lineWidth: 1)
                    )
            )
        }
    }

    private struct FooterCell: View {
        @Environment(\.appTheme) private var theme
        let label: String
        let value: String
        var tint: Color?
        var onHero: Bool = false

        var body: some View {
            VStack(spacing: 3) {
                // The Eyebrow role: Inter 11 semibold, uppercase, +0.9pt
                // tracking. Eyebrows are the one place the ladder tracks
                // POSITIVE; everything larger tracks tighter.
                Text(label.uppercased())
                    .font(theme.eyebrowFont)
                    .tracking(0.9)
                    .foregroundColor(onHero ? Brand.secondaryOnDark : theme.textSecondary)
                Text(value)
                    .font(theme.textFont(size: 12, weight: 500))
                    .foregroundColor(tint ?? (onHero ? Brand.textOnDark : theme.textPrimary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
    }

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

        let hosting = NSHostingController(rootView: AFFlowThemedRoot {
            SettingsView(appState: appState, initialSection: section)
        })
        let created = NSWindow(contentViewController: hosting)
        created.title = "AF Flow"
        created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        created.setContentSize(NSSize(width: 1000, height: 720))
        created.minSize = NSSize(width: 900, height: 680)
        created.isReleasedWhenClosed = false
        // The window is one sheet, so the title bar is part of the sheet rather
        // than a strip above it. Both values come from the SKIN, not from the
        // brand: hardcoding them meant picking Space produced a paper title bar
        // around near-black content.
        //
        // Read once at creation. The view tree below updates live on a skin
        // change through `AFFlowThemedRoot`; the window chrome follows on the
        // next launch, which is the same behaviour the chrome had before.
        created.applyAFFlowSkin()
        created.titlebarAppearsTransparent = true
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
