#!/bin/bash
# Installs Jot (floating notes, synced end-to-end encrypted through your own notes server) on this Mac:
#   curl -fsSL https://<your-server>/mac/install.sh | bash
# (publish.sh writes the server address into the published copy of this script)
# Re-running it updates Jot; Jot also updates itself (it runs this with JOT_AUTO=1, see JotApp.swift runUpdate). Uninstall:
#   launchctl bootout gui/$(id -u)/app.jot.mac; rm -rf ~/Applications/Jot.app ~/Library/LaunchAgents/app.jot.mac.plist "$HOME/Library/Application Support/Jot"
set -euo pipefail
O=${JOT_ORIGIN:-__JOT_ORIGIN__}
APP="$HOME/Applications/Jot.app"
AGENT="$HOME/Library/LaunchAgents/app.jot.mac.plist"
FILES="JotCore.swift JotModel.swift JotEditor.swift JotMedia.swift JotViews.swift JotGraph.swift JotApp.swift"

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Jot is built from source on this Mac, which needs Apple's Command Line Tools (one time)."
  xcode-select --install 2>/dev/null || true
  echo "Finish the install window that just opened, then run the same command again."
  exit 1
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "Downloading the source…"
for f in $FILES version.txt; do curl -fsSL "$O/mac/$f" -o "$TMP/$f"; done
RES="highlight.min.js jothl.js AppIcon.icns"    # code-block colouring (highlight.js, BSD-3) + app icon; optional
for f in $RES; do curl -fsSL "$O/mac/$f" -o "$TMP/$f" || rm -f "$TMP/$f"; done
VER=$(cat "$TMP/version.txt")
echo "Building Jot $VER (about a minute)…"
( cd "$TMP" && xcrun swiftc -O -swift-version 5 -parse-as-library $FILES -o Jot ) 2>&1 | grep -v "warning:" | grep -E "error|^/" || true
[ -x "$TMP/Jot" ] || { echo; echo "Build failed. Copy the errors above and send them over."; exit 1; }
"$TMP/Jot" --selftest

# build the new bundle next to the old one, then swap (the running Jot keeps working until it is restarted)
NEW="$APP.new"
rm -rf "$NEW" "$APP.old"
mkdir -p "$NEW/Contents/MacOS" "$HOME/Library/LaunchAgents"
cp "$TMP/Jot" "$NEW/Contents/MacOS/Jot"
mkdir -p "$NEW/Contents/Resources"
for f in $RES; do [ -f "$TMP/$f" ] && cp "$TMP/$f" "$NEW/Contents/Resources/" || true; done
cat > "$NEW/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.jot.mac</string>
  <key>CFBundleName</key><string>Jot</string>
  <key>CFBundleExecutable</key><string>Jot</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>JotOrigin</key><string>$O</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$NEW" >/dev/null 2>&1 || true
[ -d "$APP" ] && mv "$APP" "$APP.old"
mv "$NEW" "$APP"
rm -rf "$APP.old"
touch "$APP"                                    # so Finder picks up a new icon

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>app.jot.mac</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Jot</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
if [ "${JOT_AUTO:-}" = 1 ] && launchctl print "gui/$(id -u)/app.jot.mac" >/dev/null 2>&1; then
  echo "Jot $VER installed, restarting it"; rm -rf "$TMP"
  launchctl kickstart -k "gui/$(id -u)/app.jot.mac"     # ends the old Jot (and this script, its child); launchd starts the new one
  exit 0
fi
launchctl bootout "gui/$(id -u)/app.jot.mac" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo
echo "Jot $VER is running: press ⌥N (or click the ✎ icon in the menu bar) and enter your passphrase."
echo "It starts by itself when you log in and updates itself (menu-bar icon → Update Automatically)."
