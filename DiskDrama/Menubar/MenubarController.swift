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
    /// The volume this menu was last drawn for, so the bar can be re-sized when
    /// only the reclaimable line changes and no new reading has arrived.
    private var lastRenderedInfo: DiskInfo?

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
        // Otherwise AppKit disables — and so dims — every item without an
        // action, which is all of the informational rows at the top.
        menu.autoenablesItems = false

        headlineItem = caption("")
        headlineItem?.attributedTitle = NSAttributedString(string: "—")
        menu.addItem(headlineItem!)

        capacityItem = caption("")
        let bar = CapacityBarView(frame: NSRect(x: 0, y: 0, width: 220, height: 16))
        bar.autoresizingMask = [.width]
        capacityItem?.view = bar
        menu.addItem(capacityItem!)

        checkedItem = caption("")
        menu.addItem(checkedItem!)

        menu.addItem(.separator())

        // The reclaimable line is the whole reason this dropdown is more than a
        // gauge — it is the advisor speaking from the ambient surface.
        reclaimableItem = caption("")
        menu.addItem(reclaimableItem!)
        reclaimableDetailItem = caption("")
        menu.addItem(reclaimableDetailItem!)

        menu.addItem(.separator())
        menu.addItem(action("Open DiskDrama", #selector(openWindow), key: "o"))
        menu.addItem(action("Scan Now", #selector(scanNow), key: "s"))
        scanItem = caption("")
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

    /// The status item's glyph, one variant per state, each built once.
    ///
    /// The first version set a single template image and coloured it with
    /// `contentTintColor`. The property was assigned correctly and did nothing:
    /// `NSStatusBarButton` draws a **template** image using the menu bar's own
    /// foreground colour, so the icon stayed black on a light bar and white on a
    /// dark one no matter what tint was set. The warning states were invisible.
    ///
    /// So a template image is used only for the normal state, where following
    /// the menu bar's appearance is exactly right. The warning states use a
    /// non-template image with the colour baked into the symbol via a palette
    /// configuration, which AppKit has no reason to override.
    private static func makeIcon(_ color: NSColor?) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "internaldrive.fill",
                                 accessibilityDescription: "Disk space") else { return nil }
        guard let color else {
            base.isTemplate = true
            return base
        }
        let coloured = base.withSymbolConfiguration(.init(paletteColors: [color]))
        // Template rendering would discard the palette colour — this is the
        // whole point of the variant.
        coloured?.isTemplate = false
        return coloured
    }

    private static let normalIcon   = makeIcon(nil)
    private static let lowIcon      = makeIcon(.systemOrange)
    private static let criticalIcon = makeIcon(.systemRed)

    /// Applies both halves of the state signal. The title has the same problem
    /// as the image — a plain `title` is drawn in the menu bar's colour — so a
    /// warning state sets an attributed title carrying the colour, and the
    /// normal state sets a plain one and lets AppKit pick.
    private func applyStatusItem(to button: NSStatusBarButton, text: String, color: NSColor?) {
        switch color {
        case .some(let c) where c == .systemRed: button.image = Self.criticalIcon
        case .some:                              button.image = Self.lowIcon
        case .none:                              button.image = Self.normalIcon
        }
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true

        if let color {
            button.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.foregroundColor: color,
                             .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        } else {
            // Assigning `title` replaces the attributed string, so returning to
            // normal genuinely drops the previous colour rather than keeping a
            // stale red one.
            button.title = text
        }
    }

    /// The app's display face, in the menu.
    ///
    /// Space Grotesk is what every other title in DiskDrama uses, so the
    /// dropdown reads as the same product rather than as a system menu that
    /// happens to belong to it. Falls back to the menu font if the family is
    /// missing — a menu that renders in the wrong face is a blemish, one that
    /// renders in nothing is a bug.
    private static let displayFont: NSFont = {
        let size = NSFont.menuFont(ofSize: 0).pointSize
        return NSFont(name: "Space Grotesk", size: size) ?? NSFont.menuFont(ofSize: 0)
    }()

    /// The capacity bar, as a menu item view.
    ///
    /// Third shape for this thing. It began as eighteen `▓`/`░` characters, which
    /// read accurately and looked like a dithered checkerboard. It became an
    /// `NSImage`, which looked right but could not span the menu: an image has to
    /// state its width up front, and a menu's width is decided after layout by
    /// whichever row is widest — here an action row whose ⌘-shortcut column the
    /// captions know nothing about. Measuring the captions therefore always
    /// undershot.
    ///
    /// A menu item with a `view` is laid out at the menu's own content width, so
    /// the question stops needing an answer. Insets match the menu's text margin
    /// so the bar lines up with the sentences above and below it.
    private final class CapacityBarView: NSView {
        var fraction: Double = 0
        var colour: NSColor = .secondaryLabelColor

        private let inset: CGFloat = 14
        private let barHeight: CGFloat = 6

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: 16)
        }

        override func draw(_ dirtyRect: NSRect) {
            let track = NSRect(x: inset,
                               y: (bounds.height - barHeight) / 2,
                               width: max(0, bounds.width - inset * 2),
                               height: barHeight)
            guard track.width > 0 else { return }
            let radius = barHeight / 2

            NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

            let clamped = max(0, min(1, fraction))
            guard clamped > 0 else { return }
            var filled = track
            filled.size.width = max(barHeight, track.width * clamped)
            colour.setFill()
            NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
        }
    }

    /// A row that states something rather than doing something.
    ///
    /// It used to set `isEnabled = false`, which is what greyed the top of the
    /// menu out. Disabled is AppKit's word for "this control exists but you may
    /// not use it", and it dims accordingly — but these rows are not unavailable
    /// controls, they are the reading. Dimming them says the app is in a
    /// degraded state when it is simply telling you the numbers.
    ///
    /// With `autoenablesItems` off (set in `buildMenu`) an item with no action
    /// stays fully drawn and still does nothing when clicked, which is exactly
    /// what a caption should do.
    private func caption(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
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
            // Normal deliberately has no colour of its own — a permanently
            // coloured menu bar icon stops reading as a warning.
            let color: NSColor? = free < settings.criticalThresholdBytes ? .systemRed
                                : free < settings.lowThresholdBytes    ? .systemOrange
                                : nil
            applyStatusItem(to: button, text: ByteFormat.compact(free), color: color)
            button.toolTip = "Free: \(ByteFormat.compact(free)) of \(ByteFormat.compact(info.totalBytes))"
        }

        lastRenderedInfo = info
        headlineItem?.attributedTitle = headline(for: info)
        // The bar is now an image, so the row carries no text at all.

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

        refreshCapacityBar()
    }

    /// Updates the bar's state. Width is AppKit's problem now, not ours.
    ///
    /// Colour comes from the user's own thresholds in Settings — the same two
    /// numbers the menu-bar icon and the low-space alert read, in bytes of
    /// *free* space. An earlier version used hard-coded fractions of used space
    /// while claiming to match the icon, so the bar could sit grey with the icon
    /// already orange a few pixels above it.
    private func refreshCapacityBar() {
        guard let info = lastRenderedInfo,
              let bar = capacityItem?.view as? CapacityBarView else { return }
        bar.fraction = info.usedFraction
        bar.colour = info.availableBytes < settings.criticalThresholdBytes ? .systemRed
                   : info.availableBytes < settings.lowThresholdBytes      ? .systemOrange
                   : .secondaryLabelColor
        bar.needsDisplay = true
    }

    /// One sentence, one treatment.
    ///
    /// The free figure used to be 17pt semibold monospaced and threshold-
    /// coloured, with "free of 494.4 GB" trailing it at 11.5pt secondary — a
    /// display number and a caption glued into a single line. In a dropdown
    /// opened *from* that same number, coloured the same way, in a bar directly
    /// below it that already carries the same warning, it was the fourth
    /// statement of one fact. Three of those are ambient; this one was just
    /// loud.
    ///
    /// Plain now. The colour still lives where it does work: the menu-bar item
    /// itself, which has to catch the eye from across the screen, and the
    /// capacity bar, which is the picture of it.
    private func headline(for info: DiskInfo) -> NSAttributedString {
        NSAttributedString(
            string: "\(ByteFormat.compact(info.availableBytes)) free of \(ByteFormat.compact(info.totalBytes))",
            attributes: [.font: Self.displayFont,
                         .foregroundColor: NSColor.labelColor])
    }

    /// F01's failure case: volume unreadable → show `—` and say why in the tooltip,
    /// never a stale number presented as current.
    private func renderUnreadable() {
        if let button = statusItem?.button {
            // No threshold to signal — an unreadable volume is not a "you are
            // running out" state, and colouring it red would say something the
            // app does not know.
            applyStatusItem(to: button, text: "—", color: nil)
            button.toolTip = "DiskDrama can't read the boot volume right now."
        }
        headlineItem?.attributedTitle = NSAttributedString(
            string: "—", attributes: [.foregroundColor: NSColor.labelColor])
        lastRenderedInfo = nil
        if let bar = capacityItem?.view as? CapacityBarView {
            bar.fraction = 0
            bar.needsDisplay = true
        }
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
