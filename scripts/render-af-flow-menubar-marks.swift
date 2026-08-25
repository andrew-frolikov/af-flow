// The menu bar marks: the Fraunces AF monogram with a status dot.
//
// Four states, a deliberate decision recorded in AFFlowApp.swift: the mark
// stays his at exactly the moments he is most likely to be looking at it, which
// is why stock SF symbols were removed. This renderer keeps that structure and
// puts the colours on the brand.
//
// Each coloured state ships a LIGHT and a DARK rendition, because the glyph
// colour cannot adapt under `template-rendering-intent: original`. The previous
// assets were white-only, so they were invisible on a light menu bar. The idle
// state stays a true template and lets macOS do the work.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let brand = "/Users/andriifrolikov/Claude/Projects/personal-website/brand"
let outRoot = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AFFlow/Assets.xcassets"
let cgFont = CGFont(CGDataProvider(url: URL(fileURLWithPath: "\(brand)/Fraunces-opsz9-wght500.ttf") as CFURL)!)!

// Canon geometry, 64-unit box: glyph ink 13.0 to 46.8, dot at cx 52 r 3.4.
// The mark without its plate spans 13.0 to 55.4 horizontally.
let markLeft: CGFloat = 13.0, markRight: CGFloat = 55.4

struct Rendition { let name: String; let glyph: CGColor; let dot: CGColor }
func srgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF)/255, green: CGFloat((hex >> 8) & 0xFF)/255,
            blue: CGFloat(hex & 0xFF)/255, alpha: 1)
}

/// Measured at a reference size once, so the fit is solved by arithmetic
/// rather than by a fudge factor. Canon rule 2.
let reference: CGFloat = 26.96
let refFont = CTFontCreateWithGraphicsFont(cgFont, reference, nil, nil)
var refGlyphs = [CGGlyph](repeating: 0, count: 2)
var refChars: [UniChar] = [0x41, 0x46]
CTFontGetGlyphsForCharacters(refFont, &refChars, &refGlyphs, 2)
var refRects = [CGRect](repeating: .zero, count: 2)
_ = CTFontGetBoundingRectsForGlyphs(refFont, .default, refGlyphs, &refRects, 2)

// In 64-unit terms at the reference size: where the ink actually starts, and
// where the dot's right edge lands.
let inkStartUnits = 12.582 + refRects[0].minX
let inkEndUnits: CGFloat = 52.0 + 3.4
let inkWidthUnits = inkEndUnits - inkStartUnits
let inkTopUnits = max(refRects[0].maxY, refRects[1].maxY)
let inkBottomUnits = min(refRects[0].minY, refRects[1].minY, 3.0 - 3.4)
let inkHeightUnits = inkTopUnits - inkBottomUnits

func render(px: Int, glyph: CGColor, dot: CGColor, report: Bool) -> CGImage {
    let W = CGFloat(px)
    let margin = W * 0.03
    // Fit the WIDER of the two axes so nothing is ever clipped.
    let f = min((W - 2 * margin) / inkWidthUnits, (W - 2 * margin) / inkHeightUnits)
    let ctFont = CTFontCreateWithGraphicsFont(cgFont, reference * f, nil, nil)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: W, height: W))

    var g = [CGGlyph](repeating: 0, count: 2); var c: [UniChar] = [0x41, 0x46]
    CTFontGetGlyphsForCharacters(ctFont, &c, &g, 2)

    // Centre the measured ink box in the canvas.
    let originX = (W - inkWidthUnits * f) / 2 - inkStartUnits * f
    let baselineY = (W - inkHeightUnits * f) / 2 - inkBottomUnits * f

    var pos = [CGPoint(x: originX + 12.582 * f, y: baselineY),
               CGPoint(x: originX + 31.117 * f, y: baselineY)]
    ctx.setFillColor(glyph)
    CTFontDrawGlyphs(ctFont, g, &pos, 2, ctx)

    ctx.setFillColor(dot)
    let dr = 3.4 * f
    let dcx = originX + 52.0 * f
    let dcy = baselineY + 3.0 * f
    ctx.fillEllipse(in: CGRect(x: dcx - dr, y: dcy - dr, width: dr * 2, height: dr * 2))

    if report {
        let x0 = originX + inkStartUnits * f, x1 = dcx + dr
        let y0 = baselineY + inkBottomUnits * f, y1 = baselineY + inkTopUnits * f
        print(String(format: "    ink x %.2f to %.2f, y %.2f to %.2f, on a %.0f canvas (margins %.2f / %.2f)",
                     x0, x1, y0, y1, W, x0, W - x1))
    }
    return ctx.makeImage()!
}

func write(_ img: CGImage, _ path: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                            UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}

let ink = srgb(0x17201D), paper = srgb(0xF5F1E8), black = srgb(0x000000)
let clay = srgb(0x9E3B24), ochre = srgb(0x7A5414)

// Idle: a true template. macOS inverts it for light and dark menu bars and
// handles the pressed state, so it needs no rendition of its own.
for (i, px) in [18, 36, 54].enumerated() {
    let suffix = i == 0 ? "" : "@\(i + 1)x"
    print("  MenuBarIcon\(suffix)"); 
    write(render(px: px, glyph: black, dot: black, report: i == 2),
          "\(outRoot)/MenuBarIcon.imageset/menubar-icon\(suffix).png")
}

// Status states: colour is the point, so they cannot be templates. Each ships
// a light-menu-bar and a dark-menu-bar rendition.
let states: [(set: String, file: String, dot: CGColor)] = [
    ("MenuBarIconRed", "menubar-icon-red", clay),        // recording
    ("MenuBarIconOrange", "menubar-icon-orange", ochre), // loading, transcribing, cleaning up
    ("MenuBarIconRedDim", "menubar-icon-red-dim", clay)  // error
]
for s in states {
    for (i, px) in [18, 36, 54].enumerated() {
        let suffix = i == 0 ? "" : "@\(i + 1)x"
        write(render(px: px, glyph: ink, dot: s.dot, report: false),
              "\(outRoot)/\(s.set).imageset/\(s.file)\(suffix).png")
        write(render(px: px, glyph: paper, dot: s.dot, report: false),
              "\(outRoot)/\(s.set).imageset/\(s.file)-dark\(suffix).png")
    }
    print("  \(s.set): light and dark renditions, 3 scales each")
}
print("  done")
