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
            // Render each configured group: section header, up to `cap` items
            // (oldest first, since `current` is already sorted that way), then
            // an overflow link if there are more we couldn't fit.
            var firstGroup = true
            for group in AppConfig.menuGroups {
                let inGroup = current.filter { group.reasons.contains($0.reason) }
                guard !inGroup.isEmpty else { continue }

                if !firstGroup { menu.addItem(.separator()) }
                firstGroup = false

                let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                header.attributedTitle = Self.sectionHeaderTitle(
                    primary: "\(group.title.uppercased())  ·  \(inGroup.count)",
                    trailing: "hold ⌥ to mark done"
                )
                header.isEnabled = false
                menu.addItem(header)

                for n in inGroup.prefix(group.cap) {
                    addNotificationItems(for: n, in: group)
                }

                let overflow = inGroup.count - group.cap
                if overflow > 0, let query = group.overflowQuery {
                    let label = "→ \(overflow) more on GitHub"
                    let item = NSMenuItem(title: label,
                                          action: #selector(openOverflow(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.representedObject = query
                    menu.addItem(item)
                }
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

    /// Adds a paired primary + ⌥-alternate row for a single notification,
    /// tinted with the icon of its parent group.
    private func addNotificationItems(for n: GitHubNotification, in group: ReasonGroup) {
        // owner/repo #1234 · Event — Subject title  (or @abc1234 for commits)
        // The event tag distinguishes a review from a comment from a PR open
        // when several land in the same reason group (esp. Participating).
        let ref = n.subjectIdentifierLabel
        let repoRef = ref.isEmpty
            ? n.repository.fullName
            : "\(n.repository.fullName) \(ref)"
        let title = "\(repoRef) · \(n.eventLabel) — \(n.subject.title)"

        let primary = NSMenuItem(title: title,
                                 action: #selector(openNotification(_:)),
                                 keyEquivalent: "")
        primary.target = self
        primary.representedObject = n
        primary.keyEquivalentModifierMask = []
        primary.image = Self.categoryImage(for: group)
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

    /// Picks the leading-icon image for a group: emoji if it renders, SF
    /// Symbol fallback otherwise.
    private static func categoryImage(for group: ReasonGroup) -> NSImage? {
        emojiImage(group.emoji)
            ?? tintedSymbol(name: group.symbolName, color: group.tintColor)
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

    /// Builds the attributed title for a section header: bold uppercased
    /// `primary` on the left, lighter `trailing` text right-aligned via a
    /// right tab stop.
    private static func sectionHeaderTitle(primary: String, trailing: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        // Right-aligned tab at a wide-but-not-huge location. NSMenu will
        // expand the menu to fit this tab stop, so the hint always sits
        // flush-right inside a reasonably-wide dropdown.
        paragraph.tabStops = [
            NSTextTab(textAlignment: .right, location: 480, options: [:])
        ]

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: primary,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.5,
                .paragraphStyle: paragraph
            ]
        ))
        result.append(NSAttributedString(
            string: "\t" + trailing,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph
            ]
        ))
        return result
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

        // Oldest first, matching how GitHub's notifications inbox stacks them
        // (most recently touched at the bottom).
        let sorted = items.sorted { $0.updatedAt < $1.updatedAt }

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
        let unseen = sorted.filter { !seenIds.contains($0.id) }
        for n in unseen.prefix(UserSettings.bannerCapPerPoll) {
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

    /// Opens github.com/notifications filtered to a particular query, e.g.
    /// "is:unread reason:review-requested". Used by the per-group overflow rows.
    @objc private func openOverflow(_ sender: NSMenuItem) {
        guard let query = sender.representedObject as? String,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://github.com/notifications?query=\(encoded)")
        else { return }
        NSWorkspace.shared.open(url)
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
