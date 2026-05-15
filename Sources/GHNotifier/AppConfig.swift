import Foundation
import AppKit

/// One reason-bucket in the dropdown — a section header, the reasons that
/// route here, a per-section cap, and the URL to open when there's overflow
/// beyond the cap.
struct ReasonGroup {
    let title: String
    /// Emoji shown to the left of each item in this section. Chosen to match
    /// the icon GitHub uses for the corresponding filter on
    /// github.com/notifications (👀 / ✋ / 💬 etc).
    let emoji: String
    /// SF Symbol fallback if emoji rendering ever fails. Tinted with `tintColor`.
    let symbolName: String
    /// Tint applied to the SF Symbol fallback.
    let tintColor: NSColor
    let reasons: Set<String>
    let cap: Int
    /// Encoded GitHub notifications query (e.g. "is:unread reason:author") used
    /// to construct the overflow link. nil to disable the overflow row.
    let overflowQuery: String?
}

/// User-tunable configuration for the menu bar app.
/// Edit values here and rebuild to change behavior.
enum AppConfig {
    /// How often we poll the GitHub notifications API.
    static let pollInterval: TimeInterval = 15 * 60   // 15 minutes

    /// Max Notification Center banners to fire on any single poll. A guard
    /// against the "you've been away" / "first run" notification storm.
    /// All un-bannered items still appear in the dropdown; they just don't
    /// get a system toast.
    static let bannerCapPerPoll: Int = 5

    /// Ordered list of dropdown sections. Top = most urgent.
    /// Notifications whose reason isn't in any group are dropped from the
    /// menu (we never show them, never banner them).
    ///
    /// See https://docs.github.com/en/rest/activity/notifications#about-notification-reasons
    /// for the full reason vocabulary.
    static let menuGroups: [ReasonGroup] = [
        ReasonGroup(
            title: "Assigned",
            emoji: "🎯",
            symbolName: "target",
            tintColor: .systemRed,
            reasons: ["assign"],
            cap: 10,
            overflowQuery: "is:unread reason:assign"
        ),
        ReasonGroup(
            title: "Review requested",
            emoji: "👀",
            symbolName: "eye.fill",
            tintColor: .systemPurple,
            reasons: ["review_requested"],
            cap: 10,
            overflowQuery: "is:unread reason:review-requested"
        ),
        ReasonGroup(
            title: "Mentioned",
            emoji: "✋",
            symbolName: "at",
            tintColor: .systemOrange,
            reasons: ["mention", "team_mention"],
            cap: 10,
            overflowQuery: "is:unread reason:mention"
        ),
        ReasonGroup(
            title: "Participating",
            emoji: "💬",
            symbolName: "text.bubble.fill",
            tintColor: .systemBlue,
            reasons: ["author", "comment"],
            cap: 10,
            overflowQuery: "is:unread reason:author"
        )
    ]

    /// Reasons we accept from the GitHub API. Derived from menuGroups so the
    /// two never drift out of sync.
    static var allowedReasons: Set<String> {
        Set(menuGroups.flatMap { $0.reasons })
    }

    /// Returns the group a notification belongs in, or nil if its reason
    /// isn't covered by any group.
    static func group(for reason: String) -> ReasonGroup? {
        menuGroups.first { $0.reasons.contains(reason) }
    }

    /// Bundle id used when posting Notification Center alerts.
    /// This must match CFBundleIdentifier in Info.plist for native delivery.
    static let bundleIdentifier: String = "com.eronwright.gh-notifier"

    /// UserDefaults keys.
    static let seenIdsKey  = "ghnotifier.seenIds.v1"
    static let lastSyncKey = "ghnotifier.lastSync.v1"
}
