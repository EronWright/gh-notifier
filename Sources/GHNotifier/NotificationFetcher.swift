import Foundation

enum FetcherError: LocalizedError {
    case ghNotFound
    case ghFailed(exitCode: Int32, stderr: String)
    case decodeFailed(Error, raw: String)

    var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "Could not find the `gh` CLI. Install it from https://cli.github.com and run `gh auth login`."
        case .ghFailed(let code, let stderr):
            return "gh exited with code \(code): \(stderr)"
        case .decodeFailed(let err, _):
            return "Failed to decode notifications JSON: \(err.localizedDescription)"
        }
    }
}

/// Wraps `gh api notifications` and filters to the reasons we care about.
final class NotificationFetcher {

    /// How many pages we'll walk per poll. With per_page=50 the upper bound
    /// is 250 raw items per poll (~5 API calls, ~1–2.5s wall clock). The cap
    /// keeps a runaway backlog from melting through 50+ calls every 15 min.
    private static let maxPages = 5
    private static let perPage  = 50

    /// Fetches the user's complete unread notification inbox, paginating up
    /// to `maxPages` pages. We deliberately do *not* pass `since`: every poll
    /// returns the full set of currently-unread items so the dropdown mirrors
    /// github.com/notifications. Banner-posting de-dupe is handled separately
    /// by AppDelegate's `seenIds`.
    ///
    /// We deliberately do NOT pass `participating=true` either. The docs say
    /// it returns notifications where you're "directly participating or
    /// mentioned", but the mapping from that phrase to specific `reason`
    /// values isn't enumerated — there's a real risk `team_mention` (or even
    /// `mention`) gets dropped. Cheaper-safer to filter the page client-side
    /// against `AppConfig.allowedReasons`.
    func fetch() async throws -> [GitHubNotification] {
        let ghPath = try Self.findGhPath()
        var accumulator: [GitHubNotification] = []

        for page in 1...Self.maxPages {
            let args = ["api", "-X", "GET", "notifications",
                        "-f", "all=false",
                        "-f", "per_page=\(Self.perPage)",
                        "-f", "page=\(page)"]

            let (status, out, err) = try Self.run(executable: ghPath, args: args)
            guard status == 0 else {
                throw FetcherError.ghFailed(exitCode: status, stderr: err)
            }

            let pageItems: [GitHubNotification]
            do {
                pageItems = try JSONDecoder().decode([GitHubNotification].self, from: Data(out.utf8))
            } catch {
                throw FetcherError.decodeFailed(error, raw: out)
            }

            if pageItems.isEmpty { break }
            accumulator.append(contentsOf: pageItems.filter {
                AppConfig.allowedReasons.contains($0.reason)
            })
            // A page that comes back shorter than `perPage` is the last page —
            // no need to ask for another.
            if pageItems.count < Self.perPage { break }
        }

        return accumulator
    }

    /// Mark a single notification thread as read on GitHub.
    /// Equivalent to: `gh api -X PATCH notifications/threads/{id}`.
    func markRead(threadId: String) async throws {
        guard !threadId.isEmpty else { return }
        let ghPath = try Self.findGhPath()
        let (status, _, err) = try Self.run(
            executable: ghPath,
            args: ["api", "-X", "PATCH", "notifications/threads/\(threadId)"]
        )
        // GitHub returns 205 Reset Content on success; gh maps that to exit 0.
        guard status == 0 else {
            throw FetcherError.ghFailed(exitCode: status, stderr: err)
        }
    }

    /// Mark a thread as **done** (archive). Equivalent to clicking the Done
    /// banner on github.com/notifications: the thread leaves the unread inbox
    /// entirely and moves to the "Done" filter on github.com/notifications.
    /// Equivalent to: `gh api -X DELETE notifications/threads/{id}`.
    func markDone(threadId: String) async throws {
        guard !threadId.isEmpty else { return }
        let ghPath = try Self.findGhPath()
        let (status, _, err) = try Self.run(
            executable: ghPath,
            args: ["api", "-X", "DELETE", "notifications/threads/\(threadId)"]
        )
        // GitHub returns 204 No Content on success.
        guard status == 0 else {
            throw FetcherError.ghFailed(exitCode: status, stderr: err)
        }
    }

    // MARK: - Process plumbing

    private static func run(executable: String, args: [String]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        // Inherit a sane PATH so gh's subshells can find git, etc.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = (env["PATH"].map { "\($0):\(extraPaths)" }) ?? extraPaths
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }

    private static func findGhPath() throws -> String {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
            "\(NSHomeDirectory())/.local/bin/gh"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last-ditch: ask the shell.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", "command -v gh"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch { /* fall through */ }
        throw FetcherError.ghNotFound
    }
}
