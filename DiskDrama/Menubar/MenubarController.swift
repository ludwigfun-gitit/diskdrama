import AppKit

/// The ambient monitor: status item, its dropdown, and the poll that keeps them
/// current. Carried over from v0 (F01–F04), reshaped so the dropdown can grow
/// into the design handoff's popover in Step 13 without the polling and
/// formatting logic having to move again.
///
/// Deliberately AppKit. `NSStatusItem` is an AppKit object, the app is menubar-
/// resident, and SwiftUI's `MenuBarExtra` does not model the popover the handoff
/// specifies. AppKit owns the lifecycle here; SwiftUI is hosted inside it later.
@MainActor
final class MenubarController {

    private var statusItem: NSStatusItem?

    /// The volume poll. Owned by the app, not by this controller — the sidebar
    /// shows the same figure and the two must not drift apart (Step 6).
    private let monitor: DiskMonitor

    /// Menu items whose titles change on refresh, held directly rather than
    /// looked up by index. v0 addressed them via an index enum with a comment
    /// mapping positions to meanings — correct until the day someone inserts a
    /// separator, at which point it silently writes the free-space figure into
    /// the wrong row. References cannot drift.
    private var freeItem: NSMenuItem?
    private var usedItem: NSMenuItem?
    private var totalItem: NSMenuItem?
    private var usageItem: NSMenuItem?
    private var checkedItem: NSMenuItem?

    private let settings = Settings.shared

    /// Invoked by "Scan Now" (F02). Injected rather than reached for, so the
    /// menubar stays a view of state it does not own.
    var onScanRequested: (() -> Void)?

    /// F07's stop. Falls through to `ScanEngine.abandon()` when the walk is
    /// wedged in an uninterruptible filesystem call and cannot be asked politely.
    var onScanStopRequested: (() -> Void)?

    /// Summons the main window (A09 — the main surface, of which this dropdown
    /// is the gateway).
    var onOpenWindowRequested: (() -> Void)?

    init(monitor: DiskMonitor) {
        self.monitor = monitor
    }

    /// The scan progress row, hidden while idle.
    private var scanItem: NSMenuItem?
    private var stopItem: NSMenuItem?

    // MARK: - Lifecycle

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = buildMenu()
        statusItem = item

        monitor.onChange = { [weak self] in self?.render() }
        render()
    }

    func stop() {
        monitor.onChange = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    // MARK: - Menu construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(disabled("Macintosh HD — Free Space"))
        menu.addItem(.separator())

        freeItem  = disabled("Free:  —")
        usedItem  = disabled("Used:  —")
        totalItem = disabled("Total: —")
        usageItem = disabled("Usage: —")
        [freeItem, usedItem, totalItem, usageItem].compactMap { $0 }.forEach(menu.addItem)

        menu.addItem(.separator())
        checkedItem = disabled("Last checked: —")
        menu.addItem(checkedItem!)

        menu.addItem(.separator())
        menu.addItem(action("Open DiskDrama", #selector(openWindow), key: "o"))
        menu.addItem(action("Scan Now", #selector(scanNow), key: "s"))
        scanItem = disabled("")
        scanItem?.isHidden = true
        menu.addItem(scanItem!)
        stopItem = action("Stop Scan", #selector(stopScan), key: ".")
        stopItem?.isHidden = true
        menu.addItem(stopItem!)

        menu.addItem(.separator())
        menu.addItem(action("Refresh Now", #selector(refreshFromMenu), key: "r"))
        menu.addItem(action("Open Storage Settings…", #selector(openStorageSettings), key: ""))

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit DiskDrama",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Refresh

    @objc private func refreshFromMenu() { monitor.refresh() }

    private func render() {
        guard let info = monitor.info else {
            renderUnreadable()
            return
        }
        let free = info.availableBytes

        if let button = statusItem?.button {
            let icon = free < settings.criticalThresholdBytes ? "⛔️"
                     : free < settings.lowThresholdBytes    ? "⚠️" : "💾"
            button.title = "\(icon) \(ByteFormat.compact(free))"
            button.toolTip = "Free: \(ByteFormat.compact(free)) of \(ByteFormat.compact(info.totalBytes))"
        }

        freeItem?.attributedTitle = freeTitle(for: info)
        usedItem?.title  = "Used:  \(ByteFormat.compact(info.usedBytes))"
        totalItem?.title = "Total: \(ByteFormat.compact(info.totalBytes))"
        usageItem?.title = String(format: "Usage: %.1f%%", info.usedFraction * 100)

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        checkedItem?.title = "Last checked: \(formatter.string(from: info.readAt))"
    }

    /// The free row carries the state color, so it is always an attributed title —
    /// including in the normal case. v0 set `attributedTitle` when low and reset it
    /// to `nil` otherwise, which left the plain `title` and the attributed one as
    /// two sources of truth for the same row.
    private func freeTitle(for info: DiskInfo) -> NSAttributedString {
        let free = info.availableBytes
        let color: NSColor = free < settings.criticalThresholdBytes ? .systemRed
                           : free < settings.lowThresholdBytes    ? .systemOrange
                           : .labelColor
        return NSAttributedString(string: "Free:  \(ByteFormat.compact(free))",
                                  attributes: [.foregroundColor: color])
    }

    /// F01's failure case: volume unreadable → show `—` and say why in the tooltip,
    /// never a stale number presented as current.
    private func renderUnreadable() {
        if let button = statusItem?.button {
            button.title = "💾 —"
            button.toolTip = "DiskDrama can't read the boot volume right now."
        }
        freeItem?.attributedTitle = NSAttributedString(
            string: "Free:  —", attributes: [.foregroundColor: NSColor.labelColor])
        usedItem?.title  = "Used:  —"
        totalItem?.title = "Total: —"
        usageItem?.title = "Usage: —"
        checkedItem?.title = "Last checked: failed"
    }

    // MARK: - Scan status

    /// Reflects scan state in the dropdown. Called from the scan engine's
    /// observation, not polled.
    func showScanStatus(_ text: String?, canStop: Bool = false) {
        scanItem?.isHidden = (text == nil)
        scanItem?.title = text ?? ""
        stopItem?.isHidden = !canStop
    }

    // MARK: - Actions

    @objc private func openWindow() {
        onOpenWindowRequested?()
    }

    @objc private func scanNow() {
        onScanRequested?()
    }

    @objc private func stopScan() {
        onScanStopRequested?()
    }

    @objc private func openStorageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") else { return }
        NSWorkspace.shared.open(url)
    }
}
