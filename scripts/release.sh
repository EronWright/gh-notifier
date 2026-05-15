#!/usr/bin/env bash
# scripts/release.sh vX.Y.Z
#
# Cuts a release of GH Notifier in one shot:
#   1. validates version format, clean tree, main branch, no existing tag/release
#   2. bumps Info.plist version fields
#   3. commits the bump (with sign-off, honoring format.signOff if set)
#   4. builds GH Notifier.app via ./build-app.sh
#   5. zips the app bundle with `ditto` (preserves codesign + bundle structure)
#   6. tags annotated and pushes main + tag
#   7. creates the GitHub release with the zip attached and auto-generated notes

set -euo pipefail

cd "$(dirname "$0")/.."

# ---------- args ----------
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 vX.Y.Z" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must look like vX.Y.Z (got: $VERSION)" >&2
    exit 1
fi
VNUM="${VERSION#v}"

# ---------- preflight ----------
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is dirty. Commit or stash first." >&2
    exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
    echo "Not on main (currently: $BRANCH)." >&2
    exit 1
fi

if git rev-parse --verify --quiet "refs/tags/$VERSION" >/dev/null; then
    echo "Tag $VERSION already exists locally." >&2
    exit 1
fi

if gh release view "$VERSION" >/dev/null 2>&1; then
    echo "Release $VERSION already exists on GitHub." >&2
    exit 1
fi

# ---------- bump Info.plist ----------
echo "==> Bumping Resources/Info.plist to $VNUM"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleShortVersionString $VNUM" Resources/Info.plist
"$PB" -c "Set :CFBundleVersion $VNUM"            Resources/Info.plist
git add Resources/Info.plist
git commit -s -m "chore: bump version to $VERSION"

# ---------- build ----------
# Universal binary for distribution so Intel Macs can run the release zip too.
# Roughly doubles build time vs the dev cycle (which stays host-arch).
echo "==> Building universal GH Notifier.app (arm64 + x86_64)"
./build-app.sh --universal

# ---------- zip ----------
ZIP_NAME="GH-Notifier-$VERSION.zip"
echo "==> Creating $ZIP_NAME"
rm -f "$ZIP_NAME"
ditto -c -k --keepParent "GH Notifier.app" "$ZIP_NAME"

# ---------- tag & push ----------
echo "==> Tagging $VERSION and pushing"
git tag -a "$VERSION" -m "$VERSION"
git pull --rebase origin main
git push origin main "$VERSION"

# ---------- release ----------
echo "==> Creating GitHub release $VERSION"
gh release create "$VERSION" \
    --generate-notes \
    --title "$VERSION" \
    "$ZIP_NAME"

echo
echo "Released $VERSION"
echo "Local zip: $ZIP_NAME (safe to delete)"
