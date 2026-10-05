import AppKit

enum DashboardTab: Int, CaseIterable {
    case allowance, tokens
    var title: String {
        switch self {
        case .allowance: return "Remaining Allowance"
        case .tokens: return "Token Usage"
        }
    }
}

/// A compact local-calendar histogram. Long histories are grouped into adjacent
/// day bins so every recorded token remains represented at menu-bar scale.
final class DailyTokenChart: NSView {
    private struct Bin {
        let start: Date
        let end: Date
        let tokens: Double
    }
    private let bins: [Bin]
    private var tooltipTexts: [String] = []

    init(days: [DailyUsageTotal]) {
        let stride = max(1, Int(ceil(Double(days.count) / 32)))
        bins = Swift.stride(from: 0, to: days.count, by: stride).map { start in
            let slice = days[start..<min(start + stride, days.count)]
            return Bin(start: slice.first!.date, end: slice.last!.date,
                       tokens: slice.reduce(0) { $0 + $1.tokens })
        }
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 98).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Token consumption over time")
        let accessibleDate = DateFormatter()
        accessibleDate.dateStyle = .medium
        let count = NumberFormatter()
        count.numberStyle = .decimal
        count.maximumFractionDigits = 0
        let periods = bins.map { bin -> String in
            let range = accessibleDate.string(from: bin.start)
                + (bin.start == bin.end ? "" : " through \(accessibleDate.string(from: bin.end))")
            return "\(range): \(count.string(from: NSNumber(value: bin.tokens)) ?? "0") tokens"
        }.joined(separator: "; ")
        setAccessibilityValue("\(days.count) days. \(bins.count) bars. \(periods).")
        toolTip = "All input and output tokens, including cached input. Dates use your Mac’s time zone."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func count(_ value: Double) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", value / 1_000) }
        return String(format: "%.0f", value)
    }
    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        removeAllToolTips()
        tooltipTexts.removeAll()
        guard let first = bins.first, let last = bins.last else { return }
        let chart = NSRect(x: 0, y: 20, width: bounds.width, height: bounds.height - 36)
        let maxTokens = max(1, bins.map(\.tokens).max() ?? 0)
        for fraction in [0.0, 0.5, 1.0] {
            UsagePalette.meter.withAlphaComponent(0.16).setFill()
            NSRect(x: chart.minX, y: chart.minY + chart.height * fraction,
                   width: chart.width, height: 0.5).fill()
        }
        let step = chart.width / CGFloat(bins.count)
        let width = max(1, min(16, step - 3))
        for (index, bin) in bins.enumerated() {
            let height = bin.tokens > 0 ? max(1.5, chart.height * bin.tokens / maxTokens) : 0
            let bar = NSRect(x: chart.minX + CGFloat(index) * step + (step - width) / 2,
                             y: chart.minY, width: width, height: height)
            (index == bins.count - 1 ? UsagePalette.ink : UsagePalette.meter).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
            let period = dateLabel(bin.start) + (bin.start == bin.end ? "" : "–\(dateLabel(bin.end))")
            tooltipTexts.append("\(period): \(Self.count(bin.tokens)) tokens")
            addToolTip(NSRect(x: CGFloat(index) * step, y: chart.minY, width: step, height: chart.height),
                       owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: UsagePalette.secondary
        ]
        let scale = "\(Self.count(maxTokens))\(first.start == first.end ? " / day" : " / bar")" as NSString
        scale.draw(at: NSPoint(x: 0, y: bounds.height - 12), withAttributes: attrs)
        (dateLabel(first.start) as NSString).draw(at: NSPoint(x: 0, y: 1), withAttributes: attrs)
        let end = dateLabel(last.end) as NSString
        end.draw(at: NSPoint(x: bounds.width - end.size(withAttributes: attrs).width, y: 1), withAttributes: attrs)
    }
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        let index = data.map { Int(bitPattern: $0) - 1 } ?? -1
        return tooltipTexts.indices.contains(index) ? tooltipTexts[index] : ""
    }
}

final class AnalyticsBar: NSView {
    private let fraction: Double
    init(fraction: Double) {
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 4).isActive = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        UsagePalette.ink.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        UsagePalette.meter.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height),
                     xRadius: 2, yRadius: 2).fill()
    }
}
