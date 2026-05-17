import Foundation

/// One entry from `gh api notifications`.
/// See https://docs.github.com/en/rest/activity/notifications#list-notifications-for-the-authenticated-user
struct GitHubNotification: Codable, Hashable {
    let id: String
    let reason: String
    let unread: Bool
    let updatedAt: String
    let subject: Subject
    let repository: Repository

    struct Subject: Codable, Hashable {
        let title: String
        let url: String?
        let latestCommentUrl: String?
        let type: String

        enum CodingKeys: String, CodingKey {
            case title, url, type
            case latestCommentUrl = "latest_comment_url"
        }
    }

    struct Repository: Codable, Hashable {
        let fullName: String
        let htmlUrl: String

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
            case htmlUrl  = "html_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, reason, unread, subject, repository
        case updatedAt = "updated_at"
    }

    /// Best-effort conversion of the API URL to the corresponding web URL.
    /// Falls back to the repository's html_url.
    var htmlUrl: String {
        guard let api = subject.url else { return repository.htmlUrl }
        var web = api
            .replacingOccurrences(of: "https://api.github.com/repos", with: "https://github.com")
            .replacingOccurrences(of: "/pulls/", with: "/pull/")
        // For commits/releases/discussions the conversion above already does the right thing.
        // Strip an accidental "/api" path if present.
        if web.contains("api.github.com") {
            web = repository.htmlUrl
        }
        return web
    }

    /// Compact identifier for the subject, prefixed for clarity:
    ///   - "#1234" for issues / PRs / discussions / releases
    ///   - "@abc1234" for commits (short sha)
    /// Returns "" when subject.url is missing or unparseable.
    var subjectIdentifierLabel: String {
        guard let url = subject.url,
              let last = url.split(separator: "/").last else { return "" }
        let id = String(last)
        if id.isEmpty { return "" }
        switch subject.type {
        case "Commit":
            return "@\(id.prefix(7))"
        default:
            return "#\(id)"
        }
    }

    /// GH's own per-thread classification, formatted for display.
    ///
    /// We deliberately do *not* try to infer the trigger event here —
    /// the public REST notifications API doesn't carry event data, and
    /// every heuristic we tried (`latest_comment_url` path, cache-and-
    /// diff against prior polls) introduced its own failure modes. So
    /// the label simply mirrors GH's reason vocabulary — the same words
    /// you see next to each row on github.com/notifications. The icon
    /// keys off the same reason so the two signals always agree.
    ///
    /// Full table of `reason` values + descriptions:
    /// https://docs.github.com/en/rest/activity/notifications?apiVersion=2026-03-10#about-notification-reasons
    var eventLabel: String {
        switch reason {
        case "assign":            return "Assigned"
        case "review_requested":  return "Review requested"
        case "mention":           return "Mention"
        case "team_mention":      return "Team mention"
        case "state_change":      return "State change"
        case "author":            return "Author"
        case "comment":           return "Commented"
        case "manual":            return "Manual"
        case "subscribed":        return "Subscribed"
        case "ci_activity":       return "CI activity"
        case "push":              return "New commits"
        default:
            return reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
