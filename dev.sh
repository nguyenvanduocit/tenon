#!/usr/bin/env bash
# dev.sh — build and launch the Tenon PoC app.
#
# Opens a window, so it needs a GUI session. Any arguments are forwarded to the
# app; environment overrides work too, e.g.:
#   TENON_STUB_TERMINAL=1 ./dev.sh   # stub terminal pane, no PTY
#   TENON_PLUGINS_DIR=/path ./dev.sh # point the host at a different plugins dir
#   CLEAN=1 ./dev.sh                 # discard both build trees first (deps survive)
set -euo pipefail

cd "$(dirname "$0")/poc"

# Collect duplicate build trees before making more of them. Keeps this run's
# incremental caches, so the edit-run loop stays seconds long.
if [ -n "${CLEAN:-}" ]; then
    DEEP=1 ./scripts/prune-build-cache.sh
else
    ./scripts/prune-build-cache.sh
fi

# One-time (per clone) fetch of the pinned GhosttyKit.xcframework (~130 MB).
# The setup script is idempotent — a no-op once the framework is already in place.
./scripts/setup-ghosttykit.sh

# Read plugins straight from the source tree so every plugin — including ones added
# this session — and every edit show up immediately. Without this the app falls back
# to the one-time seed under ~/Library/Application Support/Tenon/plugins, which only an
# installed build should use and which never gains plugins added after it was first seeded.
export TENON_PLUGINS_DIR="${TENON_PLUGINS_DIR:-$PWD/plugins}"

# The app is a singleton: a plain `swift run` would just focus the instance that is
# already running and exit(0), leaving the OLD build in memory — so your edits never
# show. Kill any running instance and clear its stale control socket first, so this
# run actually replaces it with the freshly built code.
pkill -f 'debug/tenon' 2>/dev/null || true
rm -f "/tmp/tenon-$(id -u)/tenon.sock" 2>/dev/null || true
sleep 0.3

echo "==> Launching Tenon (swift run tenon, plugins: $TENON_PLUGINS_DIR)"
exec swift run tenon "$@"
