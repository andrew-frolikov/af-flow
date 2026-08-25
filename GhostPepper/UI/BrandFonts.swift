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
    private static var cache: [Key: Font] = [:]

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
        let key = Key(face: "inter", size: size, weight: weight)
        if let hit = cache[key] { return hit }
        let font: Font
        if let ct = ctFont(inter, size: size, weight: weight) {
            font = Font(ct)
        } else {
            font = .system(size: size, weight: weight >= 600 ? .semibold : weight >= 500 ? .medium : .regular)
        }
        cache[key] = font
        return font
    }

    /// Fraunces, the display face.
    ///
    /// **Never give this user or model content.** Fraunces has no Cyrillic: a
    /// Russian phrase loses 13 of its 14 glyphs, and Andrew dictates Russian
    /// more often than English. It is for strings the app itself authors.
    /// The floor is 17pt; below that the serifs muddy and Inter takes over.
    static func display(size: CGFloat) -> Font {
        let clamped = max(size, 17)
        let key = Key(face: "fraunces", size: clamped, weight: 500)
        if let hit = cache[key] { return hit }
        let font: Font
        if let ct = ctFont(fraunces, size: clamped, weight: nil) {
            font = Font(ct)
        } else {
            font = .custom("Georgia", size: clamped)
        }
        cache[key] = font
        return font
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
