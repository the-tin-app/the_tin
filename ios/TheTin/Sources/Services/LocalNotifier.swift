import Foundation
import UserNotifications

/// Protocol seam over UNUserNotificationCenter — the first notification code in the app —
/// so PriceAlertsService and SettingsModel are testable without the framework.
protocol LocalNotifier {
    /// Ask iOS for notification permission. Returns whether it was granted.
    func requestAuthorization() async -> Bool
    /// True when the user has explicitly denied notifications (drives the Settings hint).
    func isAuthorizationDenied() async -> Bool
    /// Post one local notification immediately. `userInfo` rides along for tap routing.
    func post(title: String, body: String, userInfo: [String: String]) async
}

/// The one production implementation; owns all UNUserNotificationCenter access.
final class UserNotificationNotifier: LocalNotifier {
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func isAuthorizationDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    func post(title: String, body: String, userInfo: [String: String]) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// UNUserNotificationCenter delegate: shows alerts while foregrounded and routes taps to the
/// wishlist. Installed in TheTin.init so a tap that cold-launches the app is still caught
/// (the delegate must exist before the app finishes launching).
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    /// Set by TheTin; fired on the main actor when the user taps a wishlist price alert.
    var onWishlistTap: (@MainActor () -> Void)?

    func install() { UNUserNotificationCenter.current().delegate = self }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.userInfo["route"] as? String
                == PriceAlertsService.wishlistRoute else { return }
        await MainActor.run { self.onWishlistTap?() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
