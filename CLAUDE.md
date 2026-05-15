# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GH Notifier is a macOS menu bar app (Swift, SwiftPM, macOS 12+) that polls GitHub notifications via the `gh` CLI every 15 minutes and surfaces unread items in a status-bar dropdown. It posts macOS Notification Center banners for new items (capped at 5 per poll).

**Runtime requirement:** `gh` CLI must be installed and authenticated.

## Build & Run

```bash
# Dev build (host architecture only)
./build-app.sh

# Release build (universal binary, arm64 + x86_64)
./build-app.sh --universal

# Build and install to /Applications/
./build-app.sh --install

# Launch after install
open -a "GH Notifier"
```

The build script assembles the `.app` bundle (required for Notification Center delivery) and codesigns it with the "GH Notifier Code Signing" identity from the login keychain (falls back to ad-hoc on machines without it).

## Testing

```bash
swift test
```

No tests currently exist; the SwiftPM structure is ready but no test target is defined.

## Release

```bash
./scripts/release.sh vX.Y.Z
```

Automated: bumps `Resources/Info.plist` version fields, builds universal binary, zips, commits, tags, and creates a GitHub release with `gh release create --generate-notes`.

## Architecture

```
main.swift → NSApplication (accessory policy, no Dock icon)
  └── AppDelegate
        ├── NSStatusItem (menu bar icon + badge)
        ├── Timer (15-min poll)
        ├── NotificationFetcher  — executes `gh api notifications`, paginates (5×50), filters by reason, marks read/done
        ├── NotificationPoster   — posts UNUserNotificationCenter banners (≤5 per poll), handles click callbacks
        └── NSMenu               — groups defined in AppConfig, rebuilt on each poll result
```

**Key files:**

| File | Role |
|------|------|
| `Sources/GHNotifier/AppDelegate.swift` | Menu bar lifecycle, timer, state, menu actions |
| `Sources/GHNotifier/AppConfig.swift` | All tunable settings (poll interval, banner cap, menu groups, UserDefaults keys) |
| `Sources/GHNotifier/NotificationFetcher.swift` | GitHub API calls via `gh api`, filters, mark-read/done |
| `Sources/GHNotifier/NotificationPoster.swift` | Notification Center integration |
| `Sources/GHNotifier/GitHubNotification.swift` | Codable model for GitHub notification API |
| `Resources/Info.plist` | Bundle metadata (identifier, version, min OS) |

## Configuration

All tuning lives in `AppConfig.swift`. Edit and rebuild/reinstall:

- `pollInterval` — default 900 s (15 min)
- `bannerCapPerPoll` — default 5 (prevents notification floods after absence)
- `menuGroups` — sections shown in the dropdown, each with an emoji, allowed reasons, and an overflow query
- `bundleIdentifier` — must match `CFBundleIdentifier` in `Info.plist`
- `seenIdsKey` / `lastSyncKey` — UserDefaults keys (dedup ring-buffer capped at 2,000 IDs)

## Utilities

- `scripts/re-register-app.sh` — nudges LaunchServices to re-discover the app; rarely needed since switching to a stable signing cert
- `scripts/make-icon.sh` — renders `Resources/AppIcon.icns` from scratch (Swift + AppKit, SF Symbols); re-run to tweak colors/size
- `.vscode/tasks.json` — 14 VS Code tasks covering build, kill, relaunch, reset state, re-register, open System Settings, and release
