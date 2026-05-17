import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: Timer?

    private let fetcher = NotificationFetcher()
    private let poster  = NotificationPoster()

    /// Notifications currently shown in the dropdown.
    private var current: [GitHubNotification] = []
    /// The poll interval the running timer was created with; used to detect changes.
    private var scheduledPollInterval: TimeInterval = 0
    /// Most recent error from a failed poll, surfaced in the menu.
    private var lastError: String?
    /// Last successful sync time, for the "since" param and menu label.
    private var lastSync: Date? {
        get {
            (UserDefaults.standard.object(forKey: AppConfig.lastSyncKey) as? Date)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: AppConfig.lastSyncKey)
        }
    }
    /// Ids in the unread inbox we've already handled this session — either
    /// banner'd, or skipped past the per-poll cap. After each poll this is
    /// rewritten to match the current unread set, so a thread that leaves
    /// the inbox (read/done) and later re-enters (new comment on the same
    /// PR/issue, which reuses the same thread id) banners again.
    private var seenIds: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: AppConfig.seenIdsKey) ?? []
            return Set(arr)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: AppConfig.seenIdsKey)
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        poster.bootstrap()
        poster.onClick = { [weak self] id, url in
            // Banner taps land on the main thread via DispatchQueue.main.async
            // in NotificationPoster, but the closure type isn't @MainActor-typed,
            // so hop explicitly before touching @MainActor state.
            Task { @MainActor in
                self?.handleOpen(id: id, url: url)
            }
        }
        poster.onAuthorizationChange = { [weak self] in
            self?.rebuildMenu()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        setupStatusItem()
        scheduleTimer()
        Task { await self.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    // MARK: - Status item / menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bell",
                                   accessibilityDescription: "GitHub Notifications")
            button.imagePosition = .imageLeft
            button.title = ""
        }
        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // Errors and the permission warning still live at the top — they're
        // urgent enough that the user should see them on first glance.
        // "Last sync" has moved down next to "Refresh Now".
        var hasTopSection = false

        if let err = lastError {
            let item = NSMenuItem(title: "Error: \(err)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            hasTopSection = true
        }

        if let warning = notificationStatusWarning() {
            let item = NSMenuItem(title: warning,
                                  action: #selector(openNotificationSettings),
                                  keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            hasTopSection = true
        }

        if hasTopSection {
            menu.addItem(.separator())
        }

        if current.isEmpty {
            let item = NSMenuItem(title: "No unread notifications", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            // Flat, newest-first list. Each row carries an event-specific
            // icon so the reason is readable at a glance.
            let hint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            hint.attributedTitle = Self.menuHint("hold ⌥ to mark done")
            hint.isEnabled = false
            menu.addItem(hint)

            for n in current.prefix(AppConfig.menuItemCap) {
                addNotificationItems(for: n)
            }
            let overflow = current.count - AppConfig.menuItemCap
            if overflow > 0 {
                let item = NSMenuItem(title: "→ \(overflow) more on GitHub",
                                      action: #selector(openAllOnGitHub),
                                      keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // Last sync sits with the action that produced it.
        let syncRow = NSMenuItem(title: headerTitle(), action: nil, keyEquivalent: "")
        syncRow.isEnabled = false
        menu.addItem(syncRow)

        let refresh = NSMenuItem(title: "Refresh Now",
                                 action: #selector(manualRefresh),
                                 keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let openAll = NSMenuItem(title: "Open github.com/notifications",
                                 action: #selector(openAllOnGitHub),
                                 keyEquivalent: "")
        openAll.target = self
        menu.addItem(openAll)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit GH Notifier",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Adds a paired primary + ⌥-alternate row for a single notification.
    /// Row icon and label both follow the GH-reason vocabulary so the
    /// two signals always agree.
    private func addNotificationItems(for n: GitHubNotification) {
        // owner/repo #1234 · Reason — Subject title  (or @abc1234 for commits)
        let ref = n.subjectIdentifierLabel
        let repoRef = ref.isEmpty
            ? n.repository.fullName
            : "\(n.repository.fullName) \(ref)"
        let title = "\(repoRef) · \(n.eventLabel) — \(n.subject.title)"
        let style = Self.eventStyle(for: n)

        let primary = NSMenuItem(title: title,
                                 action: #selector(openNotification(_:)),
                                 keyEquivalent: "")
        primary.target = self
        primary.representedObject = n
        primary.keyEquivalentModifierMask = []
        primary.image = Self.eventImage(style: style)
        primary.toolTip = "Open in browser and mark as read. Hold ⌥ to mark as done instead."
        menu.addItem(primary)

        // Same text as primary — only the icon distinguishes the actions.
        let alt = NSMenuItem(title: title,
                             action: #selector(markAsDone(_:)),
                             keyEquivalent: "")
        alt.target = self
        alt.representedObject = n
        alt.keyEquivalentModifierMask = [.option]
        alt.isAlternate = true
        // Swap the leading icon when the user holds Option — visual cue that
        // the action has shifted from "open & read" to "done".
        alt.image = Self.emojiImage("✅")
            ?? Self.tintedSymbol(name: "checkmark.circle.fill", color: .systemGreen)
        menu.addItem(alt)
    }

    /// Visual treatment for a row, derived from event type. The icon
    /// ties the row to its category at a glance now that groups no
    /// longer exist as section headers.
    private struct EventStyle {
        let emoji: String
        let symbolName: String
        let tint: NSColor
    }

    /// One icon per GH reason, matching the row's `eventLabel`. Subject
    /// type drives only the fallback for reasons we don't have a
    /// specific glyph for.
    private static func eventStyle(for n: GitHubNotification) -> EventStyle {
        switch n.reason {
        case "assign":
            return EventStyle(emoji: "🎯", symbolName: "target", tint: .systemRed)
        case "review_requested":
            return EventStyle(emoji: "👀", symbolName: "eye.fill", tint: .systemPurple)
        case "mention", "team_mention":
            return EventStyle(emoji: "✋", symbolName: "at", tint: .systemOrange)
        case "state_change":
            return EventStyle(emoji: "🔄", symbolName: "arrow.triangle.2.circlepath", tint: .systemGray)
        case "author":
            return EventStyle(emoji: "📝", symbolName: "pencil.line", tint: .systemBlue)
        case "comment":
            return EventStyle(emoji: "💬", symbolName: "text.bubble.fill", tint: .systemBlue)
        case "manual":
            return EventStyle(emoji: "🔔", symbolName: "bell.fill", tint: .systemBlue)
        case "subscribed":
            return EventStyle(emoji: "👁", symbolName: "eye.fill", tint: .systemGray)
        case "ci_activity":
            return EventStyle(emoji: "⚙️", symbolName: "gearshape.fill", tint: .systemGray)
        case "push":
            return EventStyle(emoji: "📦", symbolName: "shippingbox.fill", tint: .systemGray)
        default:
            break
        }
        // Unknown reasons: fall back to the subject type so something
        // still renders for newly-introduced reasons we haven't mapped.
        switch n.subject.type {
        case "PullRequest":
            return EventStyle(emoji: "🔀", symbolName: "arrow.triangle.pull", tint: .systemGreen)
        case "Issue":
            return EventStyle(emoji: "🐛", symbolName: "exclamationmark.circle.fill", tint: .systemGreen)
        case "Commit":
            return EventStyle(emoji: "📦", symbolName: "shippingbox.fill", tint: .systemGray)
        case "Release":
            return EventStyle(emoji: "🚀", symbolName: "tag.fill", tint: .systemGray)
        case "Discussion":
            return EventStyle(emoji: "💭", symbolName: "bubble.left.and.bubble.right.fill", tint: .systemTeal)
        default:
            return EventStyle(emoji: "📌", symbolName: "pin.fill", tint: .systemGray)
        }
    }

    /// Renders the row's leading icon (emoji preferred; SF Symbol fallback
    /// for the rare case emoji measurement fails).
    private static func eventImage(style: EventStyle) -> NSImage? {
        emojiImage(style.emoji)
            ?? tintedSymbol(name: style.symbolName, color: style.tint)
    }

    /// Small, muted text used for the standalone hint row above the
    /// notifications list (e.g. "hold ⌥ to mark done"). Matches the
    /// trailing-text style the section headers used to carry.
    private static func menuHint(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ])
    }

    /// Renders an emoji string into an NSImage roughly the height of menu
    /// text. Returns nil if the emoji can't be measured/drawn.
    private static func emojiImage(_ emoji: String, pointSize: CGFloat = 14) -> NSImage? {
        let attrStr = NSAttributedString(
            string: emoji,
            attributes: [.font: NSFont.systemFont(ofSize: pointSize)]
        )
        let textSize = attrStr.size()
        guard textSize.width > 0, textSize.height > 0 else { return nil }
        let image = NSImage(size: textSize)
        image.lockFocus()
        attrStr.draw(at: .zero)
        image.unlockFocus()
        return image
    }

    /// Returns a small, color-tinted SF Symbol image suitable for use as
    /// NSMenuItem.image. Returns nil if the symbol isn't available.
    private static func tintedSymbol(name: String, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: color)
        let combined = sizeConfig.applying(colorConfig)
        return base.withSymbolConfiguration(combined)
    }

    private func headerTitle() -> String {
        if let sync = lastSync {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "Last sync: \(formatter.string(from: sync))"
        }
        return "Never synced"
    }

    /// Returns a banner-permission warning string if Notification Center won't
    /// deliver our alerts, otherwise nil.
    private func notificationStatusWarning() -> String? {
        switch poster.authorizationStatus {
        case .denied:
            return "⚠️ Notifications disabled — open System Settings…"
        case .notDetermined:
            return "⚠️ Awaiting notification permission…"
        case .authorized, .provisional, .ephemeral:
            return nil
        @unknown default:
            return nil
        }
    }

    private func updateBadge() {
        guard let button = statusItem.button else { return }
        button.title = current.isEmpty ? "" : " \(current.count)"
    }

    // MARK: - Polling

    private func scheduleTimer() {
        let interval = UserSettings.pollInterval
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        // Allow firing while menus are open.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        scheduledPollInterval = interval
    }

    @objc private func userDefaultsDidChange() {
        let desired = UserSettings.pollInterval
        guard desired != scheduledPollInterval else { return }
        scheduleTimer()
    }

    @objc private func manualRefresh() {
        Task { await self.refresh() }
    }

    private func refresh() async {
        // Keep the banner-permission warning in the menu honest: the user
        // may have toggled permission in System Settings between polls.
        poster.refreshAuthorizationStatus()
        do {
            // Always pull the full unread inbox so the dropdown mirrors
            // github.com/notifications. seenIds prevents duplicate banners.
            let items = try await fetcher.fetch()
            await MainActor.run {
                self.handleFetched(items)
            }
        } catch {
            await MainActor.run {
                self.lastError = error.localizedDescription
                self.rebuildMenu()
            }
            NSLog("Fetch failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func handleFetched(_ items: [GitHubNotification]) {
        lastError = nil
        lastSync = Date()

        // Newest first: the menu shows the freshest items at the top.
        let sorted = items.sorted { $0.updatedAt > $1.updatedAt }

        // Banner at most AppConfig.bannerCapPerPoll items per poll so a big
        // backlog doesn't flood Notification Center. Items beyond the cap
        // still appear in the dropdown; they're just marked seen so they
        // don't queue up as banner candidates forever.
        //
        // Rewrite seenIds to match the current unread inbox: a thread that
        // re-enters the inbox after being read (e.g. a new comment on a PR
        // we already cleared) will then be treated as unseen again and
        // banner. GitHub reuses thread ids for the lifetime of a PR/issue,
        // so without this prune we'd silently swallow every follow-up.
        //
        // Post oldest-of-the-prefix first so Notification Center stacks the
        // genuinely-newest item on top — the system orders banners by post
        // time, last-posted-on-top.
        let unseen = sorted.filter { !seenIds.contains($0.id) }
        for n in unseen.prefix(UserSettings.bannerCapPerPoll).reversed() {
            poster.post(n)
        }
        seenIds = Set(sorted.map { $0.id })

        current = sorted
        updateBadge()
        rebuildMenu()
    }

    // MARK: - Menu actions

    @MainActor
    @objc private func openNotification(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? GitHubNotification else { return }
        handleOpen(id: n.id, url: n.htmlUrl)
    }

    @MainActor
    @objc private func markAsDone(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? GitHubNotification else { return }
        handleDone(id: n.id)
    }

    /// Drop the thread locally and ask GitHub to mark it as done (archive).
    /// Unlike handleOpen this does NOT open the browser — the user explicitly
    /// chose to dismiss without reading.
    @MainActor
    func handleDone(id: String) {
        current.removeAll { $0.id == id }
        updateBadge()
        rebuildMenu()
        Task {
            do {
                try await fetcher.markDone(threadId: id)
            } catch {
                NSLog("Failed to mark thread \(id) as done: \(error.localizedDescription)")
            }
        }
    }

    /// Shared "user opened a notification" handler. Routes both banner clicks
    /// (via NotificationPoster.onClick) and dropdown clicks. Opens the URL,
    /// dismisses the thread locally so the badge updates immediately, and
    /// asks GitHub to mark the thread as read.
    @MainActor
    func handleOpen(id: String, url: String) {
        if !url.isEmpty, let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
        // Optimistic local dismiss — badge and menu reflect the click instantly.
        current.removeAll { $0.id == id }
        updateBadge()
        rebuildMenu()
        // Tell GitHub. If this fails, the thread will reappear on the next
        // poll, which is acceptable behavior.
        Task {
            do {
                try await fetcher.markRead(threadId: id)
            } catch {
                NSLog("Failed to mark thread \(id) as read: \(error.localizedDescription)")
            }
        }
    }

    @objc private func openAllOnGitHub() {
        if let url = URL(string: "https://github.com/notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @MainActor
    @objc private func openNotificationSettings() {
        let prefsURL = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        NSWorkspace.shared.open(prefsURL)
    }

    // MARK: - NSMenuDelegate

    /// Re-check notification permission every time the user opens the menu, so
    /// toggling Allow Notifications in System Settings reflects without restart.
    func menuWillOpen(_ menu: NSMenu) {
        poster.refreshAuthorizationStatus()
    }
}
