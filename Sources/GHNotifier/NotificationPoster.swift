import Foundation
import UserNotifications
import AppKit

/// Posts macOS Notification Center alerts. Requires the binary to live inside
/// an `.app` bundle whose Info.plist has a CFBundleIdentifier and whose code
/// signature is stable enough for the system to associate a TCC permission with.
/// If the system refuses to deliver, we log the error — there is no fallback
/// channel (an osascript `display notification` would be attributed to Script
/// Editor and confuse the user).
final class NotificationPoster: NSObject, UNUserNotificationCenterDelegate {

    /// Cached result of the most recent `getNotificationSettings` call.
    /// AppDelegate can read this to surface "Notifications disabled" in the menu.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Invoked on the main queue when the user clicks a banner.
    /// Receives (threadId, webUrl). Set this from AppDelegate so the app can
    /// open the URL, dismiss the thread locally, and mark it read on GitHub.
    var onClick: ((String, String) -> Void)?

    /// Called whenever `authorizationStatus` changes. Use from AppDelegate to
    /// refresh the menu header.
    var onAuthorizationChange: (() -> Void)?

    func bootstrap() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                NSLog("Notification authorization error: \(error.localizedDescription)")
            }
            self.refreshAuthorizationStatus()
        }
        // Also fetch the current status, in case the user already responded
        // to the prompt on a previous launch.
        refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let prev = self.authorizationStatus
            self.authorizationStatus = settings.authorizationStatus
            if prev != settings.authorizationStatus {
                DispatchQueue.main.async { self.onAuthorizationChange?() }
            }
        }
    }

    func post(_ n: GitHubNotification) {
        let ref = n.subjectIdentifierLabel
        let repoRef = ref.isEmpty ? n.repository.fullName : "\(n.repository.fullName) \(ref)"
        // No emoji prefix: the system already shows the app icon.
        // eventLabel mirrors GH's reason vocabulary.
        let title = "\(n.eventLabel) · \(repoRef)"
        let body  = n.subject.title
        let url   = n.htmlUrl

        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        content.userInfo = ["url": url, "id": n.id]

        let request = UNNotificationRequest(
            identifier: "ghnotifier.\(n.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Failed to post notification \(n.id): \(error.localizedDescription)")
            }
            // The auth status can change at runtime (user toggles it in System
            // Settings), so re-check after every post.
            self.refreshAuthorizationStatus()
        }
    }

    // Open the underlying URL when the user clicks the banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id  = info["id"]  as? String ?? ""
        let url = info["url"] as? String ?? ""
        if let onClick {
            DispatchQueue.main.async {
                onClick(id, url)
            }
        } else if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
        completionHandler()
    }

    // Allow banners to appear while the app is "frontmost" (it's an accessory app,
    // but the system needs this for delivery in some cases).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
