import Foundation

/// Runtime-overridable settings persisted in UserDefaults.
/// Values fall back to the hardcoded defaults when not yet set by the user.
enum UserSettings {
    static let pollIntervalKey = "ghnotifier.settings.pollInterval"
    static let bannerCapKey    = "ghnotifier.settings.bannerCap"
    static let maxPagesKey     = "ghnotifier.settings.maxPages"

    static var pollInterval: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: pollIntervalKey)
            return v > 0 ? v : 15 * 60
        }
        set { UserDefaults.standard.set(newValue, forKey: pollIntervalKey) }
    }

    static var bannerCapPerPoll: Int {
        get {
            guard UserDefaults.standard.object(forKey: bannerCapKey) != nil else { return 5 }
            return UserDefaults.standard.integer(forKey: bannerCapKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: bannerCapKey) }
    }

    static var maxPages: Int {
        get {
            guard UserDefaults.standard.object(forKey: maxPagesKey) != nil else { return 5 }
            return UserDefaults.standard.integer(forKey: maxPagesKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: maxPagesKey) }
    }
}
