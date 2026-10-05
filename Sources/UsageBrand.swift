import AppKit

/// The instrument face is intentionally warm in either system appearance.
/// Semantic labels use opaque ink so small captions stay legible on the LCD.
enum UsagePalette {
    static let housing = color(0xE5E3DC)
    static let housingTop = color(0xF0EFE9)
    static let housingBottom = color(0xD9D8D0)
    static let ink = color(0x292A27)
    static let secondary = color(0x41483B)
    static let edge = color(0xACAEA2)
    static let lcdTop = color(0xBCC5AB)
    static let lcdBottom = color(0xB3B9A3)
    static let lcdEdge = color(0x818975)
    static let track = color(0x9EA78D)
    static let meter = color(0x465337)
    static let accent = color(0xE86A25)
    static let warning = color(0x743009)
    static let critical = color(0x8A2922)

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

/// The bundled OpenAI knot, rendered as a native monochrome template image.
enum UsageBrand {
    private static let bundledLogo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "UsageKnot", withExtension: "pdf"),
              let image = NSImage(contentsOf: url), image.isValid else { return nil }
        image.isTemplate = true
        return image
    }()

    static func logo(size: CGFloat) -> NSImage? {
        guard size.isFinite, size > 0,
              let image = bundledLogo?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}
