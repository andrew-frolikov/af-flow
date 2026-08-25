import SwiftUI
import CoreText
import AppKit

/// The brand's two faces, loaded from the bundle **by file URL**.
///
/// Loading by family name is not an option and this is measured, not stylistic:
///
/// - `Fraunces-opsz9-wght500.ttf` and any variable Fraunces share the family
///   name "Fraunces", so a name lookup can return either. That cost a wrong
///   measurement during the design pass.
/// - Inter's weight axis is **unreachable by name**. Asking a name-resolved
///   Inter for regular, medium, semibold and bold returns four identical fonts
///   (advance 205.66 for all four at 40pt). Loaded by URL and instanced on the
///   `wght` axis, the same four give 205.66, 210.14, 214.61 and 219.08. So the
///   app would silently have shipped one weight.
///
/// Everything below therefore builds `CTFont` instances directly and wraps them,
/// which never consults the font manager's name table.
enum BrandFonts {

    // MARK: - The files

    private static let fraunces: CGFont? = load("Fraunces-opsz9-wght500")
    private static let inter: CGFont? = load("Inter-variable")

    private static func load(_ name: String) -> CGFont? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
            assertionFailure("brand font \(name).ttf is not in the bundle")
            return nil
        }
        // Registering makes the face available to AppKit text views too, which
        // do not go through SwiftUI's Font. A duplicate registration is not an
        // error worth failing on, so the result is deliberately unused.
        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        guard let provider = CGDataProvider(url: url as CFURL) else { return nil }
        return CGFont(provider)
    }

    // MARK: - Building a face

    private struct Key: Hashable { let face: String; let size: CGFloat; let weight: CGFloat }
    /// A shared mutable static reached from view bodies. Every caller today is
    /// on the main thread, but an off-main one added later would race on it
    /// silently, so it is locked rather than left to convention. Marking it
    /// `@MainActor` was tried and cascades into the theme's non-isolated font
    /// properties, which would spread isolation through every call site for no
    /// gain over a lock this uncontended.
    private static let cacheLock = NSLock()
    private static var cache: [Key: Font] = [:]

    private static func cached(_ key: Key, _ make: () -> Font) -> Font {
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let font = make()
        cacheLock.lock()
        cache[key] = font
        cacheLock.unlock()
        return font
    }

    /// A `CTFont` at an explicit `wght`, or nil if the file is missing.
    private static func ctFont(_ cgFont: CGFont?, size: CGFloat, weight: CGFloat?) -> CTFont? {
        guard let cgFont else { return nil }
        let base = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
        guard let weight else { return base }
        let variations: [CFString: Any] = ["Weight" as CFString: weight]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base),
            [kCTFontVariationAttribute: variations] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// Inter at a given size and weight. Falls back to the system face, which
    /// is the right failure: an app that renders is better than one that does
    /// not, and the assertion above catches a missing file in development.
    static func text(size: CGFloat, weight: CGFloat = 400) -> Font {
        cached(Key(face: "inter", size: size, weight: weight)) {
            if let ct = ctFont(inter, size: size, weight: weight) { return Font(ct) }
            return .system(size: size, weight: weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular)
        }
    }

    /// Fraunces, the display face.
    ///
    /// **Never give this user or model content.** Fraunces has no Cyrillic: a
    /// Russian phrase loses 13 of its 14 glyphs, and Andrew dictates Russian
    /// more often than English. It is for strings the app itself authors.
    /// The floor is 17pt; below that the serifs muddy and Inter takes over.
    /// The resolved point size for a display request, exposed so the floor can
    /// actually be asserted. `String(describing:)` on a `Font` reveals only the
    /// provider type, so a test comparing two `Font` values cannot see a size
    /// at all and passes whether or not the clamp exists.
    static func displayPointSize(for size: CGFloat) -> CGFloat { max(size, 17) }

    static func display(size: CGFloat) -> Font {
        let clamped = displayPointSize(for: size)
        return cached(Key(face: "fraunces", size: clamped, weight: 500)) {
            if let ct = ctFont(fraunces, size: clamped, weight: nil) { return Font(ct) }
            return .custom("Georgia", size: clamped)
        }
    }

    /// Inter as an `NSFont`, for the AppKit text views that never go through
    /// SwiftUI's `Font`. Without this they stay on the system face while
    /// everything around them is Inter, which is visible as a face swap the
    /// moment a search box is focused.
    static func nsText(size: CGFloat, weight: CGFloat = 400) -> NSFont? {
        guard let ct = ctFont(inter, size: size, weight: weight) else { return nil }
        return ct as NSFont
    }

    // MARK: - Did the real faces actually load

    /// True when both brand faces came out of the bundle. The tests assert this
    /// so a silent fallback to the system face cannot pass for the brand.
    static var bothFacesLoaded: Bool { fraunces != nil && inter != nil }

    /// Measured identity of what actually loaded, for the acceptance test.
    /// The advance of "AF" at 72pt in the shipped Fraunces cut is 96.05.
    static func frauncesAdvanceOfAFAt72() -> CGFloat? {
        guard let ct = ctFont(fraunces, size: 72, weight: nil) else { return nil }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "AF", attributes: [.font: ct])
        )
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Inter's weights must be distinct, which is the whole reason for loading
    /// by URL. Returns the advance of a probe string at each weight.
    static func interAdvances(at size: CGFloat = 40) -> [CGFloat] {
        [400, 500, 600].compactMap { w in
            guard let ct = ctFont(inter, size: size, weight: w) else { return nil }
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "Handgloves", attributes: [.font: ct])
            )
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
    }
}

/// The type ladder from `docs/design/af-flow-visual-system.md` section 4.3.
///
/// Roles rather than sizes, so a call site says what a thing IS and the ladder
/// decides how it looks. Tracking is applied by the caller with `.tracking()`
/// where the ladder specifies it.
extension AppTheme {
    private var usesBrandFaces: Bool { id == .current }

    /// The one display moment on a surface. Fraunces 24.
    var displayFont: Font { usesBrandFaces ? BrandFonts.display(size: 24) : .system(size: 24, weight: .semibold) }
    /// The heading at the top of a detail pane. Fraunces 21.
    var sectionTitleFont: Font { usesBrandFaces ? BrandFonts.display(size: 21) : .system(size: 21, weight: .semibold) }
    /// "AF Flow" beside the mark. Fraunces 17.
    var brandNameFont: Font { usesBrandFaces ? BrandFonts.display(size: 17) : .system(size: 17, weight: .semibold) }

    /// Group labels and footer cell labels. Inter 11 semibold, uppercase,
    /// +0.9pt tracking applied at the call site.
    var eyebrowFont: Font { usesBrandFaces ? BrandFonts.text(size: 11, weight: 600) : .system(size: 11, weight: .semibold) }
    /// Default text everywhere. Inter 13.
    var bodyFont: Font { usesBrandFaces ? BrandFonts.text(size: 13) : .system(size: 13) }
    /// Control labels and sidebar rows. Inter 13 medium.
    var bodyStrongFont: Font { usesBrandFaces ? BrandFonts.text(size: 13, weight: 500) : .system(size: 13, weight: .medium) }
    /// Buttons, keycaps, the selected sidebar row. Inter 13 semibold.
    var emphasisFont: Font { usesBrandFaces ? BrandFonts.text(size: 13, weight: 600) : .system(size: 13, weight: .semibold) }
    /// Help text, timestamps, the version line. Inter 11.5.
    var captionFont: Font { usesBrandFaces ? BrandFonts.text(size: 11.5) : .system(size: 11.5) }
    /// Long-form reading: transcript notes, history bodies. Inter 15.
    var readingFont: Font { usesBrandFaces ? BrandFonts.text(size: 15) : .system(size: 15) }
    /// The transcript article body. Inter 16.
    var readingLargeFont: Font { usesBrandFaces ? BrandFonts.text(size: 16) : .system(size: 16) }

    /// Arbitrary sizes for surfaces the ladder does not name yet, so a sweep
    /// can move a call site onto the brand face without inventing a role.
    func textFont(size: CGFloat, weight: CGFloat = 400) -> Font {
        usesBrandFaces ? BrandFonts.text(size: size, weight: weight)
                       : .system(size: size, weight: weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular)
    }

    /// The diagnostic face. The brand adds no third family, so this is the
    /// system mono deliberately.
    func monoFont(size: CGFloat = 12) -> Font { .system(size: size, design: .monospaced) }
}

// MARK: - Buttons

/// The brand's two button shapes, from design section 5.3.
///
/// They read the theme, so the novelty skins keep their own colours, and they
/// drop to square corners on Windows 95 for the same reason the sidebar rows
/// do: a capsule is a brand shape, not a universal one.
private struct AFFlowButtonSurface<Content: View>: View {
    let theme: AppTheme
    let isPrimary: Bool
    let isDestructive: Bool
    let isPressed: Bool
    let content: Content
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovered = false

    /// `.controlSize` only affects built-in styles, so a custom style has to
    /// honour it itself. Thirteen call sites asked for `.small` and were
    /// silently getting a full-size 28x64 capsule, which turned a compact
    /// toolbar row into four large buttons.
    private var height: CGFloat {
        switch controlSize {
        case .mini: 18
        case .small: 22
        default: 28
        }
    }

    private var horizontalPadding: CGFloat {
        switch controlSize {
        case .mini: 8
        case .small: 10
        default: 14
        }
    }

    /// Only the PRIMARY button carries the spec's 64pt minimum. A ghost button
    /// is often an icon, and forcing 64pt on an icon-only refresh button made
    /// it three times wider than its glyph.
    private var minimumWidth: CGFloat? {
        guard isPrimary else { return nil }
        return controlSize == .regular ? 64 : nil
    }

    private var textColour: Color {
        if isPrimary { return theme.accentText }
        return isDestructive ? theme.statusLive : theme.textPrimary
    }

    private var fill: Color {
        // A disabled control must not look hovered. Nothing clears the hover
        // state when a button becomes disabled underneath the pointer.
        guard isEnabled else { return isPrimary ? theme.accent : .clear }
        if isPrimary {
            return isPressed ? theme.accentPressed : (isHovered ? theme.accentHover : theme.accent)
        }
        return isPressed ? theme.pressedFill : (isHovered ? theme.hoverFill : .clear)
    }

    var body: some View {
        content
            .font(theme.emphasisFont)
            .foregroundStyle(textColour)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .frame(minWidth: minimumWidth)
            .background(shape.fill(fill))
            .overlay(isPrimary ? nil : shape.stroke(theme.separator, lineWidth: 1))
            // A disabled control is dimmed rather than recoloured, so the
            // shape it had is still the shape it has.
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            // Moving 70 buttons off `.bordered` removed the system focus ring
            // they used to get, which left custom buttons with NO visible
            // keyboard focus indicator at all. This is the spec's ring:
            // 2pt ink at 2pt offset, 14.78:1 against the ground.
            .focusable(isEnabled)
            .focusEffectDisabled(false)
            .onHover { isHovered = $0 && isEnabled }
            .brandMotion(value: isHovered)
            .brandMotion(value: isPressed)
    }

    /// One shape, one radius. A 14pt radius on a 28pt control IS a capsule, so
    /// this avoids a conditional shape type while still letting Windows 95 keep
    /// its square corners.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .windows95 ? 0 : height / 2, style: .continuous)
    }
}

/// Pine fill, paper text. The one strong action on a surface.
struct AFFlowPrimaryButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        AFFlowButtonSurface(theme: theme, isPrimary: true, isDestructive: false,
                            isPressed: configuration.isPressed, content: configuration.label)
    }
}

/// Transparent with a hairline. Everything that is not the one strong action.
struct AFFlowGhostButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        AFFlowButtonSurface(theme: theme, isPrimary: false,
                            isDestructive: configuration.role == .destructive,
                            isPressed: configuration.isPressed, content: configuration.label)
    }
}

// MARK: - Motion

/// Motion, with the canon's reduced-motion rule applied.
///
/// The canon calls this non-negotiable and it was simply missing: three
/// repeating animations ran and ten `.animation()` modifiers fired regardless
/// of the system setting. Under Reduce Motion every transition collapses to
/// nothing and the repeating pulses hold still. **Nothing is lost by that**,
/// because in every case here the state is also carried by colour: the overlay
/// dot's clay still says recording when it stops pulsing.
extension View {
    /// A micro-interaction, 180ms ease per the canon, or nothing at all when
    /// the system asks for reduced motion.
    func brandMotion<V: Equatable>(value: V) -> some View {
        modifier(BrandMotionModifier(value: value, duration: 0.18))
    }

    /// A larger reveal, on the canon's own curve.
    func brandReveal<V: Equatable>(value: V) -> some View {
        modifier(BrandRevealModifier(value: value))
    }

    /// A repeating pulse that HOLDS STILL under reduced motion, at full opacity
    /// rather than mid-fade, so the dot never rests in a dimmed state.
    func brandPulse(active: Bool, isPulsing: Bool) -> some View {
        modifier(BrandPulseModifier(active: active, isPulsing: isPulsing))
    }
}

private struct BrandMotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V
    let duration: Double
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .easeOut(duration: duration), value: value)
    }
}

private struct BrandRevealModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V
    func body(content: Content) -> some View {
        content.animation(
            reduceMotion ? nil : .timingCurve(0.22, 0.7, 0.2, 1, duration: 0.65),
            value: value
        )
    }
}

private struct BrandPulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    let isPulsing: Bool
    func body(content: Content) -> some View {
        content
            .opacity(!reduceMotion && isPulsing && active ? 0.4 : 1.0)
            .animation(
                reduceMotion ? nil
                    : (active ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default),
                value: isPulsing
            )
    }
}
