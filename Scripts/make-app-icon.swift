// Generates Isotope's app icon with CoreGraphics — no design assets, no deps.
// Flat motif: a rounded-square field with an optical disc and a download badge.
//
//   swift Scripts/make-app-icon.swift /tmp/Isotope.iconset
//   iconutil -c icns /tmp/Isotope.iconset -o Isotope/Resources/AppIcon.icns
//
// The checked-in .icns is the build product of exactly those two commands.
import AppKit
import CoreGraphics
import Foundation

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Draws the icon into `ctx` for a canvas of `size` points (square).
func draw(_ ctx: CGContext, size s: CGFloat) {
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS icon grid: the art occupies ~82% of the canvas with a square margin.
    let inset = s * 0.09
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = plate.width * 0.2237   // matches the macOS squircle closely enough

    // Field: deep indigo → violet, top-light like every other macOS icon.
    ctx.saveGState()
    ctx.addPath(roundedRect(plate, radius: radius))
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let field = CGGradient(colorsSpace: space,
                           colors: [hex(0x5B6CF0), hex(0x2E2A8F)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(field, start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.minY), options: [])
    ctx.restoreGState()

    let c = CGPoint(x: plate.midX, y: plate.midY)
    let discR = plate.width * 0.315

    // Disc body: a bright ring, flat, with one lighter quadrant for a hint of
    // the iridescence a real disc has (no gloss, no bevel).
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2))
    ctx.clip()
    let disc = CGGradient(colorsSpace: space,
                          colors: [hex(0xFFFFFF), hex(0xC9D6FF)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(disc, start: CGPoint(x: c.x - discR, y: c.y + discR),
                           end: CGPoint(x: c.x + discR, y: c.y - discR), options: [])
    ctx.restoreGState()

    // Inner ring: the data-area edge.
    ctx.setStrokeColor(hex(0x2E2A8F, 0.20))
    ctx.setLineWidth(max(1, s * 0.012))
    let ringR = discR * 0.52
    ctx.strokeEllipse(in: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))

    // Hub hole, punched through to the field colour.
    let holeR = discR * 0.235
    ctx.setFillColor(hex(0x2E2A8F))
    ctx.fillEllipse(in: CGRect(x: c.x - holeR, y: c.y - holeR, width: holeR * 2, height: holeR * 2))

    // Update mark: a downward arrow in the disc's lower-right, the one cue that
    // says this app *fetches* images rather than burns them.
    let badgeR = plate.width * 0.145
    let bc = CGPoint(x: c.x + discR * 0.80, y: c.y - discR * 0.80)
    ctx.setFillColor(hex(0x2E2A8F))
    ctx.fillEllipse(in: CGRect(x: bc.x - badgeR * 1.16, y: bc.y - badgeR * 1.16,
                               width: badgeR * 2.32, height: badgeR * 2.32))
    ctx.setFillColor(hex(0x4ADE80))
    ctx.fillEllipse(in: CGRect(x: bc.x - badgeR, y: bc.y - badgeR,
                               width: badgeR * 2, height: badgeR * 2))
    let shaft = badgeR * 0.20
    let arrow = CGMutablePath()
    arrow.addRect(CGRect(x: bc.x - shaft / 2, y: bc.y - badgeR * 0.10,
                         width: shaft, height: badgeR * 0.62))
    arrow.move(to: CGPoint(x: bc.x - badgeR * 0.40, y: bc.y - badgeR * 0.08))
    arrow.addLine(to: CGPoint(x: bc.x + badgeR * 0.40, y: bc.y - badgeR * 0.08))
    arrow.addLine(to: CGPoint(x: bc.x, y: bc.y - badgeR * 0.60))
    arrow.closeSubpath()
    ctx.setFillColor(hex(0x0B2E18))
    ctx.addPath(arrow)
    ctx.fillPath()
}

func writePNG(pixels: Int, to url: URL) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "icon", code: 1)
    }
    draw(ctx, size: CGFloat(pixels))
    guard let image = ctx.makeImage() else { throw NSError(domain: "icon", code: 2) }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 3)
    }
    try data.write(to: url)
}

// The exact set `iconutil` expects in an .iconset.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    try writePNG(pixels: variant.pixels, to: outDir.appendingPathComponent("\(variant.name).png"))
}
print("wrote \(variants.count) PNGs to \(outDir.path)")
