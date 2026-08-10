#!/usr/bin/env bash
# release-sign.sh — turn a built Tenon.app into an artifact another machine will run.
#
# This is the distribution path. `install.sh` is the local path and stays ad-hoc: a
# machine that built the app already trusts it, and ad-hoc keeps every concurrent agent
# free of certificates. The two differ in exactly one thing — whether the signature
# names an identity macOS can remember across builds.
#
# Why that matters beyond Gatekeeper: an ad-hoc signature is a content hash, so it
# changes on every build, and macOS keys TCC consent and Keychain ACLs to the code
# identity. Ad-hoc means a fresh install is a different app, which is why permission
# prompts and `SecretStore` items do not survive one.
#
# Usage:
#   ./scripts/release-sign.sh path/to/Tenon.app
#
# Configuration comes from `.env` at the repository root, which is gitignored; copy
# `.env.example` to start one. Anything already exported wins over the file, so a one-off
# override on the command line still works.
#
# Overrides (env or .env):
#   SIGN_IDENTITY="Developer ID Application: ... (TEAMID)"
#                          # default: the only Developer ID Application identity in the
#                          # keychain; ambiguity is an error rather than a guess
#   NOTARY_PROFILE=name    # notarytool keychain profile (default: tenon-notary)
#   SKIP_NOTARIZE=1        # sign and verify only; produces a signed app that Gatekeeper
#                          # still blocks on a machine that did not build it
#
# The notarization password is in none of those places. It lives in the keychain profile,
# encrypted by macOS; `.env` only names the profile. Store it once:
#   xcrun notarytool store-credentials tenon-notary \
#     --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Read before the arguments are checked, so a misconfigured file is reported by the same
# run that would have used it. `set -a` exports what the file defines, which is how
# release.sh's child processes inherit it; the pre-existing values are restored afterwards
# so an explicit override on the command line is never overwritten by the file.
if [ -f "$REPO_ROOT/.env" ]; then
    ENV_FILE_SIGN_IDENTITY="${SIGN_IDENTITY:-}"
    ENV_FILE_NOTARY_PROFILE="${NOTARY_PROFILE:-}"
    set -a
    # shellcheck disable=SC1091  # generated per machine from .env.example
    . "$REPO_ROOT/.env"
    set +a
    [ -z "$ENV_FILE_SIGN_IDENTITY" ] || SIGN_IDENTITY="$ENV_FILE_SIGN_IDENTITY"
    [ -z "$ENV_FILE_NOTARY_PROFILE" ] || NOTARY_PROFILE="$ENV_FILE_NOTARY_PROFILE"
fi

APP="${1:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "usage: $0 path/to/Tenon.app" >&2
    exit 2
fi
APP="$(cd "$APP" && pwd)"

NOTARY_PROFILE="${NOTARY_PROFILE:-tenon-notary}"
ENTITLEMENTS="$REPO_ROOT/Tenon.entitlements"
[ -f "$ENTITLEMENTS" ] || {
    echo "error: $ENTITLEMENTS is missing; the app would harden without a JIT exception" >&2
    exit 1
}

step() { printf '\n==> %s\n' "$1"; }

# --- 1. Resolve the identity -------------------------------------------------
# Named explicitly, or discovered — but never guessed. Two Developer ID identities in
# one keychain is the case where picking either silently ships under the wrong team.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    FOUND=()
    while IFS= read -r line; do
        [ -n "$line" ] && FOUND+=("$line")
    done < <(security find-identity -v -p codesigning |
        sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p')
    case "${#FOUND[@]}" in
        1) SIGN_IDENTITY="${FOUND[0]}" ;;
        0)
            echo "error: no Developer ID Application identity in the keychain." >&2
            echo "       An Apple Development certificate cannot sign for distribution." >&2
            exit 1
            ;;
        *)
            echo "error: ${#FOUND[@]} Developer ID identities found; name one via SIGN_IDENTITY:" >&2
            printf '       %s\n' "${FOUND[@]}" >&2
            exit 1
            ;;
    esac
fi
echo "identity: $SIGN_IDENTITY"

# --- 2. Sign inside-out ------------------------------------------------------
# `--deep` is not accepted for distribution: it re-signs nested code with the outer
# entitlements and skips anything it does not recognise as code. Each nested Mach-O is
# signed on its own, innermost first, because sealing the app is what records the
# hashes of everything already inside it.
#
# `--timestamp` contacts Apple's timestamp server; without it the signature expires
# with the certificate instead of outliving it.
sign() {
    local target="$1"
    shift
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$@" "$target"
}

step "Signing embedded frameworks"
if [ -d "$APP/Contents/Frameworks" ]; then
    # Frameworks carry no entitlements of their own — entitlements belong to the
    # executable that hosts the process, and the app is the only one here.
    #
    # Collected before signing rather than piped into the loop: a `while` on the far
    # side of a pipe runs in a subshell, where `set -e` does not propagate, so a failed
    # signature would be swallowed and the app would seal over unsigned nested code.
    FRAMEWORKS=()
    while IFS= read -r -d '' framework; do
        FRAMEWORKS+=("$framework")
    done < <(find "$APP/Contents/Frameworks" -maxdepth 1 -type d -name '*.framework' -print0)
    for framework in ${FRAMEWORKS+"${FRAMEWORKS[@]}"}; do
        echo "  $(basename "$framework")"
        sign "$framework"
    done
fi

step "Signing bundled tenon-cli"
# Settings ▸ CLI ▸ Install copies this exact file to ~/.local/bin, so it is signed as
# its own program rather than inheriting the app's seal.
if [ -f "$APP/Contents/MacOS/tenon-cli" ]; then
    sign "$APP/Contents/MacOS/tenon-cli"
else
    echo "  absent — nothing to sign" >&2
fi

step "Signing the app bundle"
sign "$APP" --entitlements "$ENTITLEMENTS"

# --- 3. Verify the signature ------------------------------------------------
# `--deep` IS correct here: as a verification flag it means "check nested code too",
# which is the opposite of what it means while signing.
step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

# The flags word is the actual evidence that the runtime hardened; a build setting is
# an intention, and this is the artifact.
SIGNATURE_FLAGS="$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p')"
echo "flags: $SIGNATURE_FLAGS"
case "$SIGNATURE_FLAGS" in
    *runtime*) ;;
    *)
        echo "error: the signature does not carry the runtime flag, so the Hardened" >&2
        echo "       Runtime is not in effect and notarization would reject it." >&2
        exit 1
        ;;
esac

# An entitlement that failed to attach fails silently at runtime: JavaScriptCore simply
# stops compiling and interprets instead, which no test would notice.
step "Verifying entitlements"
codesign -d --entitlements - --xml "$APP" 2>/dev/null |
    plutil -convert xml1 -o - - |
    grep -q 'com.apple.security.cs.allow-jit' || {
    echo "error: allow-jit did not attach; plugin JavaScript would lose JIT silently." >&2
    exit 1
}
echo "entitlements: allow-jit present"

if [ -n "${SKIP_NOTARIZE:-}" ]; then
    step "Skipping notarization (SKIP_NOTARIZE set)"
    echo "signed: $APP"
    echo "note: Gatekeeper still blocks this on a machine that did not build it."
    exit 0
fi

# --- 4. Notarize and staple --------------------------------------------------
# Apple's service reads a zip, but the ticket is stapled to the app: a stapled bundle
# verifies with no network, which is what a first launch on a fresh machine needs.
step "Submitting for notarization (profile: $NOTARY_PROFILE)"
ZIP="$(mktemp -d)/Tenon.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -rf "$(dirname "$ZIP")"

step "Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "Verifying as Gatekeeper will"
# `-t exec` asks the question a first launch asks. `--verbose` prints the source, which
# should read "Notarized Developer ID".
spctl --assess --type exec --verbose=4 "$APP"

echo
echo "distributable: $APP"
