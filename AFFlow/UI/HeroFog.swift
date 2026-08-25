import SwiftUI
import AVFoundation
import AppKit

/// **The fog behind Home.**
///
/// Andrew's website opens on a looping clip of misty ridges and pines, and he
/// asked for it here: "I want my animation from my website's header woven in
/// organically, soft, beautiful, aesthetic", then "looped, cheap, not heavy,
/// playing pleasantly in the background."
///
/// Spec: `docs/design/af-flow-home-hero.md`. The parts that constrain this file:
///
/// - **The grade ships INSIDE the asset**, saturate 0.62 then blue gain 0.88.
///   Runtime filters would cost per frame and would let the poster drift from
///   the video. Measured on the shipped file: blue minus green went from +24.8
///   raw to +4.8 graded, which is what moves the clip off blue and into the
///   brand's green.
/// - **The poster IS frame zero of the graded encode**, extracted from it, so
///   the still and the first frame cannot disagree.
/// - **Ping-pong**, forward then reverse. The clip does not close its own loop:
///   fog banks form by the end that are absent at the start, so a plain loop
///   visibly jumps. Reverse costs the same as forward, measured, and fog
///   drifting back out is physically plausible in a way most footage is not.
/// - **Cost, measured**: 0.2 to 0.4% of one core and 45 MB while it plays, and
///   nothing at all when it does not.
struct HeroFog: View {
    /// Playback runs only while all three are true. `isVisible` must come from
    /// the WINDOW, never from `onDisappear`: `orderOut` does not unmount
    /// SwiftUI, which is how the debug log once kept writing raw transcriptions
    /// to disk with nothing on screen.
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shouldPlay: Bool { isVisible && !reduceMotion }

    var body: some View {
        ZStack {
            // The poster is always underneath. Under Reduce Motion it is the
            // whole treatment, and every contrast number still holds because
            // the scrims and plate above it are unchanged.
            if let poster = HeroFogAsset.poster {
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Brand.surfaceDark
            }

            if shouldPlay {
                HeroFogPlayerView()
                    // Frame zero equals the poster, so this fade is invisible
                    // and exists only to cover the first-frame wait.
                    .transition(.opacity)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .brandReveal(value: shouldPlay)
    }
}

/// Loads the two shipped assets once. A miss is not fatal: the fog is ambience,
/// and Home must still work if a resource ever fails to load.
enum HeroFogAsset {
    static let videoURL: URL? = Bundle.main.url(forResource: "hero-fog-960-graded", withExtension: "mp4")

    static let poster: NSImage? = {
        guard let url = Bundle.main.url(forResource: "hero-poster-graded", withExtension: "jpg") else { return nil }
        return NSImage(contentsOf: url)
    }()
}

/// The player, wrapped so its lifetime is tied to the view being on screen.
///
/// `dismantleNSView` releases the player rather than only pausing it, which is
/// what returns the measured 45 MB when Home is not being looked at.
private struct HeroFogPlayerView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = FogLayerView()
        view.wantsLayer = true
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    /// Hosts the player layer and keeps it filling the view. A plain NSView
    /// does not resize its sublayers, so the layer is laid out by hand.
    final class FogLayerView: NSView {
        var playerLayer: AVPlayerLayer?
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)   // never animate a resize
            playerLayer?.frame = bounds
            CATransaction.commit()
        }
    }

    @MainActor
    final class Coordinator {
        private var player: AVPlayer?
        private var observer: Any?
        private var endObserver: NSObjectProtocol?
        private weak var view: FogLayerView?

        /// 0.5x, so the ten second clip reads as twenty, matching the website.
        private static let rate: Float = 0.5

        func attach(to view: FogLayerView) {
            guard let url = HeroFogAsset.videoURL else { return }
            self.view = view

            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            // Ambience must never fight the audio session this app records with.
            player.audiovisualBackgroundPlaybackPolicy = .pauses
            // NOT `.pause`. At the forward end AVPlayer would set the rate to
            // zero, and a zero rate is a state the turn below cannot leave, so
            // one missed callback froze the clip after a single traversal.
            player.actionAtItemEnd = .none
            self.player = player

            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer?.addSublayer(layer)
            view.playerLayer = layer

            // PING-PONG. At the end, run backwards; at the start, run forwards.
            // A boundary observer would need exact times, and the turn has to
            // survive a rate that drifts, so this samples instead.
            observer = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                guard let self, let player = self.player,
                      let item = player.currentItem,
                      item.status == .readyToPlay,
                      item.duration.isNumeric else { return }
                let now = CMTimeGetSeconds(time)
                let end = CMTimeGetSeconds(item.duration)
                guard end > 0.5 else { return }
                let margin = 0.25

                // **A zero rate must be recoverable.** If the main queue is
                // busy the callback can be delayed past the turn and the
                // player can come to rest at an end. Deciding the next
                // direction from POSITION rather than from the current rate
                // means the loop restarts itself instead of freezing.
                if player.rate == 0 {
                    player.rate = now >= end - margin ? -Self.rate : Self.rate
                    return
                }
                if player.rate > 0, now >= end - margin {
                    player.rate = -Self.rate
                } else if player.rate < 0, now <= margin {
                    player.rate = Self.rate
                }
            }

            // Backstop for the case the periodic callback misses the turn
            // completely: reaching the end is itself the signal to reverse.
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                guard let self, let player = self.player else { return }
                player.rate = -Self.rate
            }

            // Restart deterministically from frame zero. Ambience has no plot,
            // and frame zero is the poster, so a restart cannot be seen.
            player.seek(to: .zero)
            player.rate = Self.rate
        }

        func tearDown() {
            if let observer { player?.removeTimeObserver(observer) }
            observer = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
            player?.pause()
            view?.playerLayer?.player = nil
            view?.playerLayer?.removeFromSuperlayer()
            view?.playerLayer = nil
            player = nil
        }

        deinit {
            // `deinit` is nonisolated on a `@MainActor` type, so it must not
            // touch main-actor state. `dismantleNSView` already calls
            // `tearDown()` on the main actor for every real teardown; the only
            // thing safe to do here is drop the notification observer, which
            // NotificationCenter allows from any thread.
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        }
    }
}

// MARK: - The surfaces drawn over the fog

/// The scrims, the soft plate and the footer band, all specified as measured
/// floors rather than as looks.
enum HeroSurface {
    /// The website's own two scrims, carried over verbatim. **Mood, not
    /// guarantee**: measured over real frames, this alone falls to 1.76:1 for
    /// paper text at its weak end, which is why the soft plate exists.
    static let diagonalScrim = LinearGradient(
        stops: [
            .init(color: Color(hex: 0x17201D).opacity(0.88), location: 0.0),
            .init(color: Color(hex: 0x17201D).opacity(0.72), location: 0.34),
            .init(color: Color(hex: 0x17201D).opacity(0.40), location: 0.66),
            .init(color: Color(hex: 0x17201D).opacity(0.24), location: 1.0)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let groundingScrim = LinearGradient(
        stops: [
            .init(color: Color(hex: 0x17201D).opacity(0.55), location: 0.0),
            .init(color: Color(hex: 0x17201D).opacity(0.0), location: 0.45)
        ],
        startPoint: .bottom, endPoint: .top
    )

    /// **The soft plate. This is the contrast guarantee, so its numbers are not
    /// decoration.**
    ///
    /// Ink at an effective 0.84 under the text block. The bound: compositing is
    /// monotone per channel, so ink at 0.84 over ANY SDR video pixel is darker
    /// than ink at 0.84 over pure white, which is `#3C4441` at luminance
    /// 0.0544. Every ratio below is therefore a floor that holds on every frame
    /// of any SDR encode, not a measurement of one frame:
    ///
    /// - paper `#F5F1E8` 8.92:1, dark-muted `#B9C3BE` 5.56:1, mist `#A7E8C6`
    ///   7.18:1, all against the 4.5 minimum
    /// - clay dot `#E8836B` 3.78:1 and ochre dot `#E0A94E` 4.77:1 against 3
    ///
    /// `#E8836B` measures 3.78 and so is BANNED as body text on the fog: an
    /// error message here is set in paper with a clay dot marker instead.
    static let plateAlpha: Double = 0.84

    /// The flat core extends this far past the text block on every side, so a
    /// glyph can never sit in the falloff.
    static let plateCoreInset: CGFloat = 36

    /// The falloff width beyond the core, 0.84 down to nothing.
    static let plateFeather: CGFloat = 56

    /// The feather width, in points, from the flat core outward.
    ///
    /// There is deliberately no ready-made gradient here. A fixed radius could
    /// not promise the floor for a block whose size changes, so the plate is
    /// built in `AFFlowHomeView` from the text block's own bounds.
    /// A flat 0.88 band under the footer, composited `#333B38` at luminance
    /// 0.0409. Eyebrows 6.39:1, values 10.25:1, the privacy value in mist
    /// 8.25:1.
    static let footerBandAlpha: Double = 0.88

    /// **The sidebar veil, Andrew's own idea and his chosen density.**
    ///
    /// He asked for the image to continue behind the sidebar "a little in the
    /// background, so it does not block or hurt readability, just barely
    /// catchable, so you understand there is a picture underneath". Extending
    /// the one image through the whole window is also what removes the vertical
    /// seam without bounding the hero, which is the alternative he rejected.
    ///
    /// He chose a flat 0.86 after seeing 0.92, 0.86 and a graded version.
    /// Measured at 0.86 over the DARKEST fog, which is the worst case for dark
    /// text: row labels in ink 10.74:1, row icons in muted 3.50:1 which clears
    /// the 3:1 non-text minimum. **The version line had to move from muted to
    /// ink**: at 0.86 muted text measures 3.50:1 and fails. The fog's visible
    /// swing at this density is 32 of 255, so it genuinely reads.
    static let sidebarVeilAlpha: Double = 0.86
}
