import AppKit

struct TimelineScenario {
    let id: String
    let label: String
    let hours: Double?
}

/// A proportional time axis. Forecast dates come from the quota reading's time,
/// not the redraw time, so an unchanged prediction does not drift into the future.
final class UsageTimelineView: NSView {
    private let now: Date
    private let reset: Date
    private let end: Date?
    private let horizon: TimeInterval
    private let clipped: Bool

    init(now: Date, reset: Date, estimatedEnd: Date?) {
        self.now = now
        self.reset = reset
        self.end = estimatedEnd
        let resetDistance = max(60, reset.timeIntervalSince(now))
        // Keep the reset readable even when a light-use scenario lasts months.
        let limit = max(resetDistance * 1.35, 3600)
        let endDistance = max(0, estimatedEnd?.timeIntervalSince(now) ?? 0)
        horizon = max(resetDistance, min(limit, endDistance))
        clipped = endDistance > limit
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 80).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Usage timeline")
        let endDescription = estimatedEnd.map { "Estimated allowance limit \(Self.fullDate($0))\($0 >= reset ? ", assuming no reset" : "")\(clipped ? ", beyond the displayed time range" : "")" } ?? "Allowance estimate unavailable"
        let description = "Now, \(Self.fullDate(now)). \(endDescription). Reset \(Self.fullDate(reset)). Day marks indicate midnight in your local time zone."
        setAccessibilityValue(description)
        toolTip = description
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let left: CGFloat = 8
        // The final few points leave room for a clipped-end arrow.
        let right = max(left + 1, bounds.width - 12)
        let y: CGFloat = 35
        func x(_ date: Date) -> CGFloat {
            left + CGFloat(min(1, max(0, date.timeIntervalSince(now) / horizon))) * (right - left)
        }
        let resetX = x(reset)
        let endX = end.map(x)
        let amber = NSColor.systemOrange.withAlphaComponent(0.88)
        let green = NSColor.systemGreen.withAlphaComponent(0.90)
        let markerClearance: CGFloat = 12
        // Keep x positions proportional. Colliding markers move vertically,
        // with a fine leader back to their true point on the time axis.
        let resetY = abs(resetX - left) < markerClearance ? y - 11 : y
        let endY = endX.map { position in
            abs(position - left) < markerClearance || abs(position - resetX) < markerClearance ? y + 10 : y
        }

        stroke(from: NSPoint(x: left, y: y), to: NSPoint(x: right, y: y),
               color: .separatorColor, width: 1.5)
        if let endX, endX > left {
            stroke(from: NSPoint(x: left, y: y), to: NSPoint(x: endX, y: y), color: amber, width: 2)
        }

        let resetWidth: CGFloat = 54
        let resetLabelX = min(max(42, resetX - resetWidth / 2), max(42, bounds.width - resetWidth))
        let resetAlignedRight = resetLabelX + resetWidth >= bounds.width
        let resetTextWidth = ceil(max(
            (Self.shortDate(reset) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]).width,
            ("Reset" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9)]).width))
        let resetTextX = resetLabelX + (resetAlignedRight ? resetWidth - resetTextWidth : (resetWidth - resetTextWidth) / 2)
        let resetLabelBounds = NSRect(x: resetTextX - 4, y: 0, width: resetTextWidth + 8, height: 29)

        // Use local midnight rather than fixed 24-hour intervals, including
        // daylight-saving transitions. Keep ticks visible beside event markers;
        // only their labels are omitted when the label lane becomes crowded.
        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE"
        let dayAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
        ]
        var day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        var count = 0
        var lastDayLabelRight: CGFloat = -4
        while let tick = day, tick.timeIntervalSince(now) < horizon, count < 40 {
            let position = x(tick)
            let nearMarker = abs(position - left) < 9 || abs(position - resetX) < 9 ||
                (endX.map { abs(position - $0) < 9 } ?? false)
            let coincidesWithStaggeredEnd = endX.map { abs(position - $0) < 6 } == true &&
                endY.map { $0 > y + 6 } == true
            // The forecast leader already marks a coincident midnight. Avoid
            // drawing a neutral tick through its vertically staggered diamond.
            if !coincidesWithStaggeredEnd {
                stroke(from: NSPoint(x: position, y: y + (nearMarker ? 6 : -4)),
                       to: NSPoint(x: position, y: y + (nearMarker ? 11 : 5)),
                       color: NSColor.secondaryLabelColor.withAlphaComponent(0.55), width: 1)
            }
            let dayText = dayFormatter.string(from: tick) as NSString
            let labelWidth = ceil(dayText.size(withAttributes: dayAttributes).width)
            let labelX = min(max(0, position - labelWidth / 2), max(0, bounds.width - labelWidth))
            let dayBounds = NSRect(x: labelX, y: 17, width: labelWidth, height: 14)
            if labelX >= lastDayLabelRight + 4, !dayBounds.intersects(resetLabelBounds) {
                dayText.draw(in: dayBounds, withAttributes: dayAttributes)
                lastDayLabelRight = dayBounds.maxX
            }
            day = calendar.date(byAdding: .day, value: 1, to: tick)
            count += 1
        }

        // Reset and Now share the upper label lane; a close reset label is
        // nudged right and connected without changing its time position.
        let resetAnchor = min(max(resetX, resetLabelX + 4), resetLabelX + resetWidth - 4)
        stroke(from: NSPoint(x: resetX, y: y), to: NSPoint(x: resetX, y: resetY),
               color: green.withAlphaComponent(0.45), width: 0.75)
        stroke(from: NSPoint(x: resetX, y: resetY), to: NSPoint(x: resetAnchor, y: 27),
               color: green.withAlphaComponent(0.45), width: 0.75)
        label(Self.shortDate(reset), subtitle: "Reset", x: resetLabelX, y: 0,
              width: resetWidth, color: .secondaryLabelColor,
              alignment: resetAlignedRight ? .right : .center)

        if let end, let endX, let endY {
            let subtitle = end >= reset ? "End without reset\(clipped ? " →" : "")" : "Est. limit"
            let labelWidth: CGFloat = end >= reset ? 102 : 66
            let labelX = min(max(0, endX - labelWidth / 2), max(0, bounds.width - labelWidth))
            let labelAnchor = min(max(endX, labelX + 4), labelX + labelWidth - 4)
            stroke(from: NSPoint(x: endX, y: y), to: NSPoint(x: endX, y: endY),
                   color: amber.withAlphaComponent(0.45), width: 0.75)
            stroke(from: NSPoint(x: endX, y: endY), to: NSPoint(x: labelAnchor, y: 50),
                   color: amber.withAlphaComponent(0.45), width: 0.75)
            label(Self.shortDate(end), subtitle: subtitle, x: labelX, y: 53,
                  width: labelWidth, color: .secondaryLabelColor,
                  alignment: labelX == 0 ? .left : (labelX + labelWidth >= bounds.width ? .right : .center))
        }

        // Draw markers after leaders so their centres stay clean.
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: NSRect(x: left - 3.5, y: y - 3.5, width: 7, height: 7)).fill()
        singleLabel("Now", rect: NSRect(x: 0, y: 2, width: 35, height: 14), color: .secondaryLabelColor)

        let resetDot = NSBezierPath(ovalIn: NSRect(x: resetX - 4, y: resetY - 4, width: 8, height: 8))
        NSColor.controlBackgroundColor.setFill()
        resetDot.fill()
        green.setStroke()
        resetDot.lineWidth = 1.5
        resetDot.stroke()

        if let endX, let endY {
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: endX, y: endY - 4.5))
            diamond.line(to: NSPoint(x: endX + 4.5, y: endY))
            diamond.line(to: NSPoint(x: endX, y: endY + 4.5))
            diamond.line(to: NSPoint(x: endX - 4.5, y: endY))
            diamond.close()
            amber.setFill()
            diamond.fill()
            if clipped {
                stroke(from: NSPoint(x: right + 5, y: endY - 3), to: NSPoint(x: right + 9, y: endY), color: amber, width: 1)
                stroke(from: NSPoint(x: right + 9, y: endY), to: NSPoint(x: right + 5, y: endY + 3), color: amber, width: 1)
            }
        }
    }

    private func stroke(from start: NSPoint, to end: NSPoint, color: NSColor, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: start); path.line(to: end)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke(); path.stroke()
    }

    private func label(_ title: String, subtitle: String, x: CGFloat, y: CGFloat,
                       width: CGFloat, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: color, .paragraphStyle: paragraph
        ]
        let dateAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph
        ]
        (title as NSString).draw(in: NSRect(x: x, y: y, width: width, height: 13), withAttributes: titleAttributes)
        (subtitle as NSString).draw(in: NSRect(x: x, y: y + 13, width: width, height: 12), withAttributes: dateAttributes)
    }

    private func singleLabel(_ text: String, rect: NSRect, color: NSColor) {
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: color
        ])
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d"
        return formatter.string(from: date)
    }

    static func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
