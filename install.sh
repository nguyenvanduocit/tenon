#!/usr/bin/env bash
# install.sh — build a release Tenon.app and install it onto this machine,
# replacing any previously installed copy.
#
# The app resolves plugins/, ghostty/ and terminfo/ through
# `Bundle.main.resourceURL`. Xcode builds that resource-bearing app bundle;
# SwiftPM builds the standalone CLI that the installer embeds into it.
#
# Run it from anywhere, including a Tenon pane: replacing the app the caller is running
# inside is detected here and handed to a detached installer, since these steps kill that
# caller. See scripts/install-replace.sh.
#
# Usage:
#   ./install.sh            # build Release, install to /Applications, replace old
#   ./install.sh --launch   # ...and open Tenon after installing
#
# Overrides (env):
#   APP_DEST=/some/dir      # install destination (default /Applications)
#   CONFIGURATION=Debug     # xcodebuild configuration (default Release)
#   ARCHS=x86_64            # override the single arch (default: this machine's arch)
#   CLEAN=1                 # discard both build trees first (dependencies survive)
#   INSTALL_APP_NAME=...    # installed bundle name (default Tenon.app)
#   INSTALL_DISPLAY_NAME=... # installed app name (default Tenon)
#   INSTALL_BUNDLE_ID=...   # installed bundle identifier (default dev.tenon.app)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

APP_DEST="${APP_DEST:-/Applications}"
CONFIGURATION="${CONFIGURATION:-Release}"
# Build only for this machine's architecture — a local install has no reason to
# carry the other slice (x86_64 is dead weight on Apple Silicon, and vice versa).
ARCHS="${ARCHS:-$(uname -m)}"
if [[ "$ARCHS" =~ [[:space:]] ]]; then
    echo "error: ARCHS must name exactly one architecture without whitespace (for example, ARCHS=x86_64)" >&2
    exit 1
fi
# One derived data path for every configuration, and the CLI compiles in the same
# SwiftPM scratch as `swift build` — so the dependency graph is checked out once and
# the module cache is kept once. See scripts/prune-build-cache.sh.
DERIVED_DATA="$REPO_ROOT/.build/xcode"     # inside the gitignored .build/
BUILT_APP_NAME="Tenon.app"
APP_NAME="${INSTALL_APP_NAME:-Tenon.app}"
DISPLAY_NAME="${INSTALL_DISPLAY_NAME:-Tenon}"
BUNDLE_ID="${INSTALL_BUNDLE_ID:-dev.tenon.app}"

case "$APP_NAME" in
    */*)
        echo "error: INSTALL_APP_NAME must be a bundle name, not a path" >&2
        exit 1
        ;;
    *.app) ;;
    *)
        echo "error: INSTALL_APP_NAME must end in .app" >&2
        exit 1
        ;;
esac
if [ -z "$DISPLAY_NAME" ]; then
    echo "error: INSTALL_DISPLAY_NAME must not be empty" >&2
    exit 1
fi
case "$BUNDLE_ID" in
    dev.tenon.app|dev.tenon.app.staging) ;;
    *)
        echo "error: INSTALL_BUNDLE_ID must be dev.tenon.app or dev.tenon.app.staging" >&2
        exit 1
        ;;
esac

case "$CONFIGURATION" in
    Release)
        SWIFT_CONFIGURATION="release"
        ;;
    Debug)
        SWIFT_CONFIGURATION="debug"
        ;;
    *)
        echo "error: unsupported CONFIGURATION '$CONFIGURATION'; expected Release or Debug" >&2
        exit 1
        ;;
esac

LAUNCH=0
[ "${1:-}" = "--launch" ] && LAUNCH=1

DEST_APP="$APP_DEST/$APP_NAME"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }

# Is this shell a descendant of the very app that is about to be replaced?
#
# Asked of the process tree rather than of an environment variable, because an env marker
# is inherited by anything the pane later spawns — an ssh session, a container, a shell
# that outlived the app — and would claim a self-install where there is none. Ancestry is
# the actual question: only a real descendant dies when that process is killed.
running_inside_target_bundle() {
    local target="$DEST_APP/Contents/MacOS/Tenon"
    local pid=$$ comm

    while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
        comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
        [ "$comm" = "$target" ] && return 0
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    done
    return 1
}

SELF_INSTALL=0
if running_inside_target_bundle; then
    SELF_INSTALL=1
    # Forced, not offered: the caller's own app is about to be quit, and leaving it shut
    # would strand the person who asked for the install with no window to come back to.
    LAUNCH=1
    # Beside the control socket, for the same reason it is there: a stable per-user path
    # that can be named before the app restarts and still found afterwards, from a pane
    # that did not exist when the install began.
    INSTALL_LOG_DIR="/tmp/tenon-$(id -u)"
    INSTALL_LOG="$INSTALL_LOG_DIR/install.log"
    mkdir -p "$INSTALL_LOG_DIR"
    printf '\n\033[1;33m==> This shell is running inside %s\033[0m\n' "$DEST_APP"
    echo "    The install replaces that app, so $DISPLAY_NAME will quit and reopen."
    echo "    Terminal panes do not survive it; the workspace layout is restored on launch."
    echo "    Building first — the replacement runs detached, logging to $INSTALL_LOG"
fi

cd "$REPO_ROOT"

# --- 1. Toolchain preconditions ----------------------------------------------
command -v xcodebuild >/dev/null 2>&1 || {
    echo "error: xcodebuild not found. Install the Xcode command line tools." >&2
    exit 1
}
command -v swift >/dev/null 2>&1 || {
    echo "error: swift not found. Install the Xcode command line tools." >&2
    exit 1
}

# --- 2. Reclaim build junk before adding more of it --------------------------
if [ -n "${CLEAN:-}" ]; then
    DEEP=1 ./scripts/prune-build-cache.sh
else
    ./scripts/prune-build-cache.sh
fi

# --- 3. Ghostty framework + resources (idempotent) ---------------------------
step "Ensuring GhosttyKit.xcframework + resources"
./scripts/setup-ghosttykit.sh

# --- 4. Regenerate the Xcode project from project.yml (source of truth) -------
step "Generating Tenon.xcodeproj from project.yml"
./scripts/setup-xcodegen.sh
.build/tools/xcodegen/bin/xcodegen generate --use-cache

# --- 5. Build the standalone CLI --------------------------------------------
step "Building tenon-cli ($SWIFT_CONFIGURATION, host arch: $(uname -m))"
swift build \
    --configuration "$SWIFT_CONFIGURATION" \
    --product tenon-cli

CLI_BIN_DIR="$(swift build \
    --configuration "$SWIFT_CONFIGURATION" \
    --product tenon-cli \
    --show-bin-path)"
BUILT_CLI="$CLI_BIN_DIR/tenon-cli"
[ -x "$BUILT_CLI" ] || {
    echo "error: SwiftPM did not produce executable $BUILT_CLI" >&2
    exit 1
}

# --- 6. Build the app bundle -------------------------------------------------
step "Building $BUILT_APP_NAME ($CONFIGURATION, archs: $ARCHS)"
xcodebuild \
    -project Tenon.xcodeproj \
    -scheme Tenon \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$REPO_ROOT/.build" \
    -destination "platform=macOS,arch=$ARCHS" \
    ARCHS="$ARCHS" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="" \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$BUILT_APP_NAME"
[ -d "$BUILT_APP" ] || {
    echo "error: build did not produce $BUILT_APP" >&2
    exit 1
}

step "Bundling standalone tenon-cli"
install -m 755 "$BUILT_CLI" "$BUILT_APP/Contents/MacOS/tenon-cli"

# Keep Xcode's object files and build database. Removing Intermediates.noindex
# here forces the next install to compile the app from scratch; CLEAN=1 remains
# the explicit escape hatch when a from-scratch build is actually wanted.
echo "build cache kept for fast incremental installs: $(du -sh "$REPO_ROOT/.build" | cut -f1)"

# --- 7. Replace the installed copy -------------------------------------------
# Everything from here kills the app, so it lives in one script that can run either in
# this shell or detached from it — see scripts/install-replace.sh.
export BUILT_APP DEST_APP APP_DEST APP_NAME BUILT_APP_NAME DISPLAY_NAME BUNDLE_ID LAUNCH
REPLACE="$REPO_ROOT/scripts/install-replace.sh"

if [ "$SELF_INSTALL" -eq 0 ]; then
    exec bash "$REPLACE"
fi

# The caller is inside the app being replaced, and the app's own teardown reaches every
# process on this pane's tty: `TerminalJobTerminator.sweep` lists them with `ps -t <tty>`
# and signals their process groups, escalating to SIGKILL. Backgrounding is not enough —
# a `nohup`-ed child keeps the controlling terminal, is listed, and is killed; SIGKILL
# cannot be ignored. So the installer leaves the terminal session entirely before the app
# is asked to quit. `setsid(2)` is what does that, and macOS ships no setsid(1).
step "Handing off to a detached installer"
# Said before the handoff, not after: once the installer starts, this pane has only as long
# as an osascript quit takes, and a message printed into a dead terminal helps nobody.
echo "    $DISPLAY_NAME will quit and reopen; this pane ends with it."
echo "    Follow the rest from a new pane with:"
echo "        tail -f \"$INSTALL_LOG\""
/usr/bin/python3 -c '
import os, sys

os.setsid()
log = open(sys.argv[1], "wb", 0)
os.dup2(log.fileno(), 1)
os.dup2(log.fileno(), 2)
os.dup2(os.open(os.devnull, os.O_RDONLY), 0)
os.execv("/bin/bash", ["bash", sys.argv[2]])
' "$INSTALL_LOG" "$REPLACE" &

echo "    installer detached (pid $!)"
