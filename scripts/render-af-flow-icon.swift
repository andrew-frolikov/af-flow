// AF Flow macOS app icon, CLASSIC variant.
//
// The design document's section 8 chose a full-bleed square on the grounds
// that this macOS generation masks icons into its own squircle. Measured on
// macOS 26.5.2 that is false: Notes, Mail and Calculator all ship artwork with
// fully transparent corners, so the system expects PRE-ROUNDED art. The
// document already recorded this variant for exactly that case.
//
// Plate 824 centred on a transparent 1024 canvas, corner radius 180 (the
// canon's rx=14 in a 64 box, scaled), construction scaled by 12.875.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let brand = ProcessInfo.processInfo.environment["AF_FLOW_BRAND_DIR"] ?? "brand"
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AFFlow/Assets.xcassets/AppIcon.appiconset"
let cgFont = CGFont(CGDataProvider(url: URL(fileURLWithPath: "\(brand)/Fraunces-opsz9-wght500.ttf") as CFURL)!)!

func render(canvas: Int, report: Bool) -> CGImage {
    let s = CGFloat(canvas)
    let plate = s * 824.0 / 1024.0
    let inset = (s - plate) / 2
    let radius = plate * 14.0 / 64.0
    let f = plate / 64.0
    let ctFont = CTFontCreateWithGraphicsFont(cgFont, 26.96 * f, nil, nil)
    let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    let plateRect = CGRect(x: inset, y: inset, width: plate, height: plate)
    let path = CGPath(roundedRect: plateRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(CGColor(srgbRed: 0x16/255.0, green: 0x16/255.0, blue: 0x1A/255.0, alpha: 1))
    ctx.fillPath()

    var g = [CGGlyph](repeating: 0, count: 2); var c: [UniChar] = [0x41, 0x46]
    CTFontGetGlyphsForCharacters(ctFont, &c, &g, 2)
    let baseline = inset + plate - 41.7 * f
    var pos = [CGPoint(x: inset + 12.582 * f, y: baseline), CGPoint(x: inset + 31.117 * f, y: baseline)]
    ctx.setFillColor(CGColor(srgbRed: 0xFA/255.0, green: 0xF8/255.0, blue: 0xF5/255.0, alpha: 1))
    CTFontDrawGlyphs(ctFont, g, &pos, 2, ctx)

    ctx.setFillColor(CGColor(srgbRed: 0x1E/255.0, green: 0x5C/255.0, blue: 0x46/255.0, alpha: 1))
    let dr = 3.4 * f, dcx = inset + 52.0 * f, dcy = inset + plate - 38.7 * f
    ctx.fillEllipse(in: CGRect(x: dcx - dr, y: dcy - dr, width: dr * 2, height: dr * 2))

    if report {
        var rects = [CGRect](repeating: .zero, count: 2)
        _ = CTFontGetBoundingRectsForGlyphs(ctFont, .default, g, &rects, 2)
        let x0 = pos[0].x + rects[0].minX, x1 = pos[1].x + rects[1].maxX
        // Canon rule 2: compute and print the fit rather than trusting it.
        print(String(format: "  plate %.0f on %d canvas, corner radius %.0f", plate, canvas, radius))
        print(String(format: "  glyph ink span %.1f to %.1f, in 64-unit terms %.2f to %.2f (canon 13.0 to 46.8)",
                     x0, x1, (x0 - inset) / f, (x1 - inset) / f))
        print(String(format: "  clearance to dot %.2f units (canon 1.8)", ((dcx - dr) - x1) / f))
    }
    return ctx.makeImage()!
}

for size in [1024, 512, 256, 128, 64, 32, 16] {
    let img = render(canvas: size, report: size == 1024)
    let url = URL(fileURLWithPath: "\(outDir)/app-icon-\(size).png")
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}
print("  written 7 sizes")
