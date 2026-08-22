#!/bin/bash
# Runs the core tests.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test "$@"
