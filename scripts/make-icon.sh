#!/usr/bin/env bash
# Generates Resources/AppIcon.icns from scratch using:
#   - Swift + AppKit to render a 1024×1024 PNG (SF Symbol on tinted bg)
#   - sips to resample into the 10 standard iconset sizes
#   - iconutil to compile the final .icns
#
# Re-run whenever you want to tweak the icon design.  The .icns is checked
# into Resources/ so a fresh clone gets the icon without running this.
#
# Tweak colors / point size inside the Swift block below.

set -euo pipefail

cd "$(dirname "$0")/.."

ICONSET="build/AppIcon.iconset"
SRC_PNG="build/AppIcon-1024.png"
ICNS="Resources/AppIcon.icns"

mkdir -p "$(dirname "$SRC_PNG")"
mkdir -p Resources

# ---------- 1. render 1024px master via Swift ----------
TMP_SWIFT_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_SWIFT_DIR"' EXIT
SWIFT_FILE="$TMP_SWIFT_DIR/make-icon.swift"

cat > "$SWIFT_FILE" <<'SWIFT'
import AppKit
import Foundation

let outPath = CommandLine.arguments[1]
let canvasSize: CGFloat = 1024
// Apple's icon corner is roughly a squircle; this is a close rounded-rect approximation.
let cornerRadius: CGFloat = canvasSize * 0.224

let canvas = NSImage(size: NSSize(width: canvasSize, height: canvasSize))
canvas.lockFocus()

// --- background: GitHub dark (#24292e) ---
let bgColor = NSColor(red: 0.141, green: 0.161, blue: 0.180, alpha: 1.0)
let rect = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    .addClip()
bgColor.setFill()
rect.fill()

// --- white circle (GH-avatar-style disc) ---
let circleRadius: CGFloat = 390
let circleRect = NSRect(
    x: (canvasSize - circleRadius * 2) / 2,
    y: (canvasSize - circleRadius * 2) / 2,
    width:  circleRadius * 2,
    height: circleRadius * 2
)
NSColor.white.setFill()
NSBezierPath(ovalIn: circleRect).fill()

// --- bell silhouette: dark on white circle, red badge ---
guard let bell = NSImage(systemSymbolName: "bell.badge.fill",
                         accessibilityDescription: nil) else {
    fputs("SF Symbol 'bell.badge.fill' not available\n", stderr)
    exit(1)
}
// paletteColors layer order for bell.badge.fill: [badge, bell body, badge outline].
// Bell body = GitHub dark (silhouette on white circle), badge = red, outline = white.
let config = NSImage.SymbolConfiguration(pointSize: 480, weight: .medium)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed, bgColor, .white]))
guard let symbol = bell.withSymbolConfiguration(config) else {
    fputs("Failed to apply SymbolConfiguration\n", stderr)
    exit(1)
}

let symRect = NSRect(
    x: (canvasSize - symbol.size.width)  / 2,
    y: (canvasSize - symbol.size.height) / 2,
    width:  symbol.size.width,
    height: symbol.size.height
)
symbol.draw(in: symRect)

canvas.unlockFocus()

guard let tiff = canvas.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
SWIFT

echo "==> Rendering 1024×1024 master PNG"
swift "$SWIFT_FILE" "$SRC_PNG"

# ---------- 2. expand into iconset ----------
echo "==> Generating iconset at $ICONSET"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16   16   "$SRC_PNG" --out "$ICONSET/icon_16x16.png"      > /dev/null
sips -z 32   32   "$SRC_PNG" --out "$ICONSET/icon_16x16@2x.png"   > /dev/null
sips -z 32   32   "$SRC_PNG" --out "$ICONSET/icon_32x32.png"      > /dev/null
sips -z 64   64   "$SRC_PNG" --out "$ICONSET/icon_32x32@2x.png"   > /dev/null
sips -z 128  128  "$SRC_PNG" --out "$ICONSET/icon_128x128.png"    > /dev/null
sips -z 256  256  "$SRC_PNG" --out "$ICONSET/icon_128x128@2x.png" > /dev/null
sips -z 256  256  "$SRC_PNG" --out "$ICONSET/icon_256x256.png"    > /dev/null
sips -z 512  512  "$SRC_PNG" --out "$ICONSET/icon_256x256@2x.png" > /dev/null
sips -z 512  512  "$SRC_PNG" --out "$ICONSET/icon_512x512.png"    > /dev/null
sips -z 1024 1024 "$SRC_PNG" --out "$ICONSET/icon_512x512@2x.png" > /dev/null

# ---------- 3. compile .icns ----------
echo "==> Compiling $ICNS"
iconutil -c icns "$ICONSET" -o "$ICNS"

echo
echo "Wrote $ICNS"
echo "Run ./build-app.sh --install (or 'app: rebuild & relaunch') to see it live."
