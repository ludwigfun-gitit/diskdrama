// DiskSentinel — menubar disk space monitor
// Requires macOS 13+, no dependencies.
// Build: see build.sh

import Cocoa

// MARK: - Disk Info

struct DiskInfo {
    let freeBytes: Int64
    let totalBytes: Int64

    var usedBytes: Int64 { totalBytes - freeBytes }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    var freeFraction: Double { 1.0 - usedFraction }

    static func read() -> DiskInfo? {
        var stat = statvfs()
        guard statvfs("/", &stat) == 0 else { return nil }
        let blockSize = Int64(stat.f_bsize)
        let total     = Int64(stat.f_blocks) * blockSize
        let free      = Int64(stat.f_bavail) * blockSize   // bavail = available to non-root
        return DiskInfo(freeBytes: free, totalBytes: total)
    }

    // Compact label for the menubar, e.g. "42.3 GB"
    var menubarLabel: String { formatBytes(freeBytes) }

    // Alert threshold check
    var isLow: Bool { freeBytes < 5 * 1_073_741_824 }      // < 5 GB
    var isCritical: Bool { freeBytes < 1 * 1_073_741_824 } // < 1 GB
}

func formatBytes(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    let mb = Double(bytes) / 1_048_576
    return String(format: "%.0f MB", mb)
}

// MARK: - App Delegate

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: Timer?
    private var lastInfo: DiskInfo?

    // Poll interval: 10 minutes
    private let pollInterval: TimeInterval = 10 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // No Dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        refresh()

        timer = Timer.scheduledTimer(
            withTimeInterval: pollInterval,
            repeats: true
        ) { [weak self] _ in self?.refresh() }
    }

    // MARK: - Menu

    private func buildMenu() {
        menu = NSMenu()

        let header = NSMenuItem(title: "Macintosh HD — Free Space", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        let freeItem   = NSMenuItem(title: "Free:  —", action: nil, keyEquivalent: "")
        let usedItem   = NSMenuItem(title: "Used:  —", action: nil, keyEquivalent: "")
        let totalItem  = NSMenuItem(title: "Total: —", action: nil, keyEquivalent: "")
        let pctItem    = NSMenuItem(title: "Usage: —", action: nil, keyEquivalent: "")
        [freeItem, usedItem, totalItem, pctItem].forEach {
            $0.isEnabled = false
            menu.addItem($0)
        }

        menu.addItem(.separator())

        let updatedItem = NSMenuItem(title: "Last checked: —", action: nil, keyEquivalent: "")
        updatedItem.isEnabled = false
        menu.addItem(updatedItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Refresh Now",
            action: #selector(refresh),
            keyEquivalent: "r"
        ))

        menu.addItem(NSMenuItem(
            title: "Open Storage Settings…",
            action: #selector(openStorageSettings),
            keyEquivalent: ""
        ))

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit DiskSentinel",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    // Tag items by index for easy update
    private enum MenuIndex: Int {
        case free = 2, used, total, pct, updated = 8, refresh = 10, storage
    }

    @objc private func refresh() {
        guard let info = DiskInfo.read() else { return }
        lastInfo = info
        updateMenuBar(info)
        updateMenuItems(info)
    }

    private func updateMenuBar(_ info: DiskInfo) {
        guard let button = statusItem.button else { return }

        let icon = info.isCritical ? "⛔️" : info.isLow ? "⚠️" : "💾"
        button.title = "\(icon) \(info.menubarLabel)"
        button.toolTip = "Free: \(info.menubarLabel) of \(formatBytes(info.totalBytes))"
    }

    private func updateMenuItems(_ info: DiskInfo) {
        let items = menu.items
        guard items.count > MenuIndex.pct.rawValue else { return }

        items[MenuIndex.free.rawValue].title  = "Free:  \(formatBytes(info.freeBytes))"
        items[MenuIndex.used.rawValue].title  = "Used:  \(formatBytes(info.usedBytes))"
        items[MenuIndex.total.rawValue].title = "Total: \(formatBytes(info.totalBytes))"
        items[MenuIndex.pct.rawValue].title   = String(format: "Usage: %.1f%%", info.usedFraction * 100)

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        items[MenuIndex.updated.rawValue].title = "Last checked: \(formatter.string(from: Date()))"

        // Colour the free item red when critical, orange when low
        if info.isCritical {
            items[MenuIndex.free.rawValue].attributedTitle = attributed(
                "Free:  \(formatBytes(info.freeBytes))", color: .systemRed
            )
        } else if info.isLow {
            items[MenuIndex.free.rawValue].attributedTitle = attributed(
                "Free:  \(formatBytes(info.freeBytes))", color: .systemOrange
            )
        } else {
            items[MenuIndex.free.rawValue].attributedTitle = nil
        }
    }

    private func attributed(_ string: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.foregroundColor: color])
    }

    @objc private func openStorageSettings() {
        // macOS 13+ System Settings URL
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
            NSWorkspace.shared.open(url)
        }
    }
}
