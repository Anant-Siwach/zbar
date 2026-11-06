// Renders Resources/AppIcon.icns: a gradient tile with a menu bar strip and a fold-away chevron.
import AppKit
let out = CommandLine.arguments[1]
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tile = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.42, blue: 1, alpha: 1), NSColor(red: 0.13, green: 0.83, blue: 0.93, alpha: 1)])!
        .draw(in: tile, angle: -60)
    // menu bar strip
    let bar = NSRect(x: r.minX + r.width * 0.12, y: r.maxY - r.height * 0.36, width: r.width * 0.76, height: r.height * 0.16)
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
    // icons on the bar
    let dot = bar.height * 0.42
    NSColor(red: 0.3, green: 0.4, blue: 0.95, alpha: 1).setFill()
    for i in 0..<3 {
        let x = bar.maxX - bar.height * 0.6 - CGFloat(i) * dot * 1.9 - dot
        NSBezierPath(ovalIn: NSRect(x: x, y: bar.midY - dot / 2, width: dot, height: dot)).fill()
    }
    // chevron folding hidden items away
    let c = NSBezierPath()
    let cx = bar.minX + bar.width * 0.3, cy = bar.midY, ch = bar.height * 0.28
    c.move(to: NSPoint(x: cx + ch * 0.6, y: cy + ch)); c.line(to: NSPoint(x: cx, y: cy)); c.line(to: NSPoint(x: cx + ch * 0.6, y: cy - ch))
    c.lineWidth = bar.height * 0.13; c.lineCapStyle = .round; c.lineJoinStyle = .round
    NSColor(red: 0.3, green: 0.4, blue: 0.95, alpha: 1).setStroke(); c.stroke()
    // ghosted hidden items below
    NSColor.white.withAlphaComponent(0.35).setFill()
    for i in 0..<3 {
        let w = r.width * 0.17, h = r.height * 0.17
        let x = r.minX + r.width * 0.16 + CGFloat(i) * w * 1.35, y = r.minY + r.height * 0.18
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: w * 0.28, yRadius: w * 0.28).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base)@2x.png"))
}
