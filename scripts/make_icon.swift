// Renders Munshi's app icon (1024px PNG): dusk squircle + glowing smiling face.
// Usage: swift scripts/make_icon.swift out.png
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor]) -> CGGradient { CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)! }

// Squircle background (macOS icon grid: 824px body centred, ~185px radius)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(squircle); ctx.setFillColor(rgb(0x141A2E)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x1E3437), rgb(0x1B2B3A), rgb(0x141A2E)]), start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// soft aurora blobs
ctx.drawRadialGradient(gradient([rgb(0x7A6FB0, 0.45), rgb(0x7A6FB0, 0)]), startCenter: CGPoint(x: 300, y: 250), startRadius: 0, endCenter: CGPoint(x: 300, y: 250), endRadius: 420, options: [])
ctx.drawRadialGradient(gradient([rgb(0xF4A987, 0.35), rgb(0xF4A987, 0)]), startCenter: CGPoint(x: 700, y: 760), startRadius: 0, endCenter: CGPoint(x: 700, y: 760), endRadius: 380, options: [])
// halo
let c = CGPoint(x: 512, y: 500), r: CGFloat = 250
ctx.drawRadialGradient(gradient([rgb(0xFFD3A5, 0.5), rgb(0xFFD3A5, 0)]), startCenter: c, startRadius: r * 0.8, endCenter: c, endRadius: r * 1.55, options: [])
ctx.restoreGState()

// Head
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFFD9AE), rgb(0xF4A987), rgb(0xE88AA6)]), start: CGPoint(x: c.x - r, y: c.y + r), end: CGPoint(x: c.x + r, y: c.y - r), options: [])
ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.45), rgb(0xFFFFFF, 0)]), startCenter: CGPoint(x: c.x - 90, y: c.y + 110), startRadius: 0, endCenter: CGPoint(x: c.x - 90, y: c.y + 110), endRadius: 230, options: [])
ctx.restoreGState()

let ink = rgb(0x2B2640, 0.9)
// Blush
for dx in [-150.0, 150.0] as [CGFloat] {
    ctx.drawRadialGradient(gradient([rgb(0xFF8FA3, 0.55), rgb(0xFF8FA3, 0)]), startCenter: CGPoint(x: c.x + dx, y: c.y - 40), startRadius: 0, endCenter: CGPoint(x: c.x + dx, y: c.y - 40), endRadius: 55, options: [])
}
// Happy crescent eyes
ctx.setStrokeColor(ink); ctx.setLineWidth(26); ctx.setLineCap(.round)
for dx in [-85.0, 85.0] as [CGFloat] {
    let ex = c.x + dx, ey = c.y + 45
    ctx.move(to: CGPoint(x: ex - 38, y: ey - 8))
    ctx.addQuadCurve(to: CGPoint(x: ex + 38, y: ey - 8), control: CGPoint(x: ex, y: ey + 48))
    ctx.strokePath()
}
// Smile
ctx.setLineWidth(24)
ctx.move(to: CGPoint(x: c.x - 70, y: c.y - 70))
ctx.addQuadCurve(to: CGPoint(x: c.x + 70, y: c.y - 70), control: CGPoint(x: c.x, y: c.y - 140))
ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
