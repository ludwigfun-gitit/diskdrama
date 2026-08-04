import AppKit
import SwiftUI

/// Owns the main window (A09).
///
/// ## Why the activation policy moves
///
/// DiskDrama lives in the menubar and is `.accessory` at rest: no Dock icon, no
/// app menu, nothing in the ⌘-Tab switcher. That is right for an ambient monitor
/// and wrong for a window the user is working in — an `.accessory` app's window
/// cannot become properly key, gets no app menu, and cannot be reached again
/// after being covered. So the policy is `.regular` while a window is open and
/// drops back on close. This is the standard shape for a menubar app that also
/// owns a real window.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let model: AppModel
    private let onScan: () -> Void
    private let onStopScan: () -> Void

    init(model: AppModel, onScan: @escaping () -> Void, onStopScan: @escaping () -> Void) {
        self.model = model
        self.onScan = onScan
        self.onStopScan = onStopScan
    }

    func show() {
        if let window {
            activate(window)
            return
        }

        // Read persisted state on first open rather than at launch. It costs a
        // store fetch that a session which never opens the window should not pay,
        // and the monitor deliberately does not depend on the store at all.
        model.loadPersistedState()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1160, height: 748),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        // The handoff draws its own 46px bar with the title, status and actions
        // in it, so the system title bar is transparent and empty and the content
        // runs underneath it. The traffic lights stay system-drawn — reproducing
        // those by hand is how a Mac app starts feeling not-quite-native.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "DiskDrama"
        window.backgroundColor = NSColor(Theme.chrome)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("DiskDramaMainWindow")

        window.contentView = NSHostingView(
            rootView: MainWindow(model: model, onScan: onScan, onStopScan: onStopScan))

        window.center()
        self.window = window
        activate(window)
    }

    private func activate(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        Log.app.notice("main window closing — returning to accessory")
        // Back to ambient. The window object is kept (`isReleasedWhenClosed` is
        // false) so reopening is instant and the user's frame, tier and scroll
        // position survive.
        NSApp.setActivationPolicy(.accessory)
    }
}
