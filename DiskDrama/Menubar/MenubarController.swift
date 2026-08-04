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
    private var headlineItem: NSMenuItem?
    private var capacityItem: NSMenuItem?
    private var checkedItem: NSMenuItem?
    private var reclaimableItem: NSMenuItem?
    private var reclaimableDetailItem: NSMenuItem?

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

    /// Opens Settings straight from the dropdown.
    var onSettingsRequested: (() -> Void)?

    /// The advisor's headline, supplied by whoever owns the scan results — the
    /// menubar renders it but does not go looking for it.
    var reclaimableSummary: (bytes: Int64, detail: String)?

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

    /// Builds the dropdown to the handoff's screen 3b.
    ///
    /// Still an `NSMenu` rather than a SwiftUI popover: this is the surface the
    /// user hits far more often than the window, and a native menu costs
    /// nothing to open, dismisses correctly, and inherits every keyboard and
    /// accessibility behaviour macOS provides. The handoff's popover styling is
    /// reproduced where a menu can carry it — a headline free-space figure, a
    /// capacity bar, freshness, and the reclaimable callout — rather than
    /// rebuilding menu behaviour from scratch to match a mockup.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        headlineItem = disabled("")
        headlineItem?.attributedTitle = NSAttributedString(string: "—")
        menu.addItem(headlineItem!)

        capacityItem = disabled("")
        menu.addItem(capacityItem!)

        checkedItem = disabled("")
        menu.addItem(checkedItem!)

        menu.addItem(.separator())

        // The reclaimable line is the whole reason this dropdown is more than a
        // gauge — it is the advisor speaking from the ambient surface.
        reclaimableItem = disabled("")
        menu.addItem(reclaimableItem!)
        reclaimableDetailItem = disabled("")
        menu.addItem(reclaimableDetailItem!)

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
        menu.addItem(action("Refresh", #selector(refreshFromMenu), key: "r"))
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(action("Open Storage Settings…", #selector(openStorageSettings), key: ""))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DiskDrama",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    /// The status item's glyph, built once and reused — `render()` runs on every
    /// poll, and rebuilding an `NSImage` on each one to hand back an identical
    /// picture is pure waste.
    ///
    /// Template rendering is what makes this correct in both appearances: AppKit
    /// draws a template image using the menu bar's own foreground colour, so a
    /// light and a dark menu bar are handled without the app knowing which it is
    /// on. That is also why the emoji it replaces had to go — emoji carry their
    /// own colour and ignore appearance entirely.
    private static let statusIcon: NSImage? = {
        let image = NSImage(systemSymbolName: "internaldrive.fill",
                            accessibilityDescription: "Disk space")
        image?.isTemplate = true
        return image
    }()

    private func applyStatusIcon(to button: NSStatusBarButton) {
        button.image = Self.statusIcon
        // Both the glyph and the byte count are shown, so the position has to be
        // stated rather than inherited.
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
    }

    /// A text capacity bar. A menu item cannot host an arbitrary view cheaply,
    /// and a monospaced block gauge reads accurately at a glance without one.
    private func capacityBar(_ fraction: Double) -> String {
        let width = 18
        let filled = Int((fraction * Double(width)).rounded())
        return String(repeating: "▓", count: max(0, min(width, filled)))
            + String(repeating: "░", count: max(0, width - filled))
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

    /// Re-renders without re-reading the volume — for when the *advisor* half
    /// changed rather than the disk.
    func refreshDisplay() { render() }

    private func render() {
        guard let info = monitor.info else {
            renderUnreadable()
            return
        }
        let free = info.availableBytes

        if let button = statusItem?.button {
            applyStatusIcon(to: button)
            // The state signal moved from the glyph itself to its tint. A
            // template image takes the tint colour when one is set and follows
            // the menu bar's own appearance when it is nil, so "normal" needs
            // no colour of its own — which is the point, since a permanently
            // coloured menu bar icon stops reading as a warning.
            button.contentTintColor = free < settings.criticalThresholdBytes ? .systemRed
                                    : free < settings.lowThresholdBytes    ? .systemOrange
                                    : nil
            button.title = ByteFormat.compact(free)
            button.toolTip = "Free: \(ByteFormat.compact(free)) of \(ByteFormat.compact(info.totalBytes))"
        }

        headlineItem?.attributedTitle = headline(for: info)
        capacityItem?.attributedTitle = NSAttributedString(
            string: capacityBar(info.usedFraction),
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor])

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        checkedItem?.attributedTitle = NSAttributedString(
            string: "\(ByteFormat.compact(info.usedBytes)) used · \(Int(info.usedFraction * 100))% · checked \(formatter.string(from: info.readAt))",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                         .foregroundColor: NSColor.tertiaryLabelColor])

        renderReclaimable()
    }

    /// The advisor's line in the ambient surface. Hidden entirely when there is
    /// nothing to say — an empty "0 GB reclaimable" row is worse than no row.
    private func renderReclaimable() {
        guard let summary = reclaimableSummary, summary.bytes > 0 else {
            reclaimableItem?.isHidden = true
            reclaimableDetailItem?.isHidden = true
            return
        }
        reclaimableItem?.isHidden = false
        reclaimableDetailItem?.isHidden = false
        reclaimableItem?.attributedTitle = NSAttributedString(
            string: "\(ByteFormat.compact(summary.bytes)) reclaimable",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                         .foregroundColor: NSColor.controlAccentColor])
        reclaimableDetailItem?.attributedTitle = NSAttributedString(
            string: summary.detail,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor])
    }

    private func headline(for info: DiskInfo) -> NSAttributedString {
        let free = info.availableBytes
        let color: NSColor = free < settings.criticalThresholdBytes ? .systemRed
                           : free < settings.lowThresholdBytes    ? .systemOrange
                           : .labelColor
        let text = NSMutableAttributedString(
            string: ByteFormat.compact(free),
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 17, weight: .semibold),
                         .foregroundColor: color])
        text.append(NSAttributedString(
            string: "  free of \(ByteFormat.compact(info.totalBytes))",
            attributes: [.font: NSFont.systemFont(ofSize: 11.5),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }

    /// F01's failure case: volume unreadable → show `—` and say why in the tooltip,
    /// never a stale number presented as current.
    private func renderUnreadable() {
        if let button = statusItem?.button {
            applyStatusIcon(to: button)
            // No threshold to signal — an unreadable volume is not a "you are
            // running out" state, and colouring it red would say something the
            // app does not know.
            button.contentTintColor = nil
            button.title = "—"
            button.toolTip = "DiskDrama can't read the boot volume right now."
        }
        headlineItem?.attributedTitle = NSAttributedString(
            string: "—", attributes: [.foregroundColor: NSColor.labelColor])
        capacityItem?.attributedTitle = NSAttributedString(string: "")
        checkedItem?.attributedTitle = NSAttributedString(string: "Couldn't read the volume")
        reclaimableItem?.isHidden = true
        reclaimableDetailItem?.isHidden = true
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

    @objc private func openSettings() {
        onSettingsRequested?()
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
