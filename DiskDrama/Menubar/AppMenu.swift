import AppKit

/// The application's menu bar.
///
/// ## Why this file exists
///
/// The app didn't have one. There is no `MainMenu.xib` — the whole app is built
/// in code — and nothing ever assigned `NSApp.mainMenu`, so it stayed nil. That
/// is invisible while the app is `.accessory`, which is how it spends most of
/// its life, and it produced two bugs the moment the window opened and the
/// policy flipped to `.regular`:
///
/// - **The menu bar kept showing the previous app.** DiskDrama was genuinely
///   frontmost — `NSWorkspace.frontmostApplication` confirmed it — but an active
///   app with no menu to draw leaves whatever was there before on screen. The
///   window looked focused, with live traffic lights, while another app's menus
///   sat above it.
/// - **No keyboard shortcuts worked at all.** Key equivalents are matched
///   against the main menu. With no main menu there is nothing to match, so
///   ⌘W, ⌘Q, and — worse, once Settings grew text fields — ⌘C, ⌘V, ⌘A and ⌘Z
///   all did nothing.
///
/// The second is the reason the Edit menu below is not optional decoration. The
/// standard editing commands are *only* reachable through it; a text field does
/// not implement them on its own. They are wired to `nil`, which sends them down
/// the responder chain to whatever is focused — the correct target, and the
/// reason no controller has to know these exist.
@MainActor
enum AppMenu {

    /// Built once at launch. Assigning it while `.accessory` is harmless — the
    /// menu is simply not drawn until the policy becomes `.regular`.
    static func install(target: AnyObject, settings: Selector, scan: Selector) {
        let name = ProcessInfo.processInfo.processName
        let main = NSMenu()

        main.addItem(appMenu(name: name, target: target, settings: settings))
        main.addItem(scanMenu(target: target, scan: scan))
        main.addItem(editMenu())

        let window = windowMenu()
        main.addItem(window.item)

        NSApp.mainMenu = main
        // Lets AppKit keep the window list current by itself.
        NSApp.windowsMenu = window.menu
    }

    // MARK: - Menus

    /// The first menu is always the application menu; macOS substitutes the real
    /// bundle name for its title, so what is set here doesn't show.
    private static func appMenu(name: String, target: AnyObject, settings: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()

        menu.addItem(withTitle: "About \(name)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: settings, keyEquivalent: ",")
        settingsItem.target = target
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide \(name)",
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit \(name)",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    /// Deliberately not called "File". DiskDrama has no documents to open or
    /// save, and a File menu containing neither would be a menu shaped like a
    /// promise the app doesn't keep.
    private static func scanMenu(target: AnyObject, scan: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Scan")

        let scanItem = NSMenuItem(title: "Scan Now", action: scan, keyEquivalent: "s")
        scanItem.target = target
        menu.addItem(scanItem)

        item.submenu = menu
        return item
    }

    /// Every item here targets `nil` on purpose: the action travels the
    /// responder chain to whichever control is focused, so text fields get real
    /// editing behaviour without anything being wired to them directly.
    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        item.submenu = menu
        return item
    }

    private static func windowMenu() -> (item: NSMenuItem, menu: NSMenu) {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")

        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        // Closing the window returns the app to its ambient `.accessory` state
        // rather than quitting — `windowWillClose` already handles that, so this
        // needs no special casing.
        menu.addItem(withTitle: "Close",
                     action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        item.submenu = menu
        return (item, menu)
    }
}
