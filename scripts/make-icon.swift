// Draws the app icon and writes it to Resources/AppIcon.icns, plus docs/icon.png for the website.
//
//   swift scripts/make-icon.swift
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

/// Draws the icon on a 1024-point canvas, scaled to `pixels`.
func icon(pixels: Int) -> NSBitmapImageRep {
    let image = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()

    let slate = NSColor(srgbRed: 0.13, green: 0.17, blue: 0.27, alpha: 1)
    let ice = NSColor(srgbRed: 0.62, green: 0.82, blue: 1.0, alpha: 1)

    // The rounded tile, with the soft shadow macOS icons sit on. Same tile and light as Show Desktop.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = .black.withAlphaComponent(0.3)
    tileShadow.shadowBlurRadius = 24
    tileShadow.shadowOffset = NSSize(width: 0, height: -12)
    tileShadow.set()
    slate.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(srgbRed: 0.80, green: 0.87, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.57, blue: 0.75, alpha: 1),
        slate,
    ])!.draw(in: tile, angle: -90)

    /// A rounded bar, with a soft shadow, or glowing in `color` when it's the newest part.
    func bar(_ rect: NSRect, color: NSColor, glow: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        if glow {
            shadow.shadowColor = color.withAlphaComponent(0.75)
            shadow.shadowBlurRadius = 34
        } else {
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -6)
        }
        shadow.set()
        color.setFill()
        let radius = min(rect.width, rect.height) / 2
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A ring showing how much of an episode was played, filled clockwise from the top.
    func ring(center: NSPoint, played: CGFloat, color: NSColor, glow: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        if glow {
            shadow.shadowColor = color.withAlphaComponent(0.75)
            shadow.shadowBlurRadius = 34
        } else {
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -6)
        }
        shadow.set()
        color.setStroke()
        color.setFill()
        let outline = NSBezierPath(ovalIn: NSRect(x: center.x - 50, y: center.y - 50, width: 100, height: 100))
        outline.lineWidth = 16
        outline.stroke()
        if played > 0 {
            let wedge = NSBezierPath()
            wedge.move(to: center)
            wedge.appendArc(withCenter: center, radius: 32, startAngle: 90, endAngle: 90 - 360 * played, clockwise: true)
            wedge.close()
            wedge.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // Three episodes in a list, each with a ring for how much of it was played and a line for its
    // title. The last one, the play still going, glows in ice blue against the slate.
    let rows: [(y: CGFloat, played: CGFloat, width: CGFloat)] = [(652, 1, 300), (512, 1, 236), (372, 0.62, 278)]
    for (index, row) in rows.enumerated() {
        let latest = index == rows.count - 1
        let color = latest ? ice : .white
        ring(center: NSPoint(x: 338, y: row.y), played: row.played, color: color, glow: latest)
        bar(NSRect(x: 436, y: row.y - 22, width: row.width, height: 44), color: color, glow: latest)
    }

    NSGraphicsContext.restoreGraphicsState()
    return image
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = icon(pixels: points * scale).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try icon(pixels: 256).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", iconset.path, "--output", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
Swift.print("Wrote \(output) and docs/icon.png")
