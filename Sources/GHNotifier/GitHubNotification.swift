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

    /// What actually happened on this thread.
    ///
    /// `reason` is split into two kinds: ones that describe the event
    /// directly (state_change, review_requested, assign) and ones that
    /// describe your *relationship* to the thread (author, comment,
    /// manual, subscribed) and tell us nothing about the latest activity.
    /// For the relationship kinds we fall through to `latest_comment_url`
    /// to guess what triggered the notification — its path distinguishes
    /// a review from a review comment from a conversation comment.
    ///
    /// We deliberately *don't* trust the URL path for state_change /
    /// review_requested / etc: `latest_comment_url` reflects the latest
    /// comment that exists on the thread, not necessarily the latest
    /// activity, so a stale comment URL would otherwise mislabel a merge
    /// as a "Comment".
    var eventLabel: String {
        switch reason {
        case "review_requested":
            return "Review requested"
        case "assign":
            return subject.type == "PullRequest" ? "PR assigned" : "Issue assigned"
        case "state_change":
            return subject.type == "PullRequest" ? "PR state changed" : "Issue state changed"
        case "mention", "team_mention":
            if let kind = latestCommentKind {
                return "Mention in \(kind)"
            }
            return "Mentioned"
        case "author", "comment", "manual", "subscribed":
            if let kind = latestCommentKind {
                return kind.prefix(1).uppercased() + kind.dropFirst()
            }
            switch subject.type {
            case "PullRequest": return "PR update"
            case "Issue":       return "Issue update"
            case "Commit":      return "Commit"
            case "Release":     return "Release"
            case "Discussion":  return "Discussion"
            default:            return subject.type
            }
        case "ci_activity":
            return "CI activity"
        case "push":
            return "New commits"
        default:
            return reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Lowercase noun for the kind of comment in `latest_comment_url`,
    /// or nil when there's no fresh comment. Used by both `eventLabel`
    /// (for sentence-style "Mention in review") and the click anchor.
    private var latestCommentKind: String? {
        guard let url = subject.latestCommentUrl, url != subject.url else { return nil }
        if url.contains("/pulls/") && url.contains("/reviews/") { return "review" }
        if url.contains("/pulls/comments/") { return "review comment" }
        if url.contains("/issues/comments/") { return "comment" }
        return nil
    }
}
