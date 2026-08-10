#!/usr/bin/env bash
# release.sh — produce the artifacts a Tenon release consists of.
#
# Output lands in dist/:
#   Tenon-<version>-macos.zip     universal app, signed, notarized, stapled
#   Tenon-<version>-macos.zip.sha256
#   SHA256SUMS
#
# The zip is what Homebrew installs and what a person downloads. It is stapled, so a
# first launch on a machine that has never seen Tenon verifies without network.
#
# Usage:
#   ./scripts/release.sh                 # full: verify, build, sign, notarize, package
#   SKIP_TESTS=1 ./scripts/release.sh    # skip the suite (for iterating on packaging)
#   SKIP_NOTARIZE=1 ./scripts/release.sh # sign but do not submit (no credentials needed)
#
# Overrides (env):
#   VERSION=x.y.z          # default: MARKETING_VERSION from the built Info.plist
#   SIGN_IDENTITY=...      # passed through to release-sign.sh
#   NOTARY_PROFILE=name    # passed through to release-sign.sh
#
# Why this is separate from install.sh: install.sh puts a build on the machine that made
# it, where an ad-hoc signature is enough and no certificate should be required. This
# produces something for a machine that has never seen the app, which is a different job
# with a different failure mode — see docs/releasing.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DERIVED_DATA="$REPO_ROOT/.build/xcode"
DIST="$REPO_ROOT/dist"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/Tenon.app"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# --- 1. State the release is cut from ----------------------------------------
step "Recording the source revision"
COMMIT="$(git rev-parse HEAD)"
echo "commit: $COMMIT"
if [ -n "$(git status --porcelain)" ]; then
    # Not fatal — several agents share this tree and a dirty file may not be ours. But a
    # release built from uncommitted work cannot be reproduced from its own commit, and
    # the person cutting it should know that before it ships rather than after.
    echo "WARNING: the worktree is dirty; this artifact is not reproducible from $COMMIT" >&2
    git status --short >&2
fi

# --- 2. Dependencies and generated project -----------------------------------
step "Fetching the pinned Ghostty artifact"
./scripts/setup-ghosttykit.sh

step "Regenerating the Xcode project"
xcodegen generate
if ! git diff --quiet -- Tenon.xcodeproj/project.pbxproj; then
    echo "error: the generated project differs from the committed one." >&2
    echo "       Commit the regenerated project.pbxproj before cutting a release." >&2
    exit 1
fi

# --- 3. Evidence -------------------------------------------------------------
if [ -z "${SKIP_TESTS:-}" ]; then
    step "Running the test suite"
    swift test
else
    step "Skipping tests (SKIP_TESTS set)"
fi

# --- 4. Build universal ------------------------------------------------------
# A release runs on machines this one is not. install.sh builds a single arch on
# purpose; here both slices are the point.
step "Building tenon-cli (universal)"
swift build --configuration release --arch arm64 --arch x86_64 --product tenon-cli
CLI_BIN="$(swift build --configuration release --arch arm64 --arch x86_64 \
    --product tenon-cli --show-bin-path)/tenon-cli"
[ -x "$CLI_BIN" ] || { echo "error: SwiftPM produced no $CLI_BIN" >&2; exit 1; }

step "Building Tenon.app (universal)"
xcodebuild \
    -project Tenon.xcodeproj \
    -scheme Tenon \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$REPO_ROOT/.build" \
    -destination 'generic/platform=macOS' \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM="" \
    build
[ -d "$BUILT_APP" ] || { echo "error: build produced no $BUILT_APP" >&2; exit 1; }

# --- 5. Stage a clean copy ---------------------------------------------------
# Signing happens on a copy so a re-run always starts from the build output rather than
# from a bundle a previous run already sealed.
step "Staging the bundle"
rm -rf "$DIST"
mkdir -p "$DIST"
STAGED="$DIST/Tenon.app"
ditto "$BUILT_APP" "$STAGED"

# The CLI is copied in before signing: Settings ▸ CLI ▸ Install hands this exact file to
# ~/.local/bin, so it must be inside the seal and signed as its own program.
install -m 755 "$CLI_BIN" "$STAGED/Contents/MacOS/tenon-cli"

# It has to keep working once it leaves the bundle, which means linking nothing but the
# OS. The app binary beside it genuinely links @rpath/TenonCore.framework, so this is a
# real difference and not a hypothetical one.
#
# Selected by shape rather than by position: a universal binary makes `otool -L` print one
# "… (architecture x86_64):" header per slice, so dropping the first line — which is what
# the single-arch install path does — leaves the second header behind and reports it as a
# foreign link. Dependency lines are the indented ones; every header starts at column zero.
FOREIGN_LINKS="$(otool -L "$STAGED/Contents/MacOS/tenon-cli" |
    grep -E '^[[:space:]]' |
    grep -vE '^[[:space:]]+(/usr/lib/|/System/Library/Frameworks/)' || true)"
if [ -n "$FOREIGN_LINKS" ]; then
    echo "error: bundled tenon-cli links outside the OS and would break in ~/.local/bin:" >&2
    echo "$FOREIGN_LINKS" >&2
    exit 1
fi

for slice in arm64 x86_64; do
    lipo -archs "$STAGED/Contents/MacOS/Tenon" | grep -q "$slice" || {
        echo "error: Tenon.app is missing the $slice slice" >&2
        exit 1
    }
done
echo "architectures: $(lipo -archs "$STAGED/Contents/MacOS/Tenon")"

# --- 6. Sign, notarize, staple ----------------------------------------------
step "Signing and notarizing"
./scripts/release-sign.sh "$STAGED"

# --- 7. Package --------------------------------------------------------------
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$STAGED/Contents/Info.plist")}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$STAGED/Contents/Info.plist")"
ARCHIVE="$DIST/Tenon-$VERSION-macos.zip"

step "Packaging $ARCHIVE"
# ditto -c -k --keepParent is the archiver Apple's tooling round-trips: it preserves the
# bundle's symlinks and extended attributes, including the stapled ticket.
ditto -c -k --keepParent "$STAGED" "$ARCHIVE"

(cd "$DIST" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
(cd "$DIST" && shasum -a 256 ./*.zip > SHA256SUMS)

# --- 8. Verify what will actually be downloaded ------------------------------
# The zip is the artifact, so the check runs on a bundle extracted back out of it — the
# staple has to survive the round trip, and a bundle verified in place proves nothing
# about the file people receive.
step "Verifying the extracted artifact"
VERIFY_DIR="$(mktemp -d)"
ditto -x -k "$ARCHIVE" "$VERIFY_DIR"
codesign --verify --deep --strict "$VERIFY_DIR/Tenon.app"
if [ -z "${SKIP_NOTARIZE:-}" ]; then
    xcrun stapler validate "$VERIFY_DIR/Tenon.app"
    spctl --assess --type exec --verbose=4 "$VERIFY_DIR/Tenon.app"
fi
rm -rf "$VERIFY_DIR"

cat <<SUMMARY

$(printf '\033[1mRelease artifacts\033[0m')
  version:   $VERSION
  bundle id: $BUNDLE_ID
  commit:    $COMMIT
  archive:   $ARCHIVE
  sha256:    $(cut -d' ' -f1 < "$ARCHIVE.sha256")

Next: docs/releasing.md — publish the GitHub release, then update the Homebrew cask.
SUMMARY
