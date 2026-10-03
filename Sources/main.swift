import AppKit
import ServiceManagement

private let bundleIdentifier = "com.nbaronia.codex-usage"

final class UsageApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let dashboard = DashboardController()
    private let provider = UsageProvider()
    private let historyReader = LocalUsageHistoryReader()
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    var snapshot: UsageSnapshot?
    var errorText: String?
    var actionErrorText: String?
    var isRefreshing = false
    var history: LocalUsageHistory?
    var historyErrorText: String?
    var isReadingHistory = false
    var selectedTimelineID: String?
    var timelineResetDate: Date? {
        guard errorText == nil, let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) <= 600,
              snapshot.ordinaryUsageAllowed != false, let reset = statusWindow?.resetsAt,
              reset.isFinite, reset > Date().timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: reset)
    }
    var forecast: UsageForecast? {
        guard errorText == nil, let snapshot, let history, let window = statusWindow,
              let bucket = snapshot.buckets.first(where: { $0.id == "codex" }) ?? snapshot.buckets.first else { return nil }
        return UsageForecaster.forecast(history: history, snapshot: snapshot, window: window,
                                        bucketID: bucket.id, planType: bucket.planType)
    }
    private var lastResetRefresh: TimeInterval = 0

    @objc func selectTimeline(_ sender: NSPopUpButton) {
        selectedTimelineID = sender.selectedItem?.representedObject as? String
        updateUI()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "CodexUsageStatus"
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("Codex usage remaining")
        }
        dashboard.owner = self
        popover.contentViewController = dashboard
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        updateUI()
        refreshNow()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refreshNow() }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.clockTick() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.refreshNow() }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
        if !UserDefaults.standard.bool(forKey: "HasLaunched") || UserDefaults.standard.string(forKey: "PresentedVersion") != version {
            UserDefaults.standard.set(true, forKey: "HasLaunched")
            UserDefaults.standard.set(version, forKey: "PresentedVersion")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showPopover() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    var statusWindow: UsageWindow? {
        guard let buckets = snapshot?.buckets else { return nil }
        let bucket = buckets.first(where: { $0.id == "codex" }) ?? buckets.first
        return [bucket?.primary, bucket?.secondary].compactMap { $0 }
            .filter { $0.remainingPercent != nil }.min { $0.remainingPercent! < $1.remainingPercent! }
    }

    func updateUI() {
        let remaining = statusWindow?.remainingPercent
        let resetPending = statusWindow?.resetsAt.map { $0.isFinite && $0 <= Date().timeIntervalSince1970 } ?? false
        let stale = errorText != nil || resetPending || (snapshot.map { Date().timeIntervalSince($0.fetchedAt) > 600 } ?? false)
        item.button?.title = remaining.map { " \(Int($0.rounded()))%\(stale ? "!" : "")" } ?? " —"
        let value = remaining.map { "\(Int($0.rounded()))%" } ?? "Unknown"
        let label = statusWindow.map(windowName) ?? "Account"
        item.button?.toolTip = "Codex · \(value) \(label.lowercased()) remaining\(resetPending ? " · reset pending" : stale ? " · update unavailable" : "")"
        if let forecast, let hours = forecast.overallHours, let snapshot, let reset = timelineResetDate {
            let end = snapshot.fetchedAt.addingTimeInterval(hours * 3600)
            let hoursLeft = max(0, end.timeIntervalSinceNow / 3600)
            item.button?.toolTip?.append(end >= reset ? " · likely to last until reset" : " · ~\(runwayTime(hoursLeft)) at recent pace")
        }
        item.button?.setAccessibilityValue("\(value) \(label.lowercased()) remaining\(stale ? ", stale" : "")")
        item.button?.image = statusIcon(remaining: remaining)
        dashboard.render()
        popover.contentSize = dashboard.preferredContentSize
    }

    private func clockTick() {
        let expired = snapshot?.buckets.flatMap { [$0.primary, $0.secondary].compactMap { $0?.resetsAt } }
            .filter { $0.isFinite && $0 <= Date().timeIntervalSince1970 && $0 > lastResetRefresh }.max()
        if let expired, !isRefreshing {
            lastResetRefresh = expired
            refreshNow()
        } else { updateUI() }
    }

    private func statusIcon(remaining: Double?) -> NSImage {
        let logo = UsageBrand.logo(size: 13)
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            let outline = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            outline.lineWidth = 1.5
            NSColor.black.withAlphaComponent(0.25).setStroke()
            outline.stroke()
            if let remaining, remaining > 0 {
                let arc = NSBezierPath()
                arc.lineWidth = 1.5
                arc.lineCapStyle = .round
                // Draw the remainder backward from noon so the consumed gap
                // advances clockwise as the allowance decreases.
                arc.appendArc(withCenter: NSPoint(x: 11, y: 11), radius: 9.5,
                              startAngle: 90, endAngle: 90 + remaining * 3.6, clockwise: false)
                NSColor.black.setStroke()
                arc.stroke()
            }
            if let logo {
                logo.draw(in: NSRect(x: 4.5, y: 4.5, width: 13, height: 13), from: .zero,
                          operation: .sourceOver, fraction: 1)
            } else {
                NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)?
                    .draw(in: NSRect(x: 5.5, y: 5.5, width: 11, height: 11))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = item?.button else { return }
        updateUI()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        if snapshot == nil || Date().timeIntervalSince(snapshot!.fetchedAt) > 60 { refreshNow() }
    }

    @objc func refreshNow() {
        guard !isRefreshing else { return }
        refreshHistory()
        isRefreshing = true
        updateUI()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.provider.fetch() }
            DispatchQueue.main.async {
                self.isRefreshing = false
                switch result {
                case .success(let snapshot): self.snapshot = snapshot; self.errorText = nil
                case .failure(let error): self.errorText = error.localizedDescription
                }
                self.updateUI()
            }
        }
    }

    private func refreshHistory() {
        guard !isReadingHistory else { return }
        isReadingHistory = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.historyReader.read() }
            DispatchQueue.main.async {
                self.isReadingHistory = false
                switch result {
                case .success(let history): self.history = history; self.historyErrorText = nil
                case .failure: self.historyErrorText = "Could not read local usage history. Allowance still refreshes normally."
                }
                self.updateUI()
            }
        }
    }

    @objc func openCodex() {
        actionErrorText = nil
        let roots = [URL(fileURLWithPath: "/Applications"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let candidates = ["Codex.app", "ChatGPT.app"].flatMap { name in
            roots.map { $0.appendingPathComponent(name).path }
        }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            actionErrorText = "Open Codex in your terminal to check your sign-in."
            updateUI()
            return
        }
        popover.performClose(nil)
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) { [weak self] _, error in
            if error != nil {
                DispatchQueue.main.async {
                    self?.actionErrorText = "Could not open Codex. Open it from Applications."
                    self?.showPopover()
                }
            }
        }
    }

    @objc func toggleLogin(_ sender: NSButton) {
        actionErrorText = nil
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            actionErrorText = "Could not change launch at login. Check System Settings → General → Login Items."
        }
        updateUI()
    }
    @objc func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        clockTimer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}

// Reopening the application reveals the existing widget instead of adding duplicates.
if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    existing.activate(options: [])
    exit(0)
}
let app = NSApplication.shared
private let delegate = UsageApp()
app.delegate = delegate
app.run()
