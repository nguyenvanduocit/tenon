#!/usr/bin/env bash
# install.sh — build a release Tenon.app and install it onto this machine,
# replacing any previously installed copy.
#
# The app resolves plugins/, ghostty/ and terminfo/ through
# `Bundle.main.resourceURL`. Xcode builds that resource-bearing app bundle;
# SwiftPM builds the standalone CLI that the installer embeds into it.
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
#   INSTALL_BUNDLE_ID=...   # installed bundle identifier (default com.firegroup.tenon)
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
BUNDLE_ID="${INSTALL_BUNDLE_ID:-com.firegroup.tenon}"

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
    com.firegroup.tenon|com.firegroup.tenon.staging) ;;
    *)
        echo "error: INSTALL_BUNDLE_ID must be com.firegroup.tenon or com.firegroup.tenon.staging" >&2
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

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }

cd "$REPO_ROOT"

# --- 1. Toolchain preconditions ----------------------------------------------
command -v xcodegen >/dev/null 2>&1 || {
    echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
    exit 1
}
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
xcodegen generate

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

# --- 7. Replace the installed copy -------------------------------------------
DEST_APP="$APP_DEST/$APP_NAME"

step "Quitting any running $DISPLAY_NAME"
osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
# Give it a beat to release the bundle, then hard-kill leftovers.
ps -axo pid=,comm= | while read -r pid executable_path; do
    if [ "$executable_path" = "$DEST_APP/Contents/MacOS/Tenon" ]; then
        kill "$pid" >/dev/null 2>&1 || true
    fi
done

step "Installing to $DEST_APP (replacing old)"
mkdir -p "$APP_DEST"
rm -rf "$DEST_APP"
# ditto preserves bundle metadata/symlinks more faithfully than cp -R.
ditto "$BUILT_APP" "$DEST_APP"

# A named install variant uses the exact same compiled artifact, but owns a distinct
# LaunchServices identity. This is deliberately done on the installed copy: changing
# the shared build product would poison a later normal install from the same cache.
if [ "$APP_NAME" != "$BUILT_APP_NAME" ] || \
   [ "$DISPLAY_NAME" != "Tenon" ] || \
   [ "$BUNDLE_ID" != "com.firegroup.tenon" ]; then
    INFO_PLIST="$DEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$INFO_PLIST"
    if ! /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" \
        "$INFO_PLIST" 2>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $DISPLAY_NAME" \
            "$INFO_PLIST"
    fi
fi

# --- 8. Make it launchable (ad-hoc sign + clear quarantine) ------------------
step "Signing (ad-hoc) and clearing quarantine"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
codesign --force --deep --sign - "$DEST_APP"

# --- 9. Verify ---------------------------------------------------------------
step "Verifying install"
codesign --verify --deep --strict "$DEST_APP" && echo "signature: valid (ad-hoc)"

# The CLI is the one payload the app cannot rebuild for itself: Settings ▸ CLI ▸ Install
# copies this exact file into ~/.local/bin, so it has to survive leaving the bundle. Check
# the artifact that ships rather than the one that was built — this runs after ditto and
# after codesign, so it also catches a copy that arrived but did not survive them.
INSTALLED_CLI="$DEST_APP/Contents/MacOS/tenon-cli"
[ -x "$INSTALLED_CLI" ] || {
    echo "error: $INSTALLED_CLI is missing or not executable — Settings ▸ CLI ▸ Install would have nothing to copy" >&2
    exit 1
}
# Relocatable means: nothing outside the OS. A link into /Users, the checkout, the build
# tree, or the bundle's own Frameworks would work here and break in ~/.local/bin — the app
# binary beside it genuinely links @rpath/TenonCore.framework, so this is the difference
# that matters, not a hypothetical.
#
# Tested on content rather than on grep's exit status: BSD `grep -qv` reports no match here
# where `grep -v` prints three lines, so the -q form would have waved a broken binary
# through — the exact failure this check exists to catch.
FOREIGN_LINKS="$(otool -L "$INSTALLED_CLI" | tail -n +2 |
    grep -vE '^[[:space:]]+(/usr/lib/|/System/Library/Frameworks/)' || true)"
if [ -n "$FOREIGN_LINKS" ]; then
    echo "error: bundled tenon-cli links something outside the OS, so it will not run once copied out of the bundle:" >&2
    echo "$FOREIGN_LINKS" >&2
    exit 1
fi
echo "tenon-cli: bundled, signed, and self-contained"
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$DEST_APP/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "installed: $DEST_APP (version $INSTALLED_VERSION, id $BUNDLE_ID)"

# --- 10. Drop what the finished install no longer needs -----------------------
# The app now lives at its destination, so the object files and headers that
# assembled it are dead weight — hundreds of megabytes of it. Products stay, so a
# later install still skips the work that did not change.
step "Reclaiming build intermediates"
INTERMEDIATES="$DERIVED_DATA/Build/Intermediates.noindex"
if [ -d "$INTERMEDIATES" ]; then
    echo "freed $(du -sh "$INTERMEDIATES" | cut -f1) of intermediates"
    rm -rf "$INTERMEDIATES"
fi
echo "build cache now $(du -sh "$REPO_ROOT/.build" | cut -f1)"

if [ "$LAUNCH" -eq 1 ]; then
    step "Launching Tenon"
    open "$DEST_APP"
else
    echo
    echo "Done. Launch it with:  open \"$DEST_APP\""
fi
