#!/usr/bin/env bash
# dev.sh — build and launch the Tenon PoC app.
#
# Opens a window, so it needs a GUI session. Any arguments are forwarded to the
# app; environment overrides work too, e.g.:
#   TENON_STUB_TERMINAL=1 ./dev.sh   # stub terminal pane, no PTY
#   TENON_PLUGINS_DIR=/path ./dev.sh # point the host at a different plugins dir
set -euo pipefail

cd "$(dirname "$0")/poc"

# One-time (per clone) fetch of the pinned GhosttyKit.xcframework (~130 MB).
# The setup script is idempotent — a no-op once the framework is already in place.
./scripts/setup-ghosttykit.sh

echo "==> Launching Tenon (swift run tenon)"
exec swift run tenon "$@"
