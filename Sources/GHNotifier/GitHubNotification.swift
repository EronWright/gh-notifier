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

    /// Human-friendly tag for the dropdown / notification title.
    var reasonLabel: String {
        switch reason {
        case "author":
            return subject.type == "PullRequest" ? "PR activity" : "Issue activity"
        case "mention":            return "Mentioned"
        case "review_requested":   return "Review requested"
        case "comment":            return "New comment"
        case "team_mention":       return "Team mentioned"
        case "assign":             return "Assigned"
        default:                   return reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
