#!/bin/bash
# Builds Resources/Anole.icns from Resources/icon-1024.png.
#
# macOS expects ten variants: every logical size exists at single and double
# density. iconutil rejects the iconset if a single one is missing.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="Resources/icon-1024.png"
ICONSET="Resources/Anole.iconset"
[ -f "$SOURCE" ] || { echo "Missing source: $SOURCE"; exit 1; }

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

emit() {  # emit <size in pixels> <file name>
    sips -z "$1" "$1" "$SOURCE" --out "$ICONSET/$2" >/dev/null 2>&1
}

emit 16   icon_16x16.png
emit 32   icon_16x16@2x.png
emit 32   icon_32x32.png
emit 64   icon_32x32@2x.png
emit 128  icon_128x128.png
emit 256  icon_128x128@2x.png
emit 256  icon_256x256.png
emit 512  icon_256x256@2x.png
emit 512  icon_512x512.png
emit 1024 icon_512x512@2x.png

iconutil --convert icns "$ICONSET" --output Resources/Anole.icns
rm -rf "$ICONSET"
echo "==> Resources/Anole.icns ($(du -h Resources/Anole.icns | cut -f1))"
