import Foundation
import Observation

/// The volume poll behind every free-space figure in the app.
///
/// Extracted out of `MenubarController` in Step 6 because the sidebar needs the
/// same reading. Two independent timers reading the same volume would drift
/// against each other, and the moment they disagreed the app would be showing
/// the user two different answers to "how much space do I have" on one screen.
///
/// `@MainActor @Observable` so SwiftUI views bind to it directly; the menubar,
/// which is AppKit, reads it through an explicit change callback instead.
@MainActor
@Observable
final class DiskMonitor {

    private(set) var info: DiskInfo?

    /// Fired after every successful or failed read. AppKit surfaces cannot
    /// observe `@Observable` the way SwiftUI does, so the menubar gets a hook.
    @ObservationIgnored var onChange: (() -> Void)?

    private var timer: Timer?

    var isLow: Bool {
        guard let info else { return false }
        return info.availableBytes < Settings.shared.lowThresholdBytes
    }

    var isCritical: Bool {
        guard let info else { return false }
        return info.availableBytes < Settings.shared.criticalThresholdBytes
    }

    func start() {
        refresh()

        // `.common` mode so the poll keeps firing while a menu is open — on the
        // default run-loop mode a tracking session starves the timer, which is
        // exactly when the user is looking at the numbers.
        let timer = Timer(timeInterval: Settings.shared.pollIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// A failed read sets `info` to nil rather than leaving the last value in
    /// place. F01's failure case is explicit that a stale number presented as
    /// current is worse than an honest dash.
    func refresh() {
        info = DiskInfo.read()
        onChange?()
    }
}
