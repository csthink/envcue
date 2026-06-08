#!/usr/bin/env bash
# Assemble EnvCue.app from the SwiftPM release build (T6.2 packaging).
#
# SwiftPM produces a bare executable; this wraps it as a menu-bar .app bundle
# (LSUIElement = menu-bar agent, no Dock icon) with an Info.plist and an icns, so the
# SAME binary serves both modes: CLI when invoked with a subcommand (argv) and the GUI
# MenuBarExtra when launched with none. The Homebrew formula symlinks the inner binary
# onto PATH as `envcue` (docs/tasks.md T6.2), so `brew install` gives both the CLI and
# the app from one bundle.
#
# Usage:
#   scripts/package-app.sh [VERSION]        # VERSION defaults to 0.1.0; the release CI
#                                           # passes the git tag (e.g. v1.2.3 -> 1.2.3)
# Env:
#   ENVCUE_APP_OUT   output bundle path (default .build/EnvCue.app)
#   DEVELOPER_DIR    honored if already set; release/CI should point at Xcode 26 for the
#                    full macOS 26 SDK (the Liquid Glass APIs). A bare CommandLineTools
#                    toolchain may also work but is not the supported release toolchain.
set -euo pipefail

VERSION="${1:-0.1.0}"
BUNDLE_ID="dev.mars.envcue"     # matches the Keychain service; independent namespaces
MIN_OS="26.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${ENVCUE_APP_OUT:-.build/EnvCue.app}"
ICON_SRC="assets/icon/envcue-icon-1024.png"
[ -f "$ICON_SRC" ] || { echo "missing icon source: $ICON_SRC" >&2; exit 1; }

echo "==> swift build -c release ${ENVCUE_SWIFT_BUILD_FLAGS:-}"
# Extra build flags from the caller (the Homebrew formula passes --disable-sandbox so
# SwiftPM can fetch dependencies inside brew's no-network build sandbox). Intentional
# word-splitting of the flag string.
# shellcheck disable=SC2086
swift build -c release ${ENVCUE_SWIFT_BUILD_FLAGS:-}
BIN=".build/release/envcue"
[ -x "$BIN" ] || { echo "build did not produce $BIN" >&2; exit 1; }

echo "==> assembling $OUT (version $VERSION)"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/envcue"

# icns from the static 1024 artwork (PROPOSAL-003). iconutil needs a full iconset; build
# every standard size + @2x, with the untouched 1024 as the 512@2x representation.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z "$sz" "$sz"         "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png"    >/dev/null
  sips -z $((sz * 2)) $((sz * 2)) "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
cp "$ICON_SRC" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"
# Ship the 1024 PNG too: AboutPresenter hands it to the standard About panel directly for
# a crisp icon (the panel otherwise renders a low-res placeholder).
cp "$ICON_SRC" "$OUT/Contents/Resources/envcue-icon-1024.png"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>EnvCue</string>
	<key>CFBundleDisplayName</key>
	<string>EnvCue</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleExecutable</key>
	<string>envcue</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_OS}</string>
	<key>LSUIElement</key>
	<true/>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

echo "==> sanity checks"
"$OUT/Contents/MacOS/envcue" --help >/dev/null 2>&1 && echo "  CLI entry ok" || { echo "  CLI entry FAILED" >&2; exit 1; }
test -f "$OUT/Contents/Resources/AppIcon.icns" && echo "  icns present"
printf "  version: "; /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$OUT/Contents/Info.plist"
printf "  LSUIElement: "; /usr/libexec/PlistBuddy -c "Print :LSUIElement" "$OUT/Contents/Info.plist"

echo "==> done: $OUT"
