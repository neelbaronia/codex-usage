import AppKit
import ServiceManagement

func windowName(_ window: UsageWindow) -> String { window.label }

func runwayTime(_ hours: Double) -> String {
    if hours <= 0 { return "0h" }
    if hours < 1 { return "\(max(1, Int((hours * 60).rounded())))m" }
    if hours < 48 { return String(format: "%.1fh", hours) }
    return String(format: "%.1fd", hours / 24)
}

private func textLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                       color: NSColor = UsagePalette.ink) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.isSelectable = false
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
}

private func caption(_ text: String, size: CGFloat = 10) -> NSTextField {
    let label = textLabel(text.uppercased(), size: size, color: UsagePalette.secondary)
    label.font = .monospacedSystemFont(ofSize: size, weight: .medium)
    return label
}

private func vertical(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    for child in views {
        child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    return stack
}

private func horizontal(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    return stack
}

private final class EngravedRule: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 2) }
    override func draw(_ dirtyRect: NSRect) {
        UsagePalette.ink.withAlphaComponent(0.18).setFill()
        NSRect(x: 0, y: 1, width: bounds.width, height: 0.5).fill()
        NSColor.white.withAlphaComponent(0.48).setFill()
        NSRect(x: 0, y: 0.5, width: bounds.width, height: 0.5).fill()
    }
}
private func separator() -> NSView { EngravedRule() }

private func compactTokens(_ tokens: Double) -> String {
    if tokens >= 1_000_000_000 { return String(format: "%.1fB", tokens / 1_000_000_000) }
    if tokens >= 1_000_000 { return String(format: "%.1fM", tokens / 1_000_000) }
    if tokens >= 1_000 { return String(format: "%.0fK", tokens / 1_000) }
    return String(format: "%.0f", tokens)
}

private func formatDate(_ date: Date, _ format: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = format
    return formatter.string(from: date)
}

private final class DashboardSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [UsagePalette.housingTop, UsagePalette.housing, UsagePalette.housingBottom])?
            .draw(in: bounds, angle: 270)
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        UsagePalette.edge.setStroke(); outer.lineWidth = 1; outer.stroke()
        let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(0.55).setStroke(); inner.lineWidth = 0.5; inner.stroke()
    }
}

private final class InstrumentReadout: NSView {
    init(content: NSView) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let face = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), xRadius: 6, yRadius: 6)
        NSGradient(starting: UsagePalette.lcdTop, ending: UsagePalette.lcdBottom)?.draw(in: face, angle: 270)
        UsagePalette.lcdEdge.setStroke(); face.lineWidth = 1; face.stroke()
        let top = NSBezierPath()
        top.move(to: NSPoint(x: 6, y: bounds.maxY - 2))
        top.line(to: NSPoint(x: bounds.maxX - 6, y: bounds.maxY - 2))
        UsagePalette.ink.withAlphaComponent(0.14).setStroke(); top.lineWidth = 1.5; top.stroke()
        let bottom = NSBezierPath()
        bottom.move(to: NSPoint(x: 6, y: 0.5)); bottom.line(to: NSPoint(x: bounds.maxX - 6, y: 0.5))
        NSColor.white.withAlphaComponent(0.8).setStroke(); bottom.lineWidth = 1; bottom.stroke()
    }
}

/// Standard NSButton behavior, keyboard support, and accessibility with a small
/// raised metal face. Only the bezel is custom; AppKit still draws the content.
private final class InstrumentButton: NSButton {
    var accent = false
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(62, super.intrinsicContentSize.width + 16), height: 28)
    }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 4, yRadius: 4).fill()
    }
    override func draw(_ dirtyRect: NSRect) {
        let face = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1.5), xRadius: 4, yRadius: 4)
        let base = accent ? UsagePalette.accent : UsagePalette.housing
        let upper = base.blended(withFraction: isHighlighted ? 0.06 : 0.35, of: isHighlighted ? .black : .white) ?? base
        let lower = base.blended(withFraction: isHighlighted ? 0.1 : 0.06, of: .black) ?? base
        NSGradient(starting: upper, ending: lower)?.draw(in: face, angle: 270)
        UsagePalette.ink.withAlphaComponent(isEnabled ? 0.26 : 0.12).setStroke()
        face.lineWidth = 1; face.stroke()
        cell?.drawInterior(withFrame: bounds.insetBy(dx: 9, dy: 0), in: self)
    }
}

private func instrumentButton(_ title: String, target: AnyObject, action: Selector, accent: Bool = false) -> NSButton {
    let button = InstrumentButton(title: title, target: target, action: action)
    button.accent = accent
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.focusRingType = .exterior
    button.font = .systemFont(ofSize: 11, weight: .medium)
    button.contentTintColor = UsagePalette.ink
    button.attributedTitle = NSAttributedString(string: title, attributes: [
        .font: button.font!, .foregroundColor: NSColor(srgbRed: 0.118, green: 0.125, blue: 0.106, alpha: 1)
    ])
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
}

private final class RemainingBar: NSView {
    let remaining: Double?
    init(_ value: Double?) {
        remaining = value
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 10).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Remaining allowance")
        setAccessibilityValue(value.map { "\(Int($0.rounded())) percent" } ?? "Unknown")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let fillWidth = bounds.width * CGFloat(min(100, max(0, remaining ?? 0))) / 100
        let color = (remaining ?? 100) <= 10 ? UsagePalette.critical :
            (remaining ?? 100) <= 25 ? UsagePalette.warning : UsagePalette.meter
        let count = 32
        let step = bounds.width / CGFloat(count)
        for index in 0..<count {
            let rect = NSRect(x: CGFloat(index) * step, y: 0, width: max(1, step - 2), height: bounds.height)
            UsagePalette.track.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            let filled = min(rect.width, max(0, fillWidth - rect.minX))
            if remaining != nil, filled > 0 {
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX, y: 0, width: filled, height: rect.height), xRadius: 1, yRadius: 1).fill()
            }
        }
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class DashboardController: NSViewController {
    weak var owner: UsageApp?
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var readoutStack: NSStackView?
    private var detailsExpanded = UserDefaults.standard.bool(forKey: "ModelDetailsExpanded")
    private var settingsExpanded = false
    private var resetScroll = false
    private var showAllRepositories = false

    override func loadView() {
        let surface = DashboardSurface(frame: NSRect(x: 0, y: 0, width: 350, height: 450))
        surface.appearance = NSAppearance(named: .aqua)
        view = surface
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        surface.addSubview(scroll)
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: surface.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: 350)
        ])
    }

    private func add(_ content: NSView, top: CGFloat = 0, bottom: CGFloat = 0, inset: CGFloat = 20) {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(content)
        let destination = readoutStack ?? stack
        destination.addArrangedSubview(wrapper)
        NSLayoutConstraint.activate([
            wrapper.widthAnchor.constraint(equalTo: destination.widthAnchor),
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: top),
            content.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -bottom)
        ])
    }

    func render() {
        _ = view
        guard let owner else { return }
        let oldOrigin = resetScroll ? NSPoint.zero : scroll.contentView.bounds.origin
        resetScroll = false
        readoutStack = nil
        for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
        let plan = owner.snapshot?.buckets.compactMap(\.planType).first?.capitalized ?? "Account"
        let mark = NSImageView()
        mark.image = UsageBrand.logo(size: 18) ?? NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)
        mark.contentTintColor = UsagePalette.ink
        mark.widthAnchor.constraint(equalToConstant: 18).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let title = caption("Codex / Usage", size: 11)
        title.textColor = UsagePalette.ink
        add(horizontal([mark, title, NSView(), caption(plan)]), top: 18, bottom: 12)

        let tabs = NSSegmentedControl(labels: DashboardTab.allCases.map(\.title), trackingMode: .selectOne,
                                      target: self, action: #selector(selectTab(_:)))
        tabs.selectedSegment = owner.selectedTab.rawValue
        tabs.segmentDistribution = .fillEqually
        tabs.segmentStyle = .texturedRounded
        tabs.font = .systemFont(ofSize: 12, weight: .medium)
        tabs.setAccessibilityLabel("Usage view")
        add(tabs, bottom: 16, inset: 14)
        if owner.selectedTab == .allowance { addAllowanceContent(owner) }
        else { addHistoryContent(owner) }
        if let error = owner.actionErrorText { add(textLabel(error, size: 11, color: UsagePalette.warning), top: 10, bottom: 10) }

        let footerText: String
        if owner.selectedTab != .allowance {
            if owner.isReadingAnalytics { footerText = "Reading local history…" }
            else if let date = owner.analyticsScannedAt { footerText = "Local · \(formatDate(date, "h:mm a"))" }
            else { footerText = "Local history" }
        }
        else if let count = owner.snapshot?.availableResets, count > 0 { footerText = "\(count) full reset\(count == 1 ? "" : "s") available" }
        else if owner.isRefreshing { footerText = "Refreshing…" }
        else if let date = owner.snapshot?.fetchedAt { footerText = "Updated \(formatDate(date, "h:mm a"))" }
        else { footerText = "Codex account allowance" }
        let footer = textLabel(footerText, size: 10, color: UsagePalette.secondary)
        footer.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        footer.toolTip = owner.selectedTab == .allowance ? freshness(owner) : "Local token history · refreshes every 5 minutes after the first scan"
        let settings = instrumentButton("Settings", target: self, action: #selector(toggleSettings), accent: true)
        settings.setAccessibilityValue(settingsExpanded ? "Expanded" : "Collapsed")
        add(horizontal([footer, NSView(), settings]), top: 10, bottom: 14, inset: 14)
        if settingsExpanded { addSettings(owner) }

        view.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height)
        document.setFrameSize(NSSize(width: 350, height: height))
        let availableHeight = max(200, ((view.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 700) - 60)
        preferredContentSize = NSSize(width: 350, height: min(height, availableHeight))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(oldOrigin.y, max(0, height - preferredContentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func addAllowanceContent(_ owner: UsageApp) {
        let readout = NSStackView()
        readout.orientation = .vertical
        readout.alignment = .leading
        readout.spacing = 0
        readoutStack = readout

        if let snapshot = owner.snapshot, !snapshot.buckets.isEmpty {
            let window = owner.statusWindow
            if let window { addAllowance(window) }
            else { add(textLabel("Allowance information unavailable", size: 18, weight: .medium), bottom: 20) }
            // Keep every reported window visible, even when the compact headline
            // uses a different, more limiting window than the weekly allowance.
            var skippedHeadline = false
            for bucket in snapshot.buckets {
                let windows = [bucket.primary, bucket.secondary].compactMap { $0 }
                for other in windows {
                    if !skippedHeadline && other == window { skippedHeadline = true; continue }
                    let label = snapshot.buckets.count > 1 ? "\(bucket.name ?? bucket.id) · \(other.label)" : other.label
                    let percent = other.remainingPercent.map { "\(Int($0.rounded()))% remaining" } ?? "Unavailable"
                    add(vertical([horizontal([textLabel(label, size: 12), NSView(), textLabel(percent, size: 12, weight: .medium)]),
                        resetRow(other)], spacing: 5), bottom: 15)
                }
            }
            if snapshot.ordinaryUsageAllowed == false {
                add(textLabel("Account usage is currently restricted.", size: 12, color: UsagePalette.warning), bottom: 16)
            }
        } else {
            add(vertical([textLabel(owner.isRefreshing ? "Checking your allowance…" : "Usage unavailable", size: 20, weight: .medium),
                textLabel("Uses the account already signed in to Codex.", size: 12, color: UsagePalette.secondary)]), bottom: 22)
        }

        if let error = owner.errorText { add(textLabel(error, size: 11, color: UsagePalette.warning), bottom: 16) }
        if let snapshot = owner.snapshot, !owner.isRefreshing, Date().timeIntervalSince(snapshot.fetchedAt) > 600 || owner.errorText != nil {
            add(textLabel("Last successful update \(formatDate(snapshot.fetchedAt, "EEE, h:mm a"))", size: 11, color: UsagePalette.secondary), bottom: 12)
        }

        let forecast = owner.forecast
        let rates = owner.history.map { ModelUsageRates.calculate(history: $0) } ?? []
        let scenarios = makeScenarios(forecast, rates)
        let selected = scenarios.first(where: { $0.id == owner.selectedTimelineID }) ?? scenarios.first(where: { $0.hours != nil }) ?? scenarios.first
        add(separator(), bottom: 16)
        addRunway(owner, selected: selected)
        readoutStack = nil
        add(InstrumentReadout(content: readout), bottom: 14, inset: 14)
        let disclosure = instrumentButton("Model token rates", target: self, action: #selector(toggleDetails))
        disclosure.alignment = .left
        disclosure.font = .systemFont(ofSize: 12)
        disclosure.image = NSImage(systemSymbolName: detailsExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        disclosure.imagePosition = .imageTrailing
        disclosure.setAccessibilityLabel("Model token rates")
        disclosure.setAccessibilityValue(detailsExpanded ? "Expanded" : "Collapsed")
        add(disclosure, bottom: 14, inset: 14)
        if detailsExpanded { addDetails(owner, forecast: forecast, rates: rates, scenarios: scenarios, selected: selected) }
        add(separator(), inset: 14)

    }

    @objc private func selectTab(_ sender: NSSegmentedControl) {
        guard let owner, let tab = DashboardTab(rawValue: sender.selectedSegment) else { return }
        owner.selectedTab = tab
        resetScroll = true
        owner.updateUI()
        if tab != .allowance { owner.refreshAnalytics() }
    }

    @objc private func selectRange(_ sender: NSSegmentedControl) {
        guard let owner, UsageReportingRange.allCases.indices.contains(sender.selectedSegment) else { return }
        owner.analyticsRange = UsageReportingRange.allCases[sender.selectedSegment]
        resetScroll = true
        showAllRepositories = false
        owner.updateUI()
    }

    @objc private func toggleRepositories() {
        showAllRepositories.toggle()
        owner?.updateUI()
    }

    private func money(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = amount >= 10_000 ? 0 : 2
        return formatter.string(from: NSNumber(value: amount)) ?? "—"
    }

    private func exactTokens(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: amount)) ?? "—"
    }

    private func fixedValue(_ value: String, size: CGFloat = 12) -> NSTextField {
        let label = textLabel(value, size: size, weight: .medium)
        label.font = .monospacedDigitSystemFont(ofSize: size, weight: .medium)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func historyReadout(_ content: () -> Void) {
        let readout = NSStackView()
        readout.orientation = .vertical
        readout.alignment = .leading
        readout.spacing = 0
        readoutStack = readout
        content()
        readoutStack = nil
        add(InstrumentReadout(content: readout), bottom: 16, inset: 14)
    }

    private func addHistoryContent(_ owner: UsageApp) {
        let picker = NSSegmentedControl(labels: ["7 days", "30 days", "All available"], trackingMode: .selectOne,
                                        target: self, action: #selector(selectRange(_:)))
        picker.selectedSegment = UsageReportingRange.allCases.firstIndex(of: owner.analyticsRange) ?? 2
        picker.segmentDistribution = .fillEqually
        picker.controlSize = .small
        picker.setAccessibilityLabel("Local history date range")
        add(picker, bottom: 14)
        guard let analytics = owner.analytics else {
            historyReadout {
                add(caption("Local history"), bottom: 10)
                add(textLabel(owner.isReadingAnalytics ? "Reading your usage…" : "History unavailable", size: 22, weight: .medium), bottom: 12)
                add(textLabel(owner.analyticsErrorText ?? "The first scan can take a moment. Your allowance is still available.", size: 12, color: UsagePalette.secondary), bottom: 16)
            }
            add(textLabel("Token and repository history stays on this Mac.", size: 11, color: UsagePalette.secondary), bottom: 16)
            add(separator(), inset: 14)
            return
        }
        if owner.selectedTab == .tokens { addTokenHistory(analytics) }
        else { addRepositoryHistory(analytics) }
        if let error = owner.analyticsErrorText {
            add(textLabel(error, size: 11, color: UsagePalette.warning), top: 4, bottom: 10)
        }
        if let date = owner.analyticsScannedAt,
           owner.analyticsErrorText != nil || Date().timeIntervalSince(date) > 900 {
            add(textLabel("Showing history read \(formatDate(date, "MMM d, h:mm a")).", size: 11, color: UsagePalette.secondary), bottom: 10)
        }
        if let warning = owner.analyticsWarning {
            add(textLabel(warning, size: 11, color: UsagePalette.warning), bottom: 10)
        }
        add(textLabel("Local logs only · other devices and deleted history may be missing.", size: 10, color: UsagePalette.secondary), top: 4, bottom: 14)
        add(separator(), inset: 14)
    }

    private func historyPeriod(_ analytics: UsageAnalytics) -> String {
        "\(formatDate(analytics.startDate, "MMM d, yyyy")) – \(formatDate(analytics.endDate, "MMM d, yyyy"))"
    }

    private func addTokenHistory(_ analytics: UsageAnalytics) {
        historyReadout {
            add(caption("Total tokens"), bottom: 5)
            let headline = fixedValue(compactTokens(analytics.totalTokens), size: 44)
            headline.toolTip = "\(exactTokens(analytics.totalTokens)) input + output tokens"
            headline.setAccessibilityValue("\(exactTokens(analytics.totalTokens)) tokens")
            add(headline, bottom: 4)
            add(textLabel(historyPeriod(analytics), size: 10, color: UsagePalette.secondary), bottom: 12)
            if analytics.totalTokens > 0 { add(DailyTokenChart(days: analytics.days), bottom: 14) }
            else { add(textLabel("No token activity found in this range.", size: 12, color: UsagePalette.secondary), top: 4, bottom: 18) }
            add(separator(), bottom: 12)
            for (label, value) in [("Input", analytics.inputTokens), ("Output", analytics.outputTokens)] {
                let row = horizontal([textLabel(label, size: 12), NSView(), fixedValue(compactTokens(value))])
                row.toolTip = "\(exactTokens(value)) tokens"
                add(row, bottom: 7)
            }
            let cache = textLabel("\(compactTokens(analytics.cachedInputTokens)) cached · included in input", size: 10, color: UsagePalette.secondary)
            cache.toolTip = "\(exactTokens(analytics.cachedInputTokens)) cached input tokens. Cached input is counted once; reasoning is included in output."
            add(cache, top: 2, bottom: 16)
        }
        if !analytics.models.isEmpty {
            add(caption("By model"), bottom: 12)
            for model in analytics.models {
                let name = textLabel(model.model, size: 12)
                name.lineBreakMode = .byTruncatingMiddle
                name.maximumNumberOfLines = 1
                let row = horizontal([name, NSView(), fixedValue(compactTokens(model.tokens))])
                row.toolTip = "\(model.model): \(exactTokens(model.tokens)) tokens"
                add(vertical([row, AnalyticsBar(fraction: model.tokens / max(1, analytics.totalTokens))], spacing: 6), bottom: 13)
            }
        }
    }

    private func addRepositoryHistory(_ analytics: UsageAnalytics) {
        historyReadout {
            add(caption("API-equivalent estimate"), bottom: 6)
            let hasCost = analytics.pricedTokens > 0
            let headline = fixedValue(hasCost ? "≈" + money(analytics.estimatedCostUSD) : "—", size: 32)
            headline.toolTip = pricingExplanation
            add(headline, bottom: 5)
            add(textLabel(historyPeriod(analytics), size: 10, color: UsagePalette.secondary), bottom: 12)
            if analytics.totalTokens == 0 {
                add(textLabel("No token activity found in this range.", size: 12, color: UsagePalette.secondary), bottom: 16)
            } else if analytics.unpricedTokens > 0 {
                let coverage = 100 * analytics.pricedTokens / max(1, analytics.totalTokens)
                add(textLabel("Prices cover \(Int(coverage.rounded(.down)))% of tokens. \(compactTokens(analytics.unpricedTokens)) unpriced.", size: 11, color: UsagePalette.secondary), bottom: 12)
            }
            let explanation = textLabel("Standard API prices · not your subscription bill", size: 10, color: UsagePalette.secondary)
            explanation.toolTip = pricingExplanation
            add(explanation, bottom: 16)
        }
        if !analytics.repositories.isEmpty {
            add(horizontal([caption("By repository"), NSView(), caption("USD")]), bottom: 14)
            let maximum = analytics.repositories.map(\.costUSD).max() ?? 0
            let duplicates = Dictionary(grouping: analytics.repositories, by: \.name)
            for repository in analytics.repositories.prefix(showAllRepositories ? analytics.repositories.count : 8) {
                let name = textLabel(repository.name, size: 12, weight: .medium)
                name.lineBreakMode = .byTruncatingMiddle
                name.maximumNumberOfLines = 1
                let costText = repository.pricedTokens > 0 ? money(repository.costUSD) + (repository.unpricedTokens > 0 ? "+" : "") : "Unpriced"
                let row = horizontal([name, NSView(), fixedValue(costText)])
                let partial = repository.unpricedTokens > 0 && repository.pricedTokens > 0 ? " · partial estimate" : ""
                var detail = "\(compactTokens(repository.tokens)) tokens\(partial)"
                if (duplicates[repository.name]?.count ?? 0) > 1, let path = repository.path {
                    detail += " · " + URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                }
                let subtitle = textLabel(detail, size: 10, color: UsagePalette.secondary)
                subtitle.maximumNumberOfLines = 1
                subtitle.lineBreakMode = .byTruncatingMiddle
                var content: [NSView] = [row, subtitle]
                if repository.pricedTokens > 0 { content.append(AnalyticsBar(fraction: repository.costUSD / max(0.01, maximum))) }
                let group = vertical(content, spacing: 5)
                group.toolTip = (repository.path ?? "No working directory in the local log") + "\n\(exactTokens(repository.tokens)) tokens · \(exactTokens(repository.unpricedTokens)) unpriced"
                add(group, bottom: 16)
            }
            if analytics.repositories.count > 8 {
                let title = showAllRepositories ? "Show fewer" : "Show all \(analytics.repositories.count) repositories"
                add(instrumentButton(title, target: self, action: #selector(toggleRepositories)), bottom: 14)
            }
            let note = textLabel("Estimates exclude cache-write charges, long-context uplifts, tools and speed tiers.", size: 10, color: UsagePalette.secondary)
            note.toolTip = pricingExplanation
            add(note, bottom: 10)
        }
    }

    private var pricingExplanation: String {
        "\(ModelPricing.basis), checked \(ModelPricing.checkedAt). Cached input is priced separately and counted once. Unknown model prices are excluded from dollars. Excludes cache writes, long-context uplifts, tool charges and speed tiers; actual API costs may be higher. \(ModelPricing.sourceURL)"
    }

    private func addAllowance(_ window: UsageWindow) {
        let expired = window.resetsAt.map { $0.isFinite && $0 <= Date().timeIntervalSince1970 } ?? false
        let label = caption("\(window.label) \(expired ? "last known" : "remaining")")
        let number = window.remainingPercent.map { String(Int($0.rounded())) } ?? "—"
        let headline = textLabel("", size: 54, weight: .medium)
        let value = NSMutableAttributedString(string: number, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 54, weight: .medium), .foregroundColor: UsagePalette.ink])
        if window.remainingPercent != nil { value.append(NSAttributedString(string: "%", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 27, weight: .medium), .foregroundColor: UsagePalette.secondary])) }
        headline.attributedStringValue = value
        add(vertical([label, headline, RemainingBar(window.remainingPercent), resetRow(window)], spacing: 8), bottom: 18)
    }

    private func resetRow(_ window: UsageWindow) -> NSView {
        guard let timestamp = window.resetsAt, timestamp.isFinite else { return textLabel("Reset time unavailable", size: 11, color: UsagePalette.secondary) }
        let date = Date(timeIntervalSince1970: timestamp)
        if date <= Date() { return textLabel("Reset due · checking for an update", size: 11, color: UsagePalette.secondary) }
        let row = horizontal([textLabel("Resets \(formatDate(date, "EEE, MMM d"))", size: 11, color: UsagePalette.secondary), NSView(),
            textLabel(UsageTimelineView.clockTime(date), size: 11, color: UsagePalette.secondary)])
        row.toolTip = "\(UsageTimelineView.fullDate(date)) · \(TimeZone.current.identifier)"
        return row
    }

    private func makeScenarios(_ forecast: UsageForecast?, _ rates: [ModelUsageRate]) -> [TimelineScenario] {
        var scenarios: [TimelineScenario] = []
        if let hours = forecast?.overallHours { scenarios.append(TimelineScenario(id: "account", label: "Recent account pace", hours: hours)) }
        scenarios += rates.map { rate in TimelineScenario(id: rate.model, label: rate.model, hours: forecast?.models.first(where: { $0.model == rate.model })?.hours) }
        return scenarios
    }

    private func addRunway(_ owner: UsageApp, selected: TimelineScenario?) {
        let end = selected?.hours.flatMap { hours -> Date? in
            guard hours.isFinite, hours >= 0, let date = owner.snapshot?.fetchedAt else { return nil }
            return date.addingTimeInterval(hours * 3600)
        }
        let shortName = selected?.id.split(separator: "-").last.map { String($0).capitalized } ?? "model"
        let title = selected?.id == "account" ? "At your recent account pace" : "At your recent \(shortName) pace"
        let caption: String
        if end != nil { caption = "Estimated elapsed runway" }
        else if owner.isReadingHistory { caption = "Reading recent model activity…" }
        else { caption = "Runway estimate unavailable" }
        var value = "—"
        if let end {
            let hours = max(0, end.timeIntervalSinceNow / 3600)
            value = "≈" + (hours >= 1 && hours < 48 ? "\(Int(hours.rounded()))h" : runwayTime(hours))
        }
        let amount = textLabel(value, size: 23, weight: .medium)
        amount.font = .monospacedSystemFont(ofSize: 23, weight: .medium)
        amount.setContentHuggingPriority(.required, for: .horizontal)
        amount.setContentCompressionResistancePriority(.required, for: .horizontal)
        let summary = vertical([textLabel(selected == nil ? "Usage runway" : title, size: 12), textLabel(caption, size: 10, color: UsagePalette.secondary)], spacing: 4)
        summary.toolTip = selected?.label
        add(horizontal([summary, NSView(), amount]), bottom: 13)
        if let reset = owner.timelineResetDate {
            add(UsageTimelineView(now: Date(), reset: reset, estimatedEnd: end), bottom: 13)
            if let end, end >= reset {
                add(textLabel("Reset comes first. End assumes no refill.", size: 11, color: UsagePalette.secondary), bottom: 14)
            } else if let end, end <= Date() {
                add(textLabel("Estimated limit reached. Refresh for the latest allowance.", size: 11, color: UsagePalette.secondary), bottom: 14)
            }
        } else { add(textLabel("A fresh allowance reading is needed for the timeline.", size: 11, color: UsagePalette.secondary), bottom: 18) }
    }

    private func addDetails(_ owner: UsageApp, forecast: UsageForecast?, rates: [ModelUsageRate], scenarios: [TimelineScenario], selected: TimelineScenario?) {
        if scenarios.count > 1 {
            let picker = NSPopUpButton(frame: .zero, pullsDown: false)
            picker.font = .systemFont(ofSize: 11)
            picker.target = owner
            picker.action = #selector(UsageApp.selectTimeline(_:))
            picker.setAccessibilityLabel("Timeline usage scenario")
            for scenario in scenarios {
                picker.addItem(withTitle: scenario.label + (scenario.hours == nil ? " · no runway estimate" : ""))
                picker.lastItem?.representedObject = scenario.id
            }
            if let index = scenarios.firstIndex(where: { $0.id == selected?.id }) { picker.selectItem(at: index) }
            add(picker, bottom: 12)
        }
        let days = (rates.first?.elapsedHours ?? 168) / 24
        let period = abs(days - 7) < 0.01 ? "7-day" : String(format: "%.1f-day", days)
        add(textLabel("\(period) average · includes idle time and concurrent runs", size: 11, color: UsagePalette.secondary), bottom: 10)
        if !rates.isEmpty, let history = owner.history,
           owner.historyErrorText != nil || Date().timeIntervalSince(history.scannedAt) > 900 {
            let reason = owner.historyErrorText ?? "Local history is awaiting an update."
            add(textLabel("\(reason)\nShowing history last read \(formatDate(history.scannedAt, "EEE, h:mm a")).", size: 11, color: UsagePalette.secondary), bottom: 10)
        }
        for rate in rates {
            let pace = textLabel("\(compactTokens(rate.tokensPerHour)) / h", size: 12, weight: .medium)
            pace.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            pace.setContentHuggingPriority(.required, for: .horizontal)
            pace.setContentCompressionResistancePriority(.required, for: .horizontal)
            let row = horizontal([textLabel(rate.model, size: 12), NSView(), pace])
            row.toolTip = "\(compactTokens(rate.tokensPerDay)) tokens/day · \(compactTokens(rate.totalTokens)) total"
            add(row, bottom: 8)
        }
        if rates.isEmpty { add(textLabel(owner.isReadingHistory ? "Reading local token history…" : owner.historyErrorText ?? "No recent local token activity found.", size: 11, color: UsagePalette.secondary), bottom: 12) }
        if let model = forecast?.models.first(where: { $0.model == selected?.id }), let low = model.lowerHours, let high = model.upperHours, let tokens = model.remainingTokens {
            let elapsed = max(0, Date().timeIntervalSince(owner.snapshot?.fetchedAt ?? Date()) / 3600)
            add(textLabel("Selected scenario: ≈\(compactTokens(tokens)) tokens left\nObserved range: \(runwayTime(max(0, low - elapsed)))–\(runwayTime(max(0, high - elapsed))) at isolated model pace", size: 11, color: UsagePalette.secondary), top: 4, bottom: 10)
        } else if selected?.hours == nil && !rates.isEmpty {
            let reason: String
            if owner.isReadingHistory { reason = "Updating local history for the runway estimate…" }
            else if owner.snapshot?.ordinaryUsageAllowed == false { reason = "Runway is unavailable while account usage is restricted." }
            else if owner.errorText != nil || owner.timelineResetDate == nil { reason = "A fresh allowance reading with a future reset is needed for runway." }
            else if owner.historyErrorText != nil { reason = "Refresh local history to restore the runway estimate." }
            else if let history = owner.history, Date().timeIntervalSince(history.scannedAt) > 900 { reason = "Local history needs an update before estimating runway." }
            else if owner.history?.warning != nil { reason = "Incomplete local history prevents reliable model attribution." }
            else if forecast != nil { reason = "Runway needs enough isolated usage to separate this model’s allowance use." }
            else { reason = "The current allowance and history do not support a runway estimate." }
            add(textLabel(reason, size: 11, color: UsagePalette.secondary), bottom: 10)
        }
        add(textLabel("Runway is elapsed time at the sampled pace, not continuous generation. Local logs may miss other account activity.", size: 11, color: UsagePalette.secondary), bottom: 14)
        if let warning = owner.history?.warning { add(textLabel(warning, size: 11, color: UsagePalette.secondary), bottom: 14) }
    }

    private func freshness(_ owner: UsageApp) -> String {
        if owner.isRefreshing { return "Refreshing…" }
        if let date = owner.snapshot?.fetchedAt { return "\(owner.errorText == nil ? "Updated" : "Last successful update") \(formatDate(date, "EEE, h:mm a")) · refreshes every 5 min" }
        return "Refreshes automatically every 5 minutes"
    }

    private func addSettings(_ owner: UsageApp) {
        add(separator(), bottom: 14)
        add(textLabel(freshness(owner), size: 11, color: UsagePalette.secondary), bottom: 10)
        let refresh = instrumentButton("Refresh now", target: owner, action: #selector(UsageApp.refreshNow))
        refresh.isEnabled = !owner.isRefreshing
        let open = instrumentButton("Open Codex", target: owner, action: #selector(UsageApp.openCodex))
        add(horizontal([refresh, open]), bottom: 12)
        let launch = NSButton(checkboxWithTitle: "Launch at login", target: owner, action: #selector(UsageApp.toggleLogin))
        launch.font = .systemFont(ofSize: 11)
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let quit = instrumentButton("Quit", target: owner, action: #selector(UsageApp.quit))
        add(horizontal([launch, NSView(), quit]), bottom: 10)
        if SMAppService.mainApp.status == .requiresApproval {
            let allow = instrumentButton("Allow in Login Items…", target: owner, action: #selector(UsageApp.openLoginSettings))
            add(allow, bottom: 10)
        }
        add(textLabel("Codex allowance · \(TimeZone.current.identifier)", size: 11, color: UsagePalette.secondary), bottom: 16)
    }

    @objc private func toggleDetails() {
        detailsExpanded.toggle()
        UserDefaults.standard.set(detailsExpanded, forKey: "ModelDetailsExpanded")
        owner?.updateUI()
    }
    @objc private func toggleSettings() { settingsExpanded.toggle(); owner?.updateUI() }
}
