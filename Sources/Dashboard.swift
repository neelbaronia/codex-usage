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
                       color: NSColor = .labelColor) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.isSelectable = false
    label.setContentCompressionResistancePriority(.required, for: .vertical)
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

private func separator() -> NSBox {
    let view = NSBox()
    view.boxType = .separator
    return view
}

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
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        updateColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }
    private func updateColor() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.15, green: 0.153, blue: 0.169, alpha: 1)
            : NSColor(srgbRed: 0.973, green: 0.973, blue: 0.98, alpha: 1)).cgColor
    }
}

private final class RemainingBar: NSView {
    let remaining: Double?
    init(_ value: Double?) {
        remaining = value
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 5).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Remaining allowance")
        setAccessibilityValue(value.map { "\(Int($0.rounded())) percent" } ?? "Unknown")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2.5, yRadius: 2.5).fill()
        guard let remaining, remaining > 0 else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let green = dark ? NSColor(srgbRed: 0.45, green: 0.81, blue: 0.68, alpha: 1)
            : NSColor(srgbRed: 0.157, green: 0.525, blue: 0.404, alpha: 1)
        (remaining <= 10 ? NSColor.systemRed : remaining <= 25 ? .systemOrange : green).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * remaining / 100,
            height: bounds.height), xRadius: 2.5, yRadius: 2.5).fill()
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class DashboardController: NSViewController {
    weak var owner: UsageApp?
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var detailsExpanded = UserDefaults.standard.bool(forKey: "ModelDetailsExpanded")
    private var settingsExpanded = false

    override func loadView() {
        let surface = DashboardSurface(frame: NSRect(x: 0, y: 0, width: 350, height: 450))
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
        stack.addArrangedSubview(wrapper)
        NSLayoutConstraint.activate([
            wrapper.widthAnchor.constraint(equalTo: stack.widthAnchor),
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: top),
            content.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -bottom)
        ])
    }

    func render() {
        _ = view
        guard let owner else { return }
        let oldOrigin = scroll.contentView.bounds.origin
        for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
        let plan = owner.snapshot?.buckets.compactMap(\.planType).first?.capitalized ?? "Account"
        let mark = NSImageView()
        mark.image = UsageBrand.logo(size: 18) ?? NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)
        mark.contentTintColor = .labelColor
        mark.widthAnchor.constraint(equalToConstant: 18).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let title = textLabel("Codex Usage", size: 13, weight: .semibold)
        add(horizontal([mark, title, NSView(), textLabel(plan, size: 11, color: .secondaryLabelColor)]), top: 20, bottom: 22)

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
                add(textLabel("Account usage is currently restricted.", size: 12, color: .systemOrange), bottom: 16)
            }
        } else {
            add(vertical([textLabel(owner.isRefreshing ? "Checking your allowance…" : "Usage unavailable", size: 20, weight: .medium),
                textLabel("Uses the account already signed in to Codex.", size: 12, color: .secondaryLabelColor)]), bottom: 22)
        }

        if let error = owner.errorText { add(textLabel(error, size: 11, color: .systemOrange), bottom: 16) }
        if let error = owner.actionErrorText { add(textLabel(error, size: 11, color: .systemOrange), bottom: 16) }
        if let snapshot = owner.snapshot, !owner.isRefreshing, Date().timeIntervalSince(snapshot.fetchedAt) > 600 || owner.errorText != nil {
            add(textLabel("Last successful update \(formatDate(snapshot.fetchedAt, "EEE, h:mm a"))", size: 11, color: .secondaryLabelColor), bottom: 12)
        }

        let forecast = owner.forecast
        let rates = owner.history.map { ModelUsageRates.calculate(history: $0) } ?? []
        let scenarios = makeScenarios(forecast, rates)
        let selected = scenarios.first(where: { $0.id == owner.selectedTimelineID }) ?? scenarios.first(where: { $0.hours != nil }) ?? scenarios.first
        add(separator(), bottom: 19)
        addRunway(owner, selected: selected)
        add(separator(), inset: 0)
        let disclosure = NSButton(title: "Model token rates", target: self, action: #selector(toggleDetails))
        disclosure.isBordered = false
        disclosure.alignment = .left
        disclosure.font = .systemFont(ofSize: 12)
        disclosure.image = NSImage(systemSymbolName: detailsExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        disclosure.imagePosition = .imageTrailing
        disclosure.setAccessibilityLabel("Model token rates")
        disclosure.setAccessibilityValue(detailsExpanded ? "Expanded" : "Collapsed")
        add(disclosure, top: 12, bottom: 12)
        if detailsExpanded { addDetails(owner, forecast: forecast, rates: rates, scenarios: scenarios, selected: selected) }
        add(separator(), inset: 0)

        let footerText: String
        if let count = owner.snapshot?.availableResets, count > 0 { footerText = "\(count) full reset\(count == 1 ? "" : "s") available" }
        else if owner.isRefreshing { footerText = "Refreshing…" }
        else if let date = owner.snapshot?.fetchedAt { footerText = "Updated \(formatDate(date, "h:mm a"))" }
        else { footerText = "Codex account allowance" }
        let footer = textLabel(footerText, size: 11, color: .secondaryLabelColor)
        footer.toolTip = freshness(owner)
        let settings = NSButton(title: "Settings", target: self, action: #selector(toggleSettings))
        settings.bezelStyle = .inline
        settings.font = .systemFont(ofSize: 11)
        settings.setAccessibilityValue(settingsExpanded ? "Expanded" : "Collapsed")
        add(horizontal([footer, NSView(), settings]), top: 10, bottom: 12)
        if settingsExpanded { addSettings(owner) }

        view.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height)
        document.setFrameSize(NSSize(width: 350, height: height))
        let availableHeight = max(200, ((view.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 700) - 60)
        preferredContentSize = NSSize(width: 350, height: min(height, availableHeight))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(oldOrigin.y, max(0, height - preferredContentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func addAllowance(_ window: UsageWindow) {
        let expired = window.resetsAt.map { $0.isFinite && $0 <= Date().timeIntervalSince1970 } ?? false
        let label = textLabel("\(window.label) \(expired ? "last known" : "remaining")", size: 11, color: .secondaryLabelColor)
        let number = window.remainingPercent.map { String(Int($0.rounded())) } ?? "—"
        let headline = textLabel("", size: 49, weight: .medium)
        let value = NSMutableAttributedString(string: number, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 49, weight: .medium), .foregroundColor: NSColor.labelColor])
        if window.remainingPercent != nil { value.append(NSAttributedString(string: "%", attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])) }
        headline.attributedStringValue = value
        add(vertical([label, headline, RemainingBar(window.remainingPercent), resetRow(window)], spacing: 8), bottom: 20)
    }

    private func resetRow(_ window: UsageWindow) -> NSView {
        guard let timestamp = window.resetsAt, timestamp.isFinite else { return textLabel("Reset time unavailable", size: 11, color: .secondaryLabelColor) }
        let date = Date(timeIntervalSince1970: timestamp)
        if date <= Date() { return textLabel("Reset due · checking for an update", size: 11, color: .secondaryLabelColor) }
        let row = horizontal([textLabel("Resets \(formatDate(date, "EEE, MMM d"))", size: 11, color: .secondaryLabelColor), NSView(),
            textLabel(formatDate(date, "h:mm a"), size: 11, color: .secondaryLabelColor)])
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
        amount.setContentHuggingPriority(.required, for: .horizontal)
        amount.setContentCompressionResistancePriority(.required, for: .horizontal)
        let summary = vertical([textLabel(selected == nil ? "Usage runway" : title, size: 13), textLabel(caption, size: 11, color: .secondaryLabelColor)], spacing: 4)
        summary.toolTip = selected?.label
        add(horizontal([summary, NSView(), amount]), bottom: 13)
        if let reset = owner.timelineResetDate {
            add(UsageTimelineView(now: Date(), reset: reset, estimatedEnd: end), bottom: 13)
            if let end, end >= reset {
                add(textLabel("Reset comes first. End assumes no refill.", size: 11, color: .secondaryLabelColor), bottom: 14)
            } else if let end, end <= Date() {
                add(textLabel("Estimated limit reached. Refresh for the latest allowance.", size: 11, color: .secondaryLabelColor), bottom: 14)
            }
        } else { add(textLabel("A fresh allowance reading is needed for the timeline.", size: 11, color: .secondaryLabelColor), bottom: 18) }
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
        add(textLabel("\(period) average · includes idle time and concurrent runs", size: 11, color: .secondaryLabelColor), bottom: 10)
        if !rates.isEmpty, let history = owner.history,
           owner.historyErrorText != nil || Date().timeIntervalSince(history.scannedAt) > 900 {
            let reason = owner.historyErrorText ?? "Local history is awaiting an update."
            add(textLabel("\(reason)\nShowing history last read \(formatDate(history.scannedAt, "EEE, h:mm a")).", size: 11, color: .secondaryLabelColor), bottom: 10)
        }
        for rate in rates {
            let pace = textLabel("\(compactTokens(rate.tokensPerHour)) / h", size: 12, weight: .medium)
            pace.setContentHuggingPriority(.required, for: .horizontal)
            pace.setContentCompressionResistancePriority(.required, for: .horizontal)
            let row = horizontal([textLabel(rate.model, size: 12), NSView(), pace])
            row.toolTip = "\(compactTokens(rate.tokensPerDay)) tokens/day · \(compactTokens(rate.totalTokens)) total"
            add(row, bottom: 8)
        }
        if rates.isEmpty { add(textLabel(owner.isReadingHistory ? "Reading local token history…" : owner.historyErrorText ?? "No recent local token activity found.", size: 11, color: .secondaryLabelColor), bottom: 12) }
        if let model = forecast?.models.first(where: { $0.model == selected?.id }), let low = model.lowerHours, let high = model.upperHours, let tokens = model.remainingTokens {
            let elapsed = max(0, Date().timeIntervalSince(owner.snapshot?.fetchedAt ?? Date()) / 3600)
            add(textLabel("Selected scenario: ≈\(compactTokens(tokens)) tokens left\nObserved range: \(runwayTime(max(0, low - elapsed)))–\(runwayTime(max(0, high - elapsed))) at isolated model pace", size: 11, color: .secondaryLabelColor), top: 4, bottom: 10)
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
            add(textLabel(reason, size: 11, color: .secondaryLabelColor), bottom: 10)
        }
        add(textLabel("Runway is elapsed time at the sampled pace, not continuous generation. Local logs may miss other account activity.", size: 11, color: .secondaryLabelColor), bottom: 14)
        if let warning = owner.history?.warning { add(textLabel(warning, size: 11, color: .secondaryLabelColor), bottom: 14) }
    }

    private func freshness(_ owner: UsageApp) -> String {
        if owner.isRefreshing { return "Refreshing…" }
        if let date = owner.snapshot?.fetchedAt { return "\(owner.errorText == nil ? "Updated" : "Last successful update") \(formatDate(date, "EEE, h:mm a")) · refreshes every 5 min" }
        return "Refreshes automatically every 5 minutes"
    }

    private func addSettings(_ owner: UsageApp) {
        add(separator(), bottom: 14)
        add(textLabel(freshness(owner), size: 11, color: .secondaryLabelColor), bottom: 10)
        let refresh = NSButton(title: "Refresh now", target: owner, action: #selector(UsageApp.refreshNow))
        refresh.bezelStyle = .rounded
        refresh.isEnabled = !owner.isRefreshing
        let open = NSButton(title: "Open Codex", target: owner, action: #selector(UsageApp.openCodex))
        open.bezelStyle = .rounded
        add(horizontal([refresh, open]), bottom: 12)
        let launch = NSButton(checkboxWithTitle: "Launch at login", target: owner, action: #selector(UsageApp.toggleLogin))
        launch.font = .systemFont(ofSize: 11)
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let quit = NSButton(title: "Quit", target: owner, action: #selector(UsageApp.quit))
        quit.bezelStyle = .inline
        quit.font = .systemFont(ofSize: 11)
        add(horizontal([launch, NSView(), quit]), bottom: 10)
        if SMAppService.mainApp.status == .requiresApproval {
            let allow = NSButton(title: "Allow in Login Items…", target: owner, action: #selector(UsageApp.openLoginSettings))
            allow.bezelStyle = .inline
            add(allow, bottom: 10)
        }
        add(textLabel("Codex allowance · \(TimeZone.current.identifier)", size: 11, color: .secondaryLabelColor), bottom: 16)
    }

    @objc private func toggleDetails() {
        detailsExpanded.toggle()
        UserDefaults.standard.set(detailsExpanded, forKey: "ModelDetailsExpanded")
        owner?.updateUI()
    }
    @objc private func toggleSettings() { settingsExpanded.toggle(); owner?.updateUI() }
}
