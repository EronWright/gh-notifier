import Foundation

/// User-tunable configuration for the menu bar app.
/// Edit values here and rebuild to change behavior.
enum AppConfig {
    /// How often we poll the GitHub notifications API.
    static let pollInterval: TimeInterval = 15 * 60   // 15 minutes

    /// Max Notification Center banners to fire on any single poll. A guard
    /// against the "you've been away" / "first run" notification storm.
    /// All un-bannered items still appear in the dropdown; they just don't
    /// get a system toast.
    static let bannerCapPerPoll: Int = 15

    /// Hard ceiling on rows the dropdown renders before collapsing the rest
    /// into a single "→ N more on GitHub" link. The menu stays navigable on
    /// busy days without giving up the scroll-everywhere option of the GH
    /// inbox itself.
    static let menuItemCap: Int = 50

    /// Bundle id used when posting Notification Center alerts.
    /// This must match CFBundleIdentifier in Info.plist for native delivery.
    static let bundleIdentifier: String = "com.eronwright.gh-notifier"

    /// UserDefaults keys.
    static let seenIdsKey  = "ghnotifier.seenIds.v1"
    static let lastSyncKey = "ghnotifier.lastSync.v1"
}
