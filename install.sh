#!/usr/bin/env bash
# install.sh — build a release Tenon.app and install it onto this machine,
# replacing any previously installed copy.
#
# The dev loop (dev.sh / `swift run`) launches a bare SwiftPM executable, which
# has no bundle resources. The real app resolves plugins/, ghostty/ and terminfo/
# through `Bundle.main.resourceURL`, so a genuine install must produce a proper
# .app bundle — that is what project.yml + xcodegen + xcodebuild give us.
#
# Usage:
#   ./install.sh            # build Release, install to /Applications, replace old
#   ./install.sh --launch   # ...and open Tenon after installing
#
# Overrides (env):
#   APP_DEST=/some/dir      # install destination (default /Applications)
#   CONFIGURATION=Debug     # xcodebuild configuration (default Release)
#   ARCHS="arm64 x86_64"    # override arch (default: this machine's arch only)
#   CLEAN=1                 # wipe derived data for a from-scratch build
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
POC="$REPO_ROOT/poc"

APP_DEST="${APP_DEST:-/Applications}"
CONFIGURATION="${CONFIGURATION:-Release}"
# Build only for this machine's architecture — a local install has no reason to
# carry the other slice (x86_64 is dead weight on Apple Silicon, and vice versa).
ARCHS="${ARCHS:-$(uname -m)}"
DERIVED_DATA="$POC/.build/xcode-install"   # inside the gitignored .build/
APP_NAME="Tenon.app"
BUNDLE_ID="com.firegroup.tenon"

LAUNCH=0
[ "${1:-}" = "--launch" ] && LAUNCH=1

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }

cd "$POC"

# --- 1. Toolchain preconditions ----------------------------------------------
command -v xcodegen >/dev/null 2>&1 || {
    echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
    exit 1
}
command -v xcodebuild >/dev/null 2>&1 || {
    echo "error: xcodebuild not found. Install the Xcode command line tools." >&2
    exit 1
}

# --- 2. Ghostty framework + resources (idempotent) ---------------------------
step "Ensuring GhosttyKit.xcframework + resources"
./scripts/setup-ghosttykit.sh

# --- 3. Regenerate the Xcode project from project.yml (source of truth) -------
step "Generating Tenon.xcodeproj from project.yml"
xcodegen generate

# --- 4. Build the release .app -----------------------------------------------
step "Building $APP_NAME ($CONFIGURATION, archs: $ARCHS)"
[ -n "${CLEAN:-}" ] && rm -rf "$DERIVED_DATA"   # otherwise reuse for a fast incremental build
xcodebuild \
    -project Tenon.xcodeproj \
    -scheme Tenon \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
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

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
[ -d "$BUILT_APP" ] || {
    echo "error: build did not produce $BUILT_APP" >&2
    exit 1
}

# --- 5. Replace the installed copy -------------------------------------------
DEST_APP="$APP_DEST/$APP_NAME"

step "Quitting any running Tenon"
osascript -e "quit app \"Tenon\"" >/dev/null 2>&1 || true
# Give it a beat to release the bundle, then hard-kill leftovers.
pkill -f "$APP_DEST/$APP_NAME/Contents/MacOS/Tenon" >/dev/null 2>&1 || true

step "Installing to $DEST_APP (replacing old)"
mkdir -p "$APP_DEST"
rm -rf "$DEST_APP"
# ditto preserves bundle metadata/symlinks more faithfully than cp -R.
ditto "$BUILT_APP" "$DEST_APP"

# --- 6. Make it launchable (ad-hoc sign + clear quarantine) ------------------
step "Signing (ad-hoc) and clearing quarantine"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
codesign --force --deep --sign - "$DEST_APP"

# --- 7. Verify ----------------------------------------------------------------
step "Verifying install"
codesign --verify --deep --strict "$DEST_APP" && echo "signature: valid (ad-hoc)"
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$DEST_APP/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "installed: $DEST_APP (version $INSTALLED_VERSION, id $BUNDLE_ID)"

if [ "$LAUNCH" -eq 1 ]; then
    step "Launching Tenon"
    open "$DEST_APP"
else
    echo
    echo "Done. Launch it with:  open \"$DEST_APP\""
fi
