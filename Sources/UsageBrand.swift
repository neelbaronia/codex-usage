import AppKit

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
