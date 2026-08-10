#!/usr/bin/env bash
# install-replace.sh — stop the installed app, replace its bundle, sign it, prove the
# result, and optionally launch it.
#
# This is the second half of ./install.sh, and it lives in its own file for one reason:
# when the person running the installer is sitting in a Tenon pane, these steps kill the
# process their shell descends from. Everything here therefore has to be able to run
# detached from that shell — same file, same order, called either in the foreground or
# from a session the pane's teardown cannot reach. Splitting it is what keeps those two
# situations from drifting into two different installers.
#
# It is not called directly; ./install.sh builds the bundle and passes everything through
# the environment:
#
#   BUILT_APP        the freshly built .app to install
#   DEST_APP         where it is going, replacing whatever is there
#   APP_DEST         the directory holding DEST_APP
#   APP_NAME         installed bundle name
#   BUILT_APP_NAME   the name the build produced
#   DISPLAY_NAME     installed app name
#   BUNDLE_ID        installed bundle identifier
#   LAUNCH           1 to open the app afterwards
set -euo pipefail

for required in BUILT_APP DEST_APP APP_DEST APP_NAME BUILT_APP_NAME DISPLAY_NAME BUNDLE_ID; do
    if [ -z "${!required:-}" ]; then
        echo "error: $required must be set by install.sh" >&2
        exit 1
    fi
done
LAUNCH="${LAUNCH:-0}"

[ -d "$BUILT_APP" ] || {
    echo "error: $BUILT_APP is not a built app bundle" >&2
    exit 1
}

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }

# --- Stop the installed copy -------------------------------------------------
step "Quitting any running $DISPLAY_NAME"
osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true

# Prints one pid per line, or nothing. The explicit `return 0` matters under `set -e`:
# with `[ … ] && echo`, a run that matches nothing leaves the function's status at 1, and
# the app not being open is the ordinary case, not a failure.
running_pids() {
    ps -axo pid=,comm= | while read -r pid executable_path; do
        if [ "$executable_path" = "$DEST_APP/Contents/MacOS/Tenon" ]; then
            echo "$pid"
        fi
    done
    return 0
}

for pid in $(running_pids); do
    kill "$pid" >/dev/null 2>&1 || true
done

# Deleting a bundle out from under a process that is still running it leaves that process
# alive with half its resources unreachable — it keeps drawing until the first lazy load
# fails. Waiting is cheap; the wreckage is not. A quit that never lands escalates, because
# an app refusing to exit must not be able to block its own replacement forever.
step "Waiting for $DISPLAY_NAME to exit"
for _ in $(seq 1 50); do
    [ -z "$(running_pids)" ] && break
    sleep 0.1
done
if [ -n "$(running_pids)" ]; then
    for pid in $(running_pids); do
        kill -9 "$pid" >/dev/null 2>&1 || true
    done
    sleep 0.3
fi
if [ -n "$(running_pids)" ]; then
    echo "error: $DISPLAY_NAME is still running; refusing to replace a live bundle" >&2
    exit 1
fi

# --- Replace -----------------------------------------------------------------
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
   [ "$BUNDLE_ID" != "dev.tenon.app" ]; then
    INFO_PLIST="$DEST_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$INFO_PLIST"
    if ! /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" \
        "$INFO_PLIST" 2>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $DISPLAY_NAME" \
            "$INFO_PLIST"
    fi
fi

# --- Make it launchable (ad-hoc sign + clear quarantine) ---------------------
# Ad-hoc and unhardened, deliberately. This machine built the bytes it is installing, so
# it needs no certificate — which is what keeps several concurrent agents able to install
# without one. `scripts/release-sign.sh` is the other path, for machines that did not.
#
# Do not add `--options runtime` here. Measured (T-114): the Hardened Runtime turns on
# Library Validation, which requires every loaded dylib to share the process's Team ID.
# An ad-hoc signature has no Team ID, so the app dies in dyld before `main` — it embeds
# three frameworks. Hardening belongs only to a build signed by one real identity.
step "Signing (ad-hoc) and clearing quarantine"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
# Signed innermost-first rather than with `--deep`, which re-signs nested code with the
# outer entitlements and silently skips whatever it does not recognise as code. The same
# order the release path uses, so one habit covers both.
for framework in "$DEST_APP"/Contents/Frameworks/*.framework; do
    [ -d "$framework" ] || continue
    codesign --force --sign - "$framework"
done
[ -f "$DEST_APP/Contents/MacOS/tenon-cli" ] &&
    codesign --force --sign - "$DEST_APP/Contents/MacOS/tenon-cli"
codesign --force --sign - "$DEST_APP"

# --- Verify ------------------------------------------------------------------
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

if [ "$LAUNCH" -eq 1 ]; then
    step "Launching $DISPLAY_NAME"
    open "$DEST_APP"
else
    echo
    echo "Done. Launch it with:  open \"$DEST_APP\""
fi
