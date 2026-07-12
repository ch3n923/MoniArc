import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("MoniArc/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let sizes = [16, 32, 64, 128, 256, 512, 1024]

func render(size: Int) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "MoniArcIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = CGFloat(size) / 1024
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    let background = NSBezierPath(roundedRect: canvas.insetBy(dx: 42 * scale, dy: 42 * scale),
                                  xRadius: 220 * scale, yRadius: 220 * scale)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.018, green: 0.035, blue: 0.09, alpha: 1),
        NSColor(calibratedRed: 0.03, green: 0.075, blue: 0.18, alpha: 1)
    ])!.draw(in: background, angle: -55)

    let center = NSPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
    let radius = 322 * scale
    func arc(start: CGFloat, end: CGFloat, width: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end)
        path.lineWidth = max(1, width * scale)
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedRed: 0.08, green: 0.55, blue: 1, alpha: 0.55)
    shadow.shadowBlurRadius = 25 * scale
    shadow.set()
    arc(start: 67, end: 394, width: 9, color: NSColor(calibratedRed: 0.18, green: 0.48, blue: 1, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()

    arc(start: 67, end: 394, width: 8, color: NSColor(calibratedRed: 0.23, green: 0.59, blue: 1, alpha: 1))

    NSGraphicsContext.saveGraphicsState()
    let signalShadow = NSShadow()
    signalShadow.shadowColor = NSColor(calibratedRed: 0.12, green: 0.92, blue: 1, alpha: 0.9)
    signalShadow.shadowBlurRadius = 34 * scale
    signalShadow.set()
    arc(start: 42, end: 61, width: 17, color: NSColor(calibratedRed: 0.18, green: 0.93, blue: 1, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    arc(start: 42, end: 61, width: 14, color: NSColor(calibratedRed: 0.3, green: 0.97, blue: 1, alpha: 1))

    context.flushGraphics()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MoniArcIcon", code: 2)
    }
    try png.write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
}

for size in sizes { try render(size: size) }

let contents = """
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64x64.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024x1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contents.write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
