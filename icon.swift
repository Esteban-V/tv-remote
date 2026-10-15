// Draws the app icon. Run: swift icon.swift && iconutil -c icns AppIcon.iconset
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Background tile on Apple's macOS icon grid (824pt body, 100pt margin).
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                            xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(red: 0.18, green: 0.45, blue: 1, alpha: 1),
               ending: NSColor(red: 0.30, green: 0.16, blue: 0.75, alpha: 1))!.draw(in: tile, angle: -90)

    // Remote body.
    let body = NSRect(x: 362 * s, y: 170 * s, width: 300 * s, height: 684 * s)
    NSColor(white: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: body, xRadius: 150 * s, yRadius: 150 * s).fill()

    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)).fill()
    }
    circle(512, 760, 30, NSColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)) // power
    circle(512, 590, 105, NSColor(white: 0.28, alpha: 1))                    // d-pad ring
    circle(512, 590, 48, .white)                                             // OK
    for (x, y) in [(445.0, 420.0), (579.0, 420.0), (445.0, 320.0), (579.0, 320.0)] {
        circle(x, y, 32, NSColor(white: 0.4, alpha: 1))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try! draw(CGFloat(pt * scale)).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
}
