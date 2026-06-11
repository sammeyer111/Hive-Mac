// Renders AppIcon.png (1024x1024) for Hive.app.
// Run: swift tools/make-icon.swift <output.png>
import AppKit

let canvas: CGFloat = 1024

func hexPath(center: CGPoint, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    for i in 0..<6 {
        let angle = CGFloat.pi / 180 * (60 * CGFloat(i) - 30)
        let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        if i == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS-style rounded square with a soft drop shadow.
let inset: CGFloat = 100
let square = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset),
    xRadius: 185, yRadius: 185)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 28
shadow.set()
color(0x1A1A24).setFill()
square.fill()
NSShadow().set()

square.setClip()
let background = NSGradient(starting: color(0x2C2C3A), ending: color(0x15151D))!
background.draw(in: square, angle: -90)

// Faint honeycomb lattice behind the main tile.
color(0xFFB300, 0.10).setStroke()
let latticeRadius: CGFloat = 120
for row in -2...6 {
    for col in -2...6 {
        let x = CGFloat(col) * latticeRadius * 1.732 + (row % 2 == 0 ? 0 : latticeRadius * 0.866)
        let y = CGFloat(row) * latticeRadius * 1.5
        let lattice = hexPath(center: CGPoint(x: x, y: y), radius: latticeRadius * 0.96)
        lattice.lineWidth = 6
        lattice.stroke()
    }
}

// Back tile (charcoal, like a black piece) peeking out behind.
let backHex = hexPath(center: CGPoint(x: 622, y: 430), radius: 300)
color(0x3A3A45).setFill()
backHex.fill()
color(0x15151B).setStroke()
backHex.lineWidth = 14
backHex.stroke()

// Main tile: honey gradient hex, like a white piece warmed up.
let mainCenter = CGPoint(x: 462, y: 542)
let mainHex = hexPath(center: mainCenter, radius: 340)
let honey = NSGradient(starting: color(0xFFC93D), ending: color(0xE89400))!
honey.draw(in: mainHex, angle: -75)
color(0xB87400).setStroke()
mainHex.lineWidth = 16
mainHex.stroke()

// The bee.
let bee = NSAttributedString(
    string: "🐝",
    attributes: [.font: NSFont(name: "Apple Color Emoji", size: 400) ?? NSFont.systemFont(ofSize: 400)])
let beeSize = bee.size()
bee.draw(at: NSPoint(x: mainCenter.x - beeSize.width / 2, y: mainCenter.y - beeSize.height / 2))

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
