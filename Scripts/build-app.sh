#!/bin/bash
# Builds Anole.app from the SPM product.
#
# SwiftPM produces a bare executable; a SwiftUI app needs a bundle with an
# Info.plist to get a window, a Dock icon and keyboard focus.
# So we assemble the bundle by hand, then sign it ad-hoc (enough locally).
set -euo pipefail

CONFIG="${1:-release}"
cd "$(dirname "$0")/.."

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Anole"
APP="build/Anole.app"

echo "==> Assembling the bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Anole"

# The Python helper ships with the app. We do not go through `resources:` in
# Package.swift: the generated accessor looks for the bundle next to the
# executable and breaks as soon as .build disappears.
cp Helper/anoled.py "$APP/Contents/Resources/anoled.py"

# Icon: built on demand if missing, so that a clone of the repository does not
# need a manual step.
[ -f Resources/Anole.icns ] || ./Scripts/make-icns.sh
cp Resources/Anole.icns "$APP/Contents/Resources/Anole.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Anole</string>
    <key>CFBundleDisplayName</key>       <string>Anole</string>
    <key>CFBundleExecutable</key>        <string>Anole</string>
    <key>CFBundleIconFile</key>          <string>Anole</string>
    <key>CFBundleIdentifier</key>        <string>fr.laatortuejaune.anole</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>15.0</string>
    <!-- Regular application with a window and a menu, not a background agent. -->
    <key>LSUIElement</key>               <false/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSLocationUsageDescription</key>
    <string>Anole shows your real location on the map, to compare it with the simulated location and use it as a starting point.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Anole shows your real location on the map, to compare it with the simulated location and use it as a starting point.</string>
    <key>NSHumanReadableCopyright</key>  <string>Copyright (C) 2026 laatortuejaune - GPL-3.0-or-later</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "==> Ready: $APP"
