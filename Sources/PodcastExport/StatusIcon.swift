import AppKit

/// The menu bar icon: three episodes in a list, each with a ring showing how much was played.
enum StatusIcon {
    static func image(alert: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            NSColor.black.set()
            let shift: CGFloat = alert ? -1.5 : 0
            // Played, half played, and not started yet.
            for (index, played) in [1.0, 0.5, 0.0].enumerated() {
                let y = rect.midY + 4.6 - CGFloat(index) * 4.6
                let ring = NSRect(x: 2.4 + shift, y: y - 1.8, width: 3.6, height: 3.6)
                let outline = NSBezierPath(ovalIn: ring)
                outline.lineWidth = 1
                outline.stroke()
                if played > 0 {
                    let center = NSPoint(x: ring.midX, y: ring.midY)
                    let wedge = NSBezierPath()
                    wedge.move(to: center)
                    wedge.appendArc(withCenter: center, radius: 1.8, startAngle: 90, endAngle: 90 - 360 * played, clockwise: true)
                    wedge.close()
                    wedge.fill()
                }
                NSBezierPath(roundedRect: NSRect(x: 8 + shift, y: y - 0.8, width: index == 1 ? 6.5 : 9, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
            }
            if alert {
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5.5, y: rect.maxY - 6, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = alert ? "Podcast Export, needs attention" : "Podcast Export"
        return image
    }
}
