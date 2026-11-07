// Draws the app icon: "Scr" over a large, cropped Georgia α on a dark red tile.
// Usage: swift scripts/make-icon.swift Sources/CameraRemoteApp/Resources/AppIcon.png
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let size = 1024
let bgTop = NSColor(srgbRed: 0.27, green: 0.05, blue: 0.06, alpha: 1)
let bgBottom = NSColor(srgbRed: 0.18, green: 0.03, blue: 0.04, alpha: 1)
let foreground = NSColor(srgbRed: 1.0, green: 0.48, blue: 0.44, alpha: 1)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: an 824 pt tile centred on the 1024 pt canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 20
shadow.set()
bgBottom.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: bgTop, ending: bgBottom)!.draw(in: path, angle: -90)

// Background α, offset to the bottom right and cropped by the tile.
NSGraphicsContext.saveGraphicsState()
path.addClip()
let alphaFont = NSFont(name: "Georgia-BoldItalic", size: 1150)!
let alpha = NSAttributedString(
    string: "α", attributes: [.font: alphaFont, .foregroundColor: foreground.withAlphaComponent(0.11)])
let alphaSize = alpha.size()
alpha.draw(
    at: NSPoint(
        x: tile.midX + 200 - alphaSize.width / 2,
        y: tile.midY - 170 - alphaSize.height / 2 + alphaFont.descender.magnitude * 0.3))
NSGraphicsContext.restoreGraphicsState()

// "Scr", optically centred on its cap height.
let textFont = NSFont(name: "AvenirNext-Bold", size: 330)!
let text = NSAttributedString(
    string: "Scr", attributes: [.font: textFont, .foregroundColor: foreground, .kern: -6])
let textSize = text.size()
text.draw(
    at: NSPoint(
        x: tile.midX - textSize.width / 2,
        y: tile.midY - textFont.descender.magnitude - textFont.capHeight / 2))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
