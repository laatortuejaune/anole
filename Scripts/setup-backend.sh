#!/bin/bash
# Installs pymobiledevice3 in a venv dedicated to the app.
#
# Two deliberate choices:
#  - Homebrew's Python, never /usr/bin/python3: Apple's one links against LibreSSL,
#    which does not handle the TLS-PSK cipher suites used by the iOS 17+ tunnel.
#  - Fixed path outside the project: the app must find the binary even when launched
#    from the Finder, where PATH is minimal.
set -euo pipefail

PYTHON=/opt/homebrew/bin/python3
VENV="$HOME/.local/share/anole/venv"
PINNED="pymobiledevice3==10.10.3"

[ -x "$PYTHON" ] || { echo "Homebrew Python not found: $PYTHON"; exit 1; }

echo "==> venv: $VENV"
mkdir -p "$(dirname "$VENV")"
[ -d "$VENV" ] || "$PYTHON" -m venv "$VENV"

echo "==> installing $PINNED"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet "$PINNED"

echo "==> version"
"$VENV/bin/pymobiledevice3" version
echo "==> ready: $VENV/bin/pymobiledevice3"
