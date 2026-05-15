# GH Notifier

A tiny macOS menu bar app that watches your GitHub notifications via the `gh` CLI.

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2?logo=github)](https://github.com/sponsors/EronWright)

<img width="533" height="167" alt="image" src="https://github.com/user-attachments/assets/aa75e7ec-fd6e-4d9e-96ae-ff036e6ca64d" />

<img width="900" height="230" alt="image" src="https://github.com/user-attachments/assets/bc8c07f8-b641-4233-b461-b72d1b6c34e0" />


## Download & install

Grab the latest zip from [Releases](https://github.com/EronWright/gh-notifier/releases), unzip, and drag `GH Notifier.app` to `/Applications`. Then:

```sh
open -a "GH Notifier"
```

macOS will prompt you to grant Notification permission. Accept.

**Requirements (release build):**
- macOS 12 (Monterey) or later
- [`gh`](https://cli.github.com) authenticated against your GitHub account:
  ```sh
  brew install gh
  gh auth login
  ```

No Xcode required.

## What it surfaces

It polls every 15 minutes (and on demand via "Refresh Now") and pulls your full unread notifications inbox, filtered to the reasons that actually matter day-to-day:

- someone reviews or comments on a PR or issue **you authored** (`reason: author`)
- you are **@-mentioned** (`reason: mention`)
- someone **requests a review** from you (`reason: review_requested`)

The filtered set shows up two ways:

1. **Menu bar dropdown** — a faithful mirror of your unread inbox at github.com/notifications, grouped by reason. Section names and leading icons match GitHub's notification filter sidebar:
   - 🎯 **Assigned** — an issue or PR is assigned to you (`assign`)
   - 👀 **Review requested** — someone wants you to review (`review_requested`)
   - ✋ **Mentioned** — you or your team were tagged (`mention`, `team_mention`)
   - 💬 **Participating** — activity on threads you authored or are subscribed to (`author`, `comment`, `state_change`)

   Each section caps at 10 rows; anything beyond shows up as `→ N more on GitHub` which opens the matching filter on github.com/notifications. Within each section items are oldest-first. Rows are labeled `owner/repo #1234 — Subject title` (commits use `@abc1234`), prefixed with the section's emoji. Section headers carry a right-aligned `hold ⌥ to mark done` hint. The bell icon shows the total count.
2. **Notification Center banners** — posted for items the app hasn't shown before, deduped by thread id (persisted in `UserDefaults`), and **capped at 5 banners per poll** so coming back from vacation doesn't blast you with 30 toasts. Anything past the cap silently appears in the dropdown.

## Actions

| Gesture                          | What it does                                                                                                    | API call                                  |
|----------------------------------|-----------------------------------------------------------------------------------------------------------------|-------------------------------------------|
| **Click** a row or a banner      | Opens the PR/issue/commit on github.com, drops it from the dropdown, marks the thread **read** on GitHub.       | `PATCH /notifications/threads/{id}`        |
| **⌥-click** a row in the dropdown | Marks the thread **done** (archived to GitHub's "Done" filter). Does *not* open the browser.                    | `DELETE /notifications/threads/{id}`       |
| **Refresh Now**                  | Manual poll. Same code path as the 15-minute timer.                                                              | `GET /notifications?all=false`             |

The dropdown shows a hint row (`Hold ⌥ to mark items as done`) whenever you have unread items, and each row has a tooltip explaining the modifier on hover.

If GitHub or the app loses sync (e.g. the PATCH/DELETE fails on a flaky connection), the next poll will pull the unread set fresh and the thread reappears — same outcome as if you'd never clicked it.

## Build from source

**Additional requirements:**
- Xcode (for universal binary builds) or Xcode Command Line Tools (`xcode-select --install`) for host-arch builds

From this folder:

```sh
./build-app.sh --install
open -a "GH Notifier"
```

That:

1. compiles the SwiftPM executable in release mode,
2. wraps it in `GH Notifier.app` with the `Info.plist` in `Resources/`,
3. codesigns the bundle,
4. copies it to `/Applications/`.

If you'd rather build without installing:

```sh
./build-app.sh
open "./GH Notifier.app"
```

## Start at login

Drag `GH Notifier.app` into **System Settings → General → Login Items** under "Open at Login".

## Configuration

### Settings dialog

Open **Settings…** (⌘,) from the menu bar dropdown to adjust the runtime-configurable options:

| Setting | Default | Notes |
|---------|---------|-------|
| Poll interval | 15 minutes | How often the app checks for new notifications. Options: 5 min – 24 hours. |
| Banner cap | 5 per poll | Max Notification Center banners fired per poll. Items beyond the cap still appear in the dropdown silently. Prevents the "you've been away" toast storm. |
| Max pages | 5 per poll | Pages of 50 notifications fetched per poll (upper bound: 250 items, ~5 API calls). |

Settings are persisted in `UserDefaults` under `com.eronwright.gh-notifier` and take effect immediately (poll interval reschedules the timer on change).

### Advanced (source edit)

Structural settings not exposed in the UI live in [`Sources/GHNotifier/AppConfig.swift`](Sources/GHNotifier/AppConfig.swift):

| Setting              | Default                          | Notes                                                                 |
|----------------------|----------------------------------|-----------------------------------------------------------------------|
| `menuGroups`         | `[Assigned 🎯, Review requested 👀, Mentioned ✋, Participating 💬]` | Ordered dropdown sections, named and emoji-iconed to match GitHub's filter sidebar. Each carries its own `reasons`, `cap` (rows shown before overflow), and `overflowQuery` (passed to `github.com/notifications?query=`). Reasons not in any group are dropped entirely. |
| `bundleIdentifier`   | `com.eronwright.gh-notifier`     | Must match `CFBundleIdentifier` in `Resources/Info.plist`.            |

`allowedReasons` is derived from `menuGroups` automatically — no need to keep them in sync. Each group caps at 10 by default; bump in `AppConfig.menuGroups` if you want more rows before overflow kicks in.

After editing, rerun `./build-app.sh --install`.

## How it works

```
┌──────────────┐  every 15m   ┌─────────────────────┐
│  AppDelegate │ ───────────► │ NotificationFetcher │
│  (menu bar)  │ Refresh Now  │   gh api ...        │
└──────┬───────┘              └──────────┬──────────┘
       │                                 │ unread JSON
       │                                 ▼
       │                       filter reasons in
       │                        AppConfig.allowedReasons
       │                                 │
       ▼                                 ▼
┌──────────────┐              ┌─────────────────────┐
│   NSMenu     │              │ NotificationPoster  │
│ (dropdown)   │              │ UNUserNotification… │
└──────┬───────┘              └─────────────────────┘
       │ click             ⌥-click
       ▼                     ▼
PATCH notifications/threads/{id}   DELETE notifications/threads/{id}
        (mark read)                       (mark done / archive)
```

- Each poll fetches the **complete unread inbox** (`gh api notifications -f all=false`). No `since` filter — the dropdown is meant to mirror github.com/notifications, not just show deltas.
- A set of seen ids (capped at 2,000, persisted in `UserDefaults` under `ghnotifier.seenIds.v1`) prevents duplicate banners when an unread item gets touched again before you've cleared it.
- Notification Center banners require the binary to live in an `.app` with a stable `CFBundleIdentifier`; that's what `build-app.sh` produces. There is **no fallback channel** — if macOS refuses to deliver, the dropdown header surfaces `⚠️ Notifications disabled…` and clicking that row opens System Settings → Notifications.
- "Mark read" uses `PATCH /notifications/threads/{id}`. "Mark done" (`DELETE …`) archives the thread to GitHub's "Done" filter.

## Troubleshooting

**Dropdown says "Notifications disabled".** macOS won't deliver banners until you flip the switch in **System Settings → Notifications → GH Notifier**. Click the warning row in the dropdown to jump there. If GH Notifier doesn't appear in the list, run `./scripts/re-register-app.sh` (or the VS Code task `app: re-register with LaunchServices`) — that nudges LaunchServices to re-discover the bundle so the next launch can register for notifications.

**Menu bar says "Error: ... gh exited with code 4".** Run `gh auth status`; you probably need to re-authenticate.

**"Could not find the `gh` CLI".** Install it (`brew install gh`) — the app probes `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, and `~/.local/bin` before falling back to `command -v gh` via zsh.

**I want to test it but I don't have any open notifications.** Drop `AppConfig.pollInterval` to `60` (one minute), comment on one of your own PRs from another account or browser session, then hit "Refresh Now". Set the interval back to `15 * 60` when you're done.

**Fresh start.** `./scripts/re-register-app.sh` re-registers the bundle. The VS Code task `app: reset state` wipes `seenIds`/`lastSync` so the next launch behaves like a first run (it'll banner everything currently unread).

## Source layout

```
GH Notifications/
├── Package.swift
├── build-app.sh
├── README.md
├── .vscode/
│   ├── launch.json
│   └── tasks.json
├── Resources/
│   ├── AppIcon.icns
│   └── Info.plist
├── scripts/
│   ├── make-icon.sh
│   ├── re-register-app.sh
│   └── release.sh
└── Sources/
    └── GHNotifier/
        ├── main.swift
        ├── AppConfig.swift
        ├── AppDelegate.swift
        ├── GitHubNotification.swift
        ├── NotificationFetcher.swift
        └── NotificationPoster.swift
```
