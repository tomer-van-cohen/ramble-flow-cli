// Renders the Ramble logo (geometry of the approved 1024 pt app-icon master) into a macOS
// .iconset using CoreGraphics only. Usage: swift scripts/make-icon.swift <output.iconset>
// The Ramble logo is NOT covered by this repository's MIT license; see THIRD_PARTY_NOTICES.md.
import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(pixels) / 1024
    // SVG coordinates have y down; flip.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: s, y: -s)
    // Body: 824 on a 1024 canvas, corner radius 184, vertical gradient #2EDC6E → #1FC45C.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 184, cornerHeight: 184, transform: nil)
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x2EDC6E), color(0x1FC45C)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    ctx.restoreGState()
    // Wave: M212 512 q58-290 116 0 q58 250 116 0 q45-170 90 0 q45 100 90 0 h188
    let wave = CGMutablePath()
    var p = CGPoint(x: 212, y: 512)
    wave.move(to: p)
    for (cx, cy, ex, ey) in [(58.0, -290.0, 116.0, 0.0), (58, 250, 116, 0), (45, -170, 90, 0), (45, 100, 90, 0)] {
        wave.addQuadCurve(to: CGPoint(x: p.x + ex, y: p.y + ey), control: CGPoint(x: p.x + cx, y: p.y + cy))
        p = CGPoint(x: p.x + ex, y: p.y + ey)
    }
    wave.addLine(to: CGPoint(x: p.x + 188, y: p.y))
    ctx.addPath(wave)
    ctx.setStrokeColor(color(0x121212))
    ctx.setLineWidth(66)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(pixels: base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
