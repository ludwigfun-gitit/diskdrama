import AppKit
import Foundation
import ServiceManagement

/// Whether DiskDrama starts itself when you log in.
///
/// A background disk monitor that only runs when you remember to open it is not
/// a monitor. F04's low-space alert in particular is worth nothing if the app
/// isn't there when the disk fills — which is exactly when nobody is thinking
/// about launching a cleanup tool.
///
/// **Asked, never assumed.** Registering a login item silently is the kind of
/// thing that makes people distrust an app: it changes what their Mac does at
/// startup without saying so. The onboarding offers it and Settings reverses it.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Whether macOS is holding the request behind the user's own approval.
    ///
    /// `.requiresApproval` means the registration went through but the system
    /// wants confirmation in Login Items. Distinct from "off" — the answer to it
    /// is "go and approve it", not "try again".
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                // Registering while already enabled throws rather than being a
                // no-op, and that error is not a failure worth reporting.
                guard SMAppService.mainApp.status != .enabled else { return true }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            Log.app.error("login item change failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}


/// Quitting and coming back, without the user having to do it by hand.
///
/// macOS asks "Quit & Reopen?" when Full Disk Access is granted to a running
/// app, because a TCC change is not reliably picked up by a process that was
/// already running when it was made. Answering that dialog does not always
/// work — a modal sheet can swallow the termination — and when it doesn't, the
/// user is left with a granted permission, an app that cannot use it, and
/// nothing on screen admitting either fact.
///
/// So DiskDrama offers its own, which it can actually guarantee.
enum Relauncher {

    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        // Without this the workspace just activates the instance that is already
        // running, and nothing restarts.
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            if let error {
                Log.app.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            // Terminate only once the replacement is up, so a failure to launch
            // leaves the user with a running app rather than none.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
