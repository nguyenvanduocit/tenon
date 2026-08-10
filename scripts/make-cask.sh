#!/usr/bin/env bash
# make-cask.sh — write the Homebrew cask for the artifacts in dist/.
#
# Everything in a cask that can drift — version, checksum, bundle identifier, minimum
# macOS — is read from the built artifact rather than typed. A cask whose sha256 was
# copied by hand is a cask that installs the wrong build exactly once.
#
# Usage:
#   ./scripts/make-cask.sh                     # writes dist/tenon.rb
#   TAP_REPO=~/projects/homebrew-tap ./scripts/make-cask.sh   # ...and copies it into the tap
#
# Overrides (env):
#   GITHUB_REPO=owner/name   # default: parsed from the `origin` remote
#   TAP_REPO=/path           # a checkout of the tap; the cask is copied to Casks/tenon.rb
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DIST="$REPO_ROOT/dist"
APP="$DIST/Tenon.app"
[ -d "$APP" ] || {
    echo "error: no $APP — run ./scripts/release.sh first" >&2
    exit 1
}

ARCHIVE="$(find "$DIST" -maxdepth 1 -name 'Tenon-*-macos.zip' | head -1)"
[ -n "$ARCHIVE" ] || { echo "error: no release archive in $DIST" >&2; exit 1; }

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }

VERSION="$(plist CFBundleShortVersionString)"
BUNDLE_ID="$(plist CFBundleIdentifier)"
MIN_MACOS="$(plist LSMinimumSystemVersion)"
SHA256="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"

GITHUB_REPO="${GITHUB_REPO:-$(git remote get-url origin |
    sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')}"

# Homebrew names macOS releases, not version numbers. Deployment target 14.0 is Sonoma;
# mapping the major version keeps the cask honest if the target moves.
case "${MIN_MACOS%%.*}" in
    14) MACOS_SYMBOL="sonoma" ;;
    15) MACOS_SYMBOL="sequoia" ;;
    16) MACOS_SYMBOL="tahoe" ;;
    *)
        echo "error: no Homebrew symbol known for macOS $MIN_MACOS; add it here." >&2
        exit 1
        ;;
esac

CASK="$DIST/tenon.rb"
cat > "$CASK" <<CASK_BODY
cask "tenon" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$GITHUB_REPO/releases/download/v#{version}/Tenon-#{version}-macos.zip"
  name "Tenon"
  desc "Terminal-first macOS workspace for supervising parallel CLI agents"
  homepage "https://github.com/$GITHUB_REPO"

  depends_on macos: ">= :$MACOS_SYMBOL"

  app "Tenon.app"

  # The CLI is deliberately not symlinked here. Tenon installs it itself from
  # Settings ▸ CLI ▸ Install, which is the surface that owns the CLI's location and
  # keeps it matched to the running app. A second path to the same file would let a
  # stale symlink outlive the bundle it points into.

  zap trash: [
    "~/Library/Application Support/Tenon",
    "~/Library/Caches/$BUNDLE_ID",
    "~/Library/Preferences/$BUNDLE_ID.plist",
    "~/Library/Saved Application State/$BUNDLE_ID.savedState",
  ]
end
CASK_BODY

echo "wrote $CASK"
echo "  version:   $VERSION"
echo "  sha256:    $SHA256"
echo "  bundle id: $BUNDLE_ID"
echo "  url:       https://github.com/$GITHUB_REPO/releases/download/v$VERSION/"

if [ -n "${TAP_REPO:-}" ]; then
    [ -d "$TAP_REPO/Casks" ] || mkdir -p "$TAP_REPO/Casks"
    cp "$CASK" "$TAP_REPO/Casks/tenon.rb"
    echo "copied to $TAP_REPO/Casks/tenon.rb"
    echo "commit and push the tap, then: brew install --cask $GITHUB_REPO%%/*/tenon"
fi

# A cask pointing at a private repository installs for nobody: Homebrew fetches the URL
# with no credentials. Say so here rather than letting the first `brew install` say it.
if command -v gh >/dev/null 2>&1; then
    VISIBILITY="$(gh repo view "$GITHUB_REPO" --json visibility -q .visibility 2>/dev/null || echo UNKNOWN)"
    if [ "$VISIBILITY" = "PRIVATE" ]; then
        echo
        echo "NOTE: $GITHUB_REPO is private, so this cask cannot install yet."
        echo "      Homebrew downloads the release asset anonymously. Make the repository"
        echo "      public — or host the archive somewhere public — before publishing the tap."
    fi
fi
