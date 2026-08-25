import XCTest
import SwiftUI
@testable import AFFlow

/// **The brand palette is the canon's palette, and it is measured.**
///
/// Two controls in one file, both of which exist because this project has
/// already paid for their absence:
///
/// 1. Every brand token is pinned to the exact value in
///    `AndrewFrolikov OS/Context/brand-visual.md`. A colour nudged in a view
///    file is a divergence; a colour nudged here fails a test.
/// 2. Every pair in section 7 of `docs/design/af-flow-visual-system.md` is
///    re-derived with the WCAG relative-luminance formula and asserted against
///    its minimum. The canon's hard rule is "contrast is measured, never
///    eyeballed", learned twice the expensive way: a mint card shipped at
///    4.24:1 and a lime focus ring at 1.01:1.
///
/// The app it replaces shipped three text tokens below 4.5:1 on its own paper
/// (muted 3.44, the teal signal 3.89, gold 3.15). That is what this pins shut.
final class BrandPaletteTests: XCTestCase {

    // MARK: - Colour arithmetic

    /// sRGB component to linear light, per WCAG 2.x.
    private func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private func relativeLuminance(_ rgb: (Double, Double, Double)) -> Double {
        0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }

    private func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Resolve a SwiftUI Color to sRGB components, the way it will actually be drawn.
    private func components(_ color: Color, file: StaticString = #filePath, line: UInt = #line) -> (Double, Double, Double) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else {
            XCTFail("colour did not resolve into sRGB", file: file, line: line)
            return (0, 0, 0)
        }
        return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
    }

    private func rgb(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255.0,
         Double((hex >> 8) & 0xFF) / 255.0,
         Double(hex & 0xFF) / 255.0)
    }

    /// Composite a colour at `alpha` over an opaque background, which is what
    /// SwiftUI does when a token is expressed as an opacity of another token,
    /// **then quantise to 8 bits per channel**.
    ///
    /// The rounding is not a nicety. A continuous composite of ink at 6% over
    /// the ground yields a contrast of 13.1665, while the pixel that actually
    /// reaches the screen is `#E8E4DC` and measures 13.14. The design document
    /// specifies the second because that is what a person sees and what a
    /// screenshot sampler will read back. Compositing without the rounding made
    /// this test disagree with the document by 0.0265 on pair 16, and the
    /// document was right.
    private func over(_ fg: (Double, Double, Double), _ bg: (Double, Double, Double), _ alpha: Double) -> (Double, Double, Double) {
        return (((fg.0 * alpha + bg.0 * (1 - alpha)) * 255).rounded() / 255,
                ((fg.1 * alpha + bg.1 * (1 - alpha)) * 255).rounded() / 255,
                ((fg.2 * alpha + bg.2 * (1 - alpha)) * 255).rounded() / 255)
    }

    private func assertSameColour(_ color: Color, _ hex: UInt32, _ name: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let got = components(color), want = rgb(hex)
        // One 8-bit step of tolerance, no more: this is an exact-value pin.
        let tolerance = 1.0 / 255.0
        XCTAssertEqual(got.0, want.0, accuracy: tolerance, "\(name) red", file: file, line: line)
        XCTAssertEqual(got.1, want.1, accuracy: tolerance, "\(name) green", file: file, line: line)
        XCTAssertEqual(got.2, want.2, accuracy: tolerance, "\(name) blue", file: file, line: line)
    }

    // MARK: - 1. The tokens are the canon's values

    func testBrandTokensMatchTheCanonExactly() {
        assertSameColour(Brand.ground, 0xF5F1E8, "ground / --paper")
        assertSameColour(Brand.well, 0xFFFDF7, "well / --panel")
        assertSameColour(Brand.textPrimary, 0x17201D, "textPrimary / --ink")
        assertSameColour(Brand.textSecondary, 0x626C68, "textSecondary / --muted")
        assertSameColour(Brand.hairline, 0xD8D3C8, "hairline / --line")
        assertSameColour(Brand.accent, 0x1E5C46, "accent / --signal pine")
        assertSameColour(Brand.onAccent, 0xF5F1E8, "onAccent / --signal-ink")
        assertSameColour(Brand.mist, 0xA7E8C6, "mist / --signal-soft")
        assertSameColour(Brand.surfaceDark, 0x17201D, "surfaceDark / --dark")
        assertSameColour(Brand.textOnDark, 0xF5F1E8, "textOnDark / --dark-ink")
        assertSameColour(Brand.secondaryOnDark, 0xB9C3BE, "secondaryOnDark / --dark-muted")
    }

    /// The retired colours must never come back. Lime was retired 2026-08-24
    /// and terracotta was retired from the mark the same day.
    func testRetiredColoursAreAbsentFromTheBrandSkin() {
        let retired: [UInt32] = [
            0x8F5F44,   // terracotta, retired from the mark
            0x2E8B7A,   // the app's old teal signal, 3.89:1 and off-canon
            0x7C8797,   // the app's old muted, 3.44:1
            0xB9822B,   // the app's old gold, 3.15:1
            0x1B2A3B,   // the app's old blue-cast ink
            0xB0472F    // Home's old red, which the design document replaces
        ]
        let brandSkin = AppTheme(id: .current)
        let live: [(String, Color)] = [
            ("accent", brandSkin.accent), ("textPrimary", brandSkin.textPrimary),
            ("textSecondary", brandSkin.textSecondary), ("windowBackground", brandSkin.windowBackground),
            ("textBackground", brandSkin.textBackground), ("separator", brandSkin.separator),
            ("statusReady", brandSkin.statusReady), ("statusBusy", brandSkin.statusBusy),
            ("statusLive", brandSkin.statusLive)
        ]
        for (name, colour) in live {
            let got = components(colour)
            for hex in retired {
                let want = rgb(hex)
                let identical = abs(got.0 - want.0) < 0.004 && abs(got.1 - want.1) < 0.004 && abs(got.2 - want.2) < 0.004
                XCTAssertFalse(identical, "\(name) is a retired colour, \(String(format: "#%06X", hex))")
            }
        }
    }

    // MARK: - 2. The brand skin wires the tokens through

    func testBrandSkinUsesBrandTokens() {
        let t = AppTheme(id: .current)
        assertSameColour(t.windowBackground, 0xF5F1E8, "windowBackground")
        assertSameColour(t.textBackground, 0xFFFDF7, "textBackground")
        assertSameColour(t.accent, 0x1E5C46, "accent")
        assertSameColour(t.separator, 0xD8D3C8, "separator")
        assertSameColour(t.textPrimary, 0x17201D, "textPrimary")
        assertSameColour(t.textSecondary, 0x626C68, "textSecondary")
        assertSameColour(t.statusReady, 0x1E5C46, "statusReady")
        assertSameColour(t.statusBusy, 0x7A5414, "statusBusy")
        assertSameColour(t.statusLive, 0x9E3B24, "statusLive")
    }

    /// The monolith rule, at the token level: the control background is the
    /// window background, so no third region colour can exist.
    func testControlBackgroundIsTheGroundSoThereIsNoThirdRegionColour() {
        let t = AppTheme(id: .current)
        XCTAssertEqual(components(t.controlBackground).0, components(t.windowBackground).0, accuracy: 1.0 / 255.0)
        XCTAssertEqual(components(t.controlBackground).1, components(t.windowBackground).1, accuracy: 1.0 / 255.0)
        XCTAssertEqual(components(t.controlBackground).2, components(t.windowBackground).2, accuracy: 1.0 / 255.0)
    }

    /// The novelty skins must keep working, and this must be able to FAIL.
    ///
    /// Its first version only asserted that each slot resolved into sRGB, which
    /// every colour form does, so it could not fail and would have passed if
    /// every novelty case returned pine. Its own doc comment named the bug it
    /// was supposed to catch and then did not catch it.
    ///
    /// It now asserts the thing that matters: on a novelty skin, the coloured
    /// slots must NOT be the brand's values. Picking Windows 95 must show no
    /// pine.
    func testNoveltySkinsShowNoneOfTheBrandsColours() {
        let brandValues: [(String, (Double, Double, Double))] = [
            ("accent/pine", components(Brand.accent)),
            ("ground/paper", components(Brand.ground)),
            ("ink", components(Brand.textPrimary)),
            ("muted", components(Brand.textSecondary)),
            ("statusBusy ochre", components(Brand.statusBusy)),
            ("statusLive clay", components(Brand.statusLive))
        ]
        for id in AppThemeID.allCases where id != .current {
            let t = AppTheme(id: id)
            let slots: [(String, Color)] = [
                ("accent", t.accent), ("windowBackground", t.windowBackground),
                ("textBackground", t.textBackground), ("controlBackground", t.controlBackground),
                ("textPrimary", t.textPrimary), ("textSecondary", t.textSecondary),
                ("statusReady", t.statusReady), ("statusBusy", t.statusBusy),
                ("statusLive", t.statusLive), ("overlayText", t.overlayText)
            ]
            for (slotName, colour) in slots {
                guard let resolved = NSColor(colour).usingColorSpace(.sRGB) else {
                    XCTFail("\(id.rawValue).\(slotName) did not resolve into sRGB")
                    continue
                }
                let got = (Double(resolved.redComponent), Double(resolved.greenComponent), Double(resolved.blueComponent))
                for (brandName, want) in brandValues {
                    let identical = abs(got.0 - want.0) < 0.004
                        && abs(got.1 - want.1) < 0.004
                        && abs(got.2 - want.2) < 0.004
                    XCTAssertFalse(identical, "\(id.rawValue).\(slotName) is the brand's \(brandName)")
                }
            }
        }
    }

    // MARK: - 3. The contrast checklist, section 7 of the design document

    /// **Every colour here is read from the shipping theme, never typed in.**
    ///
    /// The first version of this test named each foreground and background as a
    /// hex literal. It therefore proved that the design document's arithmetic
    /// is self-consistent and proved nothing whatsoever about the app: it would
    /// have passed unchanged against a full revert to the orange-on-system-grey
    /// palette. A reviewer caught that, and it is the same defect this project
    /// has recorded before, an upper bound satisfied by never firing.
    ///
    /// Now a reverted token changes a measured ratio and the assertion fails.
    func testEveryContrastPairInTheDesignDocumentPasses() {
        let t = AppTheme(id: .current)
        let ground = components(t.windowBackground)
        let well = components(t.textBackground)
        let ink = components(t.textPrimary)
        let muted = components(t.textSecondary)
        let accent = components(t.accent)
        let dark = components(Brand.surfaceDark)

        // Composites are derived from the live tokens and the live opacities,
        // so an edit to either is caught.
        let hoverFill = over(ink, ground, Brand.hoverOpacity)
        let pressedFill = over(ink, ground, Brand.pressedOpacity)
        let selectedFill = over(accent, ground, Brand.selectedOpacity)
        let busyFill = over(components(t.statusBusy), ground, Brand.selectedOpacity)
        let liveFill = over(components(t.statusLive), ground, Brand.selectedOpacity)

        let pairs: [(Int, (Double, Double, Double), (Double, Double, Double), Double, Double, String)] = [
            (1, ink, ground, 4.5, 14.78, "body text on ground"),
            (2, ink, well, 4.5, 16.37, "text in wells"),
            (3, muted, ground, 4.5, 4.82, "secondary on ground"),
            (4, muted, well, 4.5, 5.34, "placeholders in wells"),
            (5, accent, ground, 4.5, 6.97, "links, ready text, focus tint"),
            (6, components(t.accentText), accent, 4.5, 6.97, "primary button, selected sidebar row"),
            (7, components(t.accentText), components(t.accentHover), 4.5, 8.99, "primary button hover"),
            (8, components(t.accentText), components(t.accentPressed), 4.5, 11.03, "primary button pressed"),
            (9, components(t.statusLive), ground, 4.5, 6.00, "error text, destructive, live dot"),
            (10, components(t.statusLive), well, 4.5, 6.65, "error text in wells"),
            (11, components(t.statusBusy), ground, 4.5, 6.00, "busy text and dot"),
            (12, components(t.accentText), components(t.statusLive), 4.5, 6.00, "destructive filled confirm"),
            (13, components(t.statusReady), selectedFill, 4.5, 5.81, "ready pill text on its fill"),
            (14, components(t.statusBusy), busyFill, 4.5, 5.06, "busy pill text on its fill"),
            (15, components(t.statusLive), liveFill, 4.5, 5.02, "live pill text on its fill"),
            (16, ink, hoverFill, 4.5, 13.14, "text on hover fill"),
            (17, ink, pressedFill, 4.5, 12.16, "text on pressed fill"),
            (18, ink, selectedFill, 4.5, 12.32, "text on selected rows"),
            (19, components(t.overlayText), dark, 4.5, 14.78, "overlay primary text"),
            (20, components(t.overlaySecondaryText), dark, 4.5, 9.21, "overlay secondary text"),
            (21, components(t.overlayStatusReady), dark, 3.0, 11.90, "overlay ready dot"),
            (22, components(t.overlayStatusBusy), dark, 3.0, 7.90, "overlay busy dot"),
            (23, components(t.overlayStatusLive), dark, 3.0, 6.26, "overlay live dot"),
            // Pair 24 measured ink on ground and called itself the focus
            // ring, which is pair 1 under another name. The ring the app
            // actually draws is the system one, tinted by the accent asset,
            // so the pair that matters is the ACCENT against the ground and
            // `testTheAppAccentColourAssetIsThePine` pins the asset itself.
            (24, accent, ground, 3.0, 6.97, "focus ring, accent on ground")
        ]
        for (n, fg, bg, minimum, expected, what) in pairs {
            let measured = contrast(fg, bg)
            XCTAssertGreaterThanOrEqual(
                measured, minimum,
                String(format: "pair %d (%@) measures %.2f:1, below its %.1f:1 minimum", n, what, measured, minimum)
            )
            XCTAssertEqual(
                measured, expected, accuracy: 0.01,
                String(format: "pair %d (%@) measures %.2f:1 but the design document says %.2f:1", n, what, measured, expected)
            )
        }
    }

    /// The state tints, composited from the live tokens and the live opacities.
    func testStateTintsCompositeToTheDocumentedValues() {
        let t = AppTheme(id: .current)
        let ground = components(t.windowBackground)
        let cases: [(String, (Double, Double, Double), UInt32)] = [
            ("hoverFill, ink at 6%", over(components(t.textPrimary), ground, Brand.hoverOpacity), 0xE8E4DC),
            ("pressedFill, ink at 10%", over(components(t.textPrimary), ground, Brand.pressedOpacity), 0xDFDCD4),
            ("selectedFill, pine at 12%", over(components(t.accent), ground, Brand.selectedOpacity), 0xDBDFD5),
            ("busy pill fill, ochre at 12%", over(components(t.statusBusy), ground, Brand.selectedOpacity), 0xE6DECF),
            ("live pill fill, clay at 12%", over(components(t.statusLive), ground, Brand.selectedOpacity), 0xEBDBD0)
        ]
        for (name, got, want) in cases {
            let expected = rgb(want)
            XCTAssertEqual(got.0, expected.0, accuracy: 1.0 / 255.0, "\(name) red")
            XCTAssertEqual(got.1, expected.1, accuracy: 1.0 / 255.0, "\(name) green")
            XCTAssertEqual(got.2, expected.2, accuracy: 1.0 / 255.0, "\(name) blue")
        }
    }

    /// The two pairs the document bans by name, derived from live tokens so
    /// the ban keeps its reason if a token moves.
    func testTheBannedPairsStillFailSoTheBanKeepsItsReason() {
        let t = AppTheme(id: .current)
        let selectedFill = over(components(t.accent), components(t.windowBackground), Brand.selectedOpacity)
        XCTAssertLessThan(contrast(components(t.textSecondary), selectedFill), 4.5,
                          "secondary on selectedFill: if this now passes, section 5.6's rule can change")
        XCTAssertLessThan(contrast(components(t.textSecondary), rgb(0xE7E2D8)), 4.5,
                          "secondary on --outer: if this now passes, --outer could be used")
    }

    // MARK: - 4. The brand faces actually loaded

    /// **A silent fallback to the system face must not pass for the brand.**
    ///
    /// `BrandFonts` falls back to `.system` when a file is missing, which is the
    /// right runtime behaviour and the wrong thing to ship unnoticed. This test
    /// is the only thing standing between "we bundled Inter" and San Francisco
    /// wearing its name.
    func testBothBrandFacesLoadedFromTheBundle() {
        XCTAssertTrue(
            BrandFonts.bothFacesLoaded,
            "Fraunces or Inter did not load from the app bundle, so the app is silently running on the system face"
        )
    }

    /// Inter's weight axis is unreachable by family name: asking a name-resolved
    /// Inter for regular, medium and semibold returns three identical fonts.
    /// Loading by URL and instancing the `wght` axis is what makes the ladder's
    /// three weights real, and this asserts they are actually distinct.
    func testIntersThreeWeightsAreActuallyDifferent() {
        let advances = BrandFonts.interAdvances()
        XCTAssertEqual(advances.count, 3, "Inter did not produce three weights")
        guard advances.count == 3 else { return }
        XCTAssertGreaterThan(advances[1], advances[0],
                             "medium is not wider than regular, so the wght axis was not applied")
        XCTAssertGreaterThan(advances[2], advances[1],
                             "semibold is not wider than medium, so the wght axis was not applied")
    }

    /// The shipped Fraunces cut, identified by measurement rather than by name.
    /// 96.05 is the advance of "AF" at 72pt in `Fraunces-opsz9-wght500.ttf`,
    /// measured on this Mac. The design document originally recorded 89.62,
    /// which is the VARIABLE font at weight 500 and a different file.
    func testTheShippedFrauncesIsTheOneTheMarkIsBuiltFrom() {
        guard let advance = BrandFonts.frauncesAdvanceOfAFAt72() else {
            XCTFail("Fraunces did not load"); return
        }
        XCTAssertEqual(Double(advance), 96.05, accuracy: 0.05,
                       "the loaded Fraunces is not the cut the mark is built from")
    }

    /// The ladder's floor. Fraunces below 17pt muddies, so a smaller display
    /// request must clamp rather than quietly render an illegible serif.
    ///
    /// **This test used to be unable to fail.** It compared `String(describing:)`
    /// of two `Font` values, which reveals only the provider TYPE: by that
    /// measure `display(24)` equals `display(17)`, and `Font.system(size: 15)`
    /// equals `size: 13`. Deleting the clamp left it green. It asserts the
    /// resolved point size now, which is a number and can disagree.
    func testTheFrauncesFloorHolds() {
        XCTAssertEqual(BrandFonts.displayPointSize(for: 10), 17, "a size below the floor did not clamp")
        XCTAssertEqual(BrandFonts.displayPointSize(for: 16.9), 17, "a size just below the floor did not clamp")
        XCTAssertEqual(BrandFonts.displayPointSize(for: 17), 17, "the floor itself moved")
        XCTAssertEqual(BrandFonts.displayPointSize(for: 21), 21, "a size above the floor was clamped when it should not be")
        XCTAssertEqual(BrandFonts.displayPointSize(for: 24), 24, "the display size was clamped when it should not be")
    }

    /// The novelty skins must not pick up the brand faces, for the same reason
    /// they must not pick up pine.
    ///
    /// What this can actually see is the font PROVIDER, which distinguishes a
    /// bundled face from a system one but not a size or a weight. That is
    /// enough for the claim being made and the comparison is written against a
    /// brand font rather than a system one so the assertion says what it means.
    func testNoveltySkinsKeepTheSystemFace() {
        let brandBody = String(describing: BrandFonts.text(size: 13))
        for id in AppThemeID.allCases where id != .current {
            let t = AppTheme(id: id)
            XCTAssertNotEqual(String(describing: t.bodyFont), brandBody,
                              "\(id.rawValue) is using the brand text face")
            XCTAssertNotEqual(String(describing: t.displayFont),
                              String(describing: BrandFonts.display(size: 24)),
                              "\(id.rawValue) is using the brand display face")
        }
        // And the brand skin genuinely does use it, so the test above cannot
        // pass by everything being the system face.
        XCTAssertEqual(String(describing: AppTheme(id: .current).bodyFont), brandBody,
                       "the brand skin is NOT using the brand text face")
    }

    /// The AppKit focus ring follows the app's accent colour asset, not
    /// SwiftUI's `.tint`. Without the asset it stays the system blue, which
    /// would be the only blue in a pine-and-paper app.
    func testTheAppAccentColourAssetIsThePine() {
        guard let accent = NSColor(named: "AccentColor")?.usingColorSpace(.sRGB) else {
            XCTFail("no AccentColor asset, so the system focus ring is still blue")
            return
        }
        let got = (Double(accent.redComponent), Double(accent.greenComponent), Double(accent.blueComponent))
        let want = rgb(0x1E5C46)
        XCTAssertEqual(got.0, want.0, accuracy: 1.0 / 255.0, "accent red")
        XCTAssertEqual(got.1, want.1, accuracy: 1.0 / 255.0, "accent green")
        XCTAssertEqual(got.2, want.2, accuracy: 1.0 / 255.0, "accent blue")
    }

    // MARK: - 4. The Home hero, per docs/design/af-flow-home-hero.md

    /// **The soft plate is the contrast guarantee, so it is pinned as one.**
    ///
    /// The bound is the interesting part: compositing is monotone per channel,
    /// so ink at 0.84 over ANY sRGB video pixel is darker than ink at 0.84 over
    /// pure white. Measuring the white case therefore measures the worst case
    /// on every frame of any SDR encode, present or future, which a per-frame
    /// sample can never do.
    func testTheSoftPlateGuaranteesItsFloorOnEveryPossibleFrame() {
        let white = (1.0, 1.0, 1.0)
        let floor = over(components(Brand.textPrimary), white, HeroSurface.plateAlpha)

        XCTAssertEqual(hex(floor), 0x3C4441, "the plate floor moved off #3C4441")

        // The design document computes these in continuous float and reports
        // 8.92, 5.56, 7.18, 3.78 and 4.77. These are the same pairs QUANTISED
        // to 8 bits, which is the pixel that actually reaches the screen and
        // what a screenshot sampler reads back. The difference is in the third
        // decimal and never changes a verdict; the quantised figure is the one
        // the built app can be measured against.
        let pairs: [(String, Color, Double, Double)] = [
            ("paper on the plate", Brand.textOnDark, 4.5, 8.891),
            ("dark-muted on the plate", Brand.secondaryOnDark, 4.5, 5.542),
            ("mist on the plate", Brand.mist, 4.5, 7.159),
            ("clay dot on the plate", Brand.statusLiveOnDark, 3.0, 3.766),
            ("ochre dot on the plate", Brand.statusBusyOnDark, 3.0, 4.751)
        ]
        for (name, colour, minimum, expected) in pairs {
            let measured = contrast(components(colour), floor)
            XCTAssertGreaterThanOrEqual(measured, minimum, "\(name) measures \(measured), below \(minimum)")
            XCTAssertEqual(measured, expected, accuracy: 0.01, "\(name) drifted from the specified \(expected)")
        }
    }

    /// Clay is BANNED as body text on the fog, and this keeps the ban's reason
    /// alive. If it ever passes, the paper-plus-dot error treatment in
    /// `AFFlowHomeView` can be revisited deliberately rather than by accident.
    func testClayStillFailsAsBodyTextOnThePlateSoTheErrorRuleKeepsItsReason() {
        let floor = over(components(Brand.textPrimary), (1.0, 1.0, 1.0), HeroSurface.plateAlpha)
        XCTAssertLessThan(contrast(components(Brand.statusLiveOnDark), floor), 4.5,
                          "clay now passes as body text; the error treatment can change")
    }

    /// The footer sits on a flat band, not a gradient, so its contrast cannot
    /// depend on what the fog is doing.
    func testTheFooterBandCarriesTheFooter() {
        let band = over(components(Brand.textPrimary), (1.0, 1.0, 1.0), HeroSurface.footerBandAlpha)
        XCTAssertEqual(hex(band), 0x333B38, "the footer band moved off #333B38")
        // Quantised, as above; the document's float figures are 6.39, 10.25, 8.25.
        XCTAssertEqual(contrast(components(Brand.secondaryOnDark), band), 6.368, accuracy: 0.01, "eyebrows")
        XCTAssertEqual(contrast(components(Brand.textOnDark), band), 10.217, accuracy: 0.01, "values")
        XCTAssertEqual(contrast(components(Brand.mist), band), 8.227, accuracy: 0.01, "privacy value")
    }

    /// **The sidebar veil, at the density Andrew chose.**
    ///
    /// The worst case for dark text is the DARKEST fog under the veil, so the
    /// veil is composited over black. At his chosen 0.86 the row labels clear
    /// comfortably and the icons clear the non-text minimum, but MUTED TEXT
    /// FAILS at 3.50:1, which is exactly why the version line was moved to ink.
    /// The failing assertion below is deliberate: it keeps that move's reason.
    func testTheSidebarVeilKeepsItsRowsReadableAndExplainsTheVersionLine() {
        let black = (0.0, 0.0, 0.0)
        let surface = over(components(Brand.ground), black, HeroSurface.sidebarVeilAlpha)

        XCTAssertEqual(contrast(components(Brand.textPrimary), surface), 10.74, accuracy: 0.01,
                       "row labels and the version line, in ink")
        let muted = contrast(components(Brand.textSecondary), surface)
        XCTAssertGreaterThanOrEqual(muted, 3.0, "row icons must still clear the non-text minimum")
        XCTAssertLessThan(muted, 4.5,
                          "muted now passes on the veil, so the version line need not be ink any more")
    }

    /// The two shipped hero assets must actually be in the bundle. The fog is
    /// ambience and Home survives without it, so a miss would be silent.
    func testTheHeroAssetsAreInTheBundle() {
        XCTAssertNotNil(HeroFogAsset.videoURL, "the graded fog clip is not in the bundle")
        XCTAssertNotNil(HeroFogAsset.poster, "the graded poster is not in the bundle")
    }

    /// **Does the plate as BUILT actually reach its floor?**
    ///
    /// Every other contrast test here combines tokens and constants, which a
    /// reviewer correctly pointed out proves arithmetic rather than the shipped
    /// surface. This one renders the plate the way `AFFlowHomeView` builds it,
    /// a rounded rectangle at `plateAlpha` extended 36pt past the block and
    /// feathered with a blur, over PURE WHITE, and reads the pixels back.
    ///
    /// The specific risk it exists to catch: **a blur used as a feather also
    /// eats into the core.** If the shape were not large enough relative to the
    /// blur radius, the centre would land above `#3C4441` and every ratio in
    /// this file would quietly stop holding.
    @MainActor
    func testThePlateAsBuiltReachesItsFloorInTheMiddle() throws {
        let block = CGSize(width: 300, height: 120)
        // Mirrors `AFFlowHomeView` exactly: the plate is a BACKGROUND of the
        // block, so it takes the block's size and then extends past it.
        let plate = ZStack {
            Color.white
            Color.clear
                .frame(width: block.width, height: block.height)
                .background {
                    Color(hex: 0x17201D)
                        .opacity(HeroSurface.plateAlpha)
                        .mask {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .padding(-(HeroSurface.plateCoreInset + HeroSurface.plateFeather))
                                .blur(radius: HeroSurface.plateFeather / 3)
                        }
                        .padding(-(HeroSurface.plateCoreInset + HeroSurface.plateFeather))
                }
        }
        .frame(width: block.width + 420, height: block.height + 420)

        let renderer = ImageRenderer(content: plate)
        renderer.scale = 1
        guard let cg = renderer.cgImage else {
            throw XCTSkip("this environment cannot rasterise SwiftUI; the floor stays proven by arithmetic")
        }

        let w = cg.width, h = cg.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw XCTSkip("no sRGB colour space")
        }
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        // Sample the region a glyph can occupy: the block's own bounds, which
        // sit 36pt inside the shape's edge by construction.
        let insetX = (w - Int(block.width)) / 2, insetY = (h - Int(block.height)) / 2
        var brightest = 0.0
        for y in stride(from: insetY, to: insetY + Int(block.height), by: 4) {
            for x in stride(from: insetX, to: insetX + Int(block.width), by: 4) {
                let i = (y * w + x) * 4
                guard i + 2 < buffer.count else { continue }
                let px = (Double(buffer[i]) / 255, Double(buffer[i + 1]) / 255, Double(buffer[i + 2]) / 255)
                brightest = max(brightest, relativeLuminance(px))
            }
        }

        // The arithmetic floor, ink at plateAlpha over pure white.
        let floor = relativeLuminance(over(components(Brand.textPrimary), (1.0, 1.0, 1.0), HeroSurface.plateAlpha))
        // A little tolerance for rasteriser rounding, far below anything that
        // could move a ratio across its minimum.

        XCTAssertLessThanOrEqual(
            brightest, floor + 0.004,
            String(format: "the built plate is lighter than its floor: %.4f against %.4f", brightest, floor)
        )
        XCTAssertGreaterThan(brightest, 0, "nothing rendered, so this proved nothing")
    }

    /// **The shell must not paint over the hero.**
    ///
    /// The fog was invisible in the built app, and the cause was structural
    /// rather than a colour: `HSplitView` draws its own opaque system
    /// background, so everything behind it was hidden no matter what the
    /// backgrounds inside it were set to. It was also buying nothing, since the
    /// sidebar is pinned at min == max and the boundary hairline is drawn by
    /// hand.
    ///
    /// This renders both containers over a known colour and checks which one
    /// lets it through. If a future tidy-up puts a split view back, the fog
    /// disappears again and this goes red.
    @MainActor
    func testAnHStackLetsTheHeroThroughWhereASplitViewDoesNot() throws {
        func backdropVisible<V: View>(behind container: V) throws -> Bool {
            let probe = ZStack {
                Color(hex: 0xFF0000)
                container.frame(width: 200, height: 120)
            }
            .frame(width: 200, height: 120)
            let renderer = ImageRenderer(content: probe)
            renderer.scale = 1
            guard let cg = renderer.cgImage else {
                throw XCTSkip("this environment cannot rasterise SwiftUI")
            }
            let w = cg.width, h = cg.height
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw XCTSkip("no sRGB") }
            buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress,
                      let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            var red = 0
            for i in stride(from: 0, to: buffer.count, by: 4) where buffer[i] > 180 && buffer[i + 1] < 80 {
                red += 1
            }
            return red > (w * h) / 4
        }

        let throughStack = try backdropVisible(behind: HStack(spacing: 0) { Color.clear })
        XCTAssertTrue(throughStack, "an HStack of clear content must not hide what is behind it")

        let throughSplit = try backdropVisible(behind: HSplitView { Color.clear })
        XCTAssertFalse(
            throughSplit,
            "HSplitView no longer paints an opaque background; the shell could use it again, but check the fog first"
        )
    }

    private func hex(_ c: (Double, Double, Double)) -> UInt32 {
        (UInt32((c.0 * 255).rounded()) << 16) | (UInt32((c.1 * 255).rounded()) << 8) | UInt32((c.2 * 255).rounded())
    }

    /// The arithmetic itself is checked against two ratios the canon publishes
    /// independently, so a bug in the formula cannot silently pass everything.
    /// These two ARE literals on purpose: they are the calibration.
    func testTheContrastFormulaReproducesTheCanonsOwnPublishedRatios() {
        XCTAssertEqual(contrast(rgb(0xF5F1E8), rgb(0x1E5C46)), 6.97, accuracy: 0.01,
                       "the canon publishes 6.97:1 for text on pine")
        XCTAssertEqual(contrast(rgb(0xA7E8C6), rgb(0x17201D)), 11.90, accuracy: 0.01,
                       "the canon publishes 11.90:1 for mint on the dark hero")
    }
}
