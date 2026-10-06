#!/usr/bin/env swift
import AppKit

// Reproduce the app icon from the same vector knot and palette as the menu bar.
// Run from any directory with: swift scripts/generate-app-icon.swift
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
guard let knot = NSImage(contentsOf: resources.appendingPathComponent("UsageKnot.pdf")) else {
    fatalError("Missing vector UsageKnot.pdf")
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func render(pixels: Int) -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
        pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create icon canvas")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    let cg = graphics.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // A softly bevelled instrument housing, with transparent macOS icon margins.
    let housing = NSBezierPath(roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860),
                               xRadius: 192, yRadius: 192)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x292A27, alpha: 0.22)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0xD9D8D0).setFill()
    housing.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xD9D8D0), ending: color(0xF6F5EF))!.draw(in: housing, angle: 90)
    color(0xFFFFFF, alpha: 0.75).setStroke()
    housing.lineWidth = 3
    housing.stroke()

    // Recessed LCD face. Shading stays subtle enough to read at Finder sizes.
    let face = NSBezierPath(roundedRect: NSRect(x: 126, y: 132, width: 772, height: 772),
                           xRadius: 154, yRadius: 154)
    NSGradient(starting: color(0xB3B9A3), ending: color(0xCFD5C1))!.draw(in: face, angle: 90)
    color(0x818975, alpha: 0.64).setStroke()
    face.lineWidth = 3
    face.stroke()

    let center = NSPoint(x: 512, y: 518)
    let radius: CGFloat = 301
    let width: CGFloat = pixels <= 32 ? 48 : 38
    let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2))
    track.lineWidth = width
    color(0x9EA78D, alpha: 0.82).setStroke()
    track.stroke()

    // An illustrative 82% allowance, clockwise from twelve o'clock.
    let end: CGFloat = 90 - 360 * 0.82
    let budget = NSBezierPath()
    budget.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: end, clockwise: true)
    budget.lineWidth = width
    budget.lineCapStyle = .round
    color(0x465337).setStroke()
    budget.stroke()
    let radians = end * .pi / 180
    let endpoint = NSPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
    color(0xE86A25).setFill()
    NSBezierPath(ovalIn: NSRect(x: endpoint.x - width / 2, y: endpoint.y - width / 2,
                               width: width, height: width)).fill()

    let logoSize: CGFloat = 422
    let logoRect = NSRect(x: center.x - logoSize / 2, y: center.y - logoSize / 2,
                          width: logoSize, height: logoSize)
    // Tint a separate layer, preserving the exact bundled knot geometry.
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    knot.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1)
    color(0x292F25).setFill()
    logoRect.fill(using: .sourceIn)
    cg.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode icon PNG")
    }
    return png
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        try render(pixels: points * scale).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try render(pixels: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", resources.appendingPathComponent("AppIcon.icns").path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated Resources/AppIcon.png and Resources/AppIcon.icns")
