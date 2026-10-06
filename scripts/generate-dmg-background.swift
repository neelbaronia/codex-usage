#!/usr/bin/env swift
import AppKit

// Finder's layout uses a 600 x 340 point canvas. Icon centers are (160, 100)
// and (440, 100), measured from the top-left of the content area.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let size = NSSize(width: 600, height: 340)
try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func render(scale: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600 * scale,
        pixelsHigh: 340 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    rgb(0xF4F3ED).setFill()
    NSRect(origin: .zero, size: size).fill()

    let ink = rgb(0x465337)
    let text = "Drag to Applications" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 17, weight: .medium),
        .foregroundColor: ink
    ]
    let textSize = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (600 - textSize.width) / 2,
                          y: 340 - 34 - textSize.height / 2), withAttributes: attrs)

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 243, y: 240))
    arrow.line(to: NSPoint(x: 357, y: 240))
    arrow.move(to: NSPoint(x: 340, y: 257))
    arrow.line(to: NSPoint(x: 357, y: 240))
    arrow.line(to: NSPoint(x: 340, y: 223))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    ink.setStroke()
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let normal = render(scale: 1)
let retina = render(scale: 2)
guard let tiff = NSBitmapImageRep.representationOfImageReps(in: [normal, retina], using: .tiff, properties: [:]),
      let png = retina.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode Finder background")
}
try tiff.write(to: root.appendingPathComponent("Resources/dmg-background.tiff"))
try png.write(to: root.appendingPathComponent("build/dmg-background-preview.png"))
print("Generated Resources/dmg-background.tiff (600x340 points, standard + Retina)")
