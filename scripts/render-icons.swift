import AppKit
import Foundation

// Renders AF Flow's icons from Andrew's own brand mark, taken verbatim from
// the favicon on andrew-frolikov.netlify.app:
//
//   <rect width="64" height="64" rx="14" fill="#16161A"/>
//   <text x="13.5" y="43.5" font-family="Georgia,serif" font-weight="600"
//         font-size="31" letter-spacing="-1.5" fill="#FAF8F5">AF</text>
//   <circle cx="52" cy="40.5" r="3.4" fill="#8F5F44"/>
//
// Every geometric value below is that SVG's, expressed as a fraction of the
// 64pt viewBox, so the mark scales exactly rather than approximately. No
// SVG rasteriser is installed on this machine, so this draws it with Core
// Graphics instead of guessing at an approximation.

let ink = NSColor(srgbRed: 0x16 / 255.0, green: 0x16 / 255.0, blue: 0x1A / 255.0, alpha: 1)
let paper = NSColor(srgbRed: 0xFA / 255.0, green: 0xF8 / 255.0, blue: 0xF5 / 255.0, alpha: 1)
let terracotta = NSColor(srgbRed: 0x8F / 255.0, green: 0x5F / 255.0, blue: 0x44 / 255.0, alpha: 1)

// Draws into an explicitly sized bitmap rather than using NSImage.lockFocus.
// lockFocus adopts the display's backing scale, so on this Retina Mac every
// icon came out at exactly double the requested pixel dimensions. An app icon
// that is 2048px in a slot declared as 1024px is a defect the asset catalogue
// will not warn about.
func draw(size: CGFloat, background: NSColor?, glyph: NSColor, dot: NSColor?, inset: CGFloat = 0) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.imageInterpolation = .high
    let unit = size / 64.0

    if let background {
        background.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                     xRadius: 14 * unit, yRadius: 14 * unit).fill()
    }

    // Georgia at the mark's own weight and tracking. Falling back to the
    // system serif rather than silently substituting a sans face, which would
    // stop it being his mark.
    // 0.92 of the SVG's declared size. In the browser, font-weight 600 with
    // Georgia renders slightly narrower than AppKit's Georgia-Bold, so drawing
    // at the literal 31 made the glyph run into the dot. His own icon keeps
    // clear space there: the text must end before the dot's left edge at
    // x=48.6 (centre 52 minus radius 3.4), which caps the glyph at 35.1 units.
    let pointSize = (31 * unit) * 0.92 * (1 - inset)
    let font = NSFont(name: "Georgia-Bold", size: pointSize)
        ?? NSFont(name: "Georgia", size: pointSize)
        ?? NSFont.systemFont(ofSize: pointSize, weight: .semibold)

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: glyph,
        .kern: -1.5 * unit,
    ]
    let text = NSAttributedString(string: "AF", attributes: attributes)

    // The SVG places the text baseline at y=43.5 from the TOP; AppKit's origin
    // is bottom-left, so the baseline sits at (64 - 43.5) from the bottom.
    let bounds = text.boundingRect(with: .zero, options: [])
    let baselineFromBottom = (64 - 43.5) * unit
    let descender = abs(font.descender)
    var origin = NSPoint(x: 13.5 * unit, y: baselineFromBottom - descender)

    if inset > 0 {
        // Centre the glyph when there is no background plate to sit inside.
        origin.x = (size - bounds.width) / 2
        origin.y = (size - bounds.height) / 2 + descender * 0.35
    }
    text.draw(at: origin)

    if let dot {
        dot.setFill()
        let radius = 3.4 * unit
        NSBezierPath(ovalIn: NSRect(x: (52 - 3.4) * unit,
                                    y: (64 - 40.5 - 3.4) * unit,
                                    width: radius * 2,
                                    height: radius * 2)).fill()
    }

    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to encode \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else { exit(2) }
let outputDirectory = arguments[1]

// App icon: the full mark, exactly as it appears on his site.
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = draw(size: CGFloat(size), background: ink, glyph: paper, dot: terracotta)
    write(image, to: "\(outputDirectory)/app-icon-\(size).png")
}

// Menu bar: no background plate, because a filled square in the menu bar reads
// as a foreign object next to Apple's own glyphs. The AF glyph alone carries
// the identity at 18pt, and the dot carries the STATE, which is what his mark
// already had a dot for.
//
// Idle is drawn in solid black and rendered as a TEMPLATE, so macOS recolours
// it for light and dark menu bars automatically. The active states are drawn
// in their own colour because a template cannot express "recording".
let menuStates: [(String, NSColor, NSColor?)] = [
    ("menubar-icon", .black, .black),
    ("menubar-icon-red", NSColor(srgbRed: 0.78, green: 0.22, blue: 0.18, alpha: 1),
     NSColor(srgbRed: 0.78, green: 0.22, blue: 0.18, alpha: 1)),
    ("menubar-icon-red-dim", NSColor(srgbRed: 0.78, green: 0.22, blue: 0.18, alpha: 0.55),
     NSColor(srgbRed: 0.78, green: 0.22, blue: 0.18, alpha: 0.55)),
    ("menubar-icon-orange", terracotta, terracotta),
]

for (name, glyph, dot) in menuStates {
    for (suffix, scale) in [("", 1), ("@2x", 2), ("@3x", 3)] {
        let size = CGFloat(18 * scale)
        let image = draw(size: size, background: nil, glyph: glyph, dot: dot, inset: 0.18)
        write(image, to: "\(outputDirectory)/\(name)\(suffix).png")
    }
}
