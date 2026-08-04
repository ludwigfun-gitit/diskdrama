import Foundation
import UserNotifications

/// User notifications (F21's watch alerts, F25's low-space alert).
///
/// Authorization is requested **lazily** — the first time the app actually has
/// something to say — rather than at launch. A permission prompt on first run,
/// before the user has seen what the app does, is the fastest way to get a
/// permanent "Don't Allow" and lose the channel for good.
///
/// A denied grant is not an error state: the app still shows everything in its
/// own window. Notifications are the convenience, not the product.
@MainActor
enum Notifier {

    private static var didRequestAuthorization = false

    enum Category: String {
        case watchExceeded = "watch-exceeded"
        case lowSpace = "low-space"
    }

    /// Fire-and-forget. Requests authorization on first use, then posts.
    static func post(title: String, body: String, category: Category, id: String = UUID().uuidString) {
        Task {
            let center = UNUserNotificationCenter.current()
            if !didRequestAuthorization {
                didRequestAuthorization = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                Log.app.notice("notification suppressed — not authorized")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category.rawValue

            // No trigger: deliver now. A scheduled trigger would fire after the
            // condition it describes may already have changed.
            try? await center.add(UNNotificationRequest(
                identifier: id, content: content, trigger: nil))
            Log.app.notice("notification posted — \(category.rawValue, privacy: .public)")
        }
    }
}
