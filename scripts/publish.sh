#!/usr/bin/env bash
# tenon: tag, publish to GitHub, update the cask, verify a stranger can install it
# tenon-group: release
#
# This is the only road to a published release, and it runs from a machine that holds the
# Developer ID certificate — deliberately, so the certificate never leaves it.
#
# `./tenon release` produces the artifact. This publishes it and then proves the result the
# way a stranger's Mac would experience it: tag, GitHub release, Homebrew cask, and a final
# check that downloads the published asset with no credentials at all.
#
# That last part is the point. A tag is not a release, and "the upload succeeded" is not
# evidence anyone can install it — a private repository returns 404 to an anonymous fetch,
# and Homebrew is always anonymous. So the run ends by being a stranger rather than by
# reporting success.
#
# Usage:
#   ./tenon publish                  # build, release, cask, verify
#   DRY_RUN=1 ./tenon publish        # do everything except push a tag, release or cask
#   SKIP_BUILD=1 ./tenon publish     # reuse dist/ from an earlier ./tenon release
#
# Overrides (env, or .env at the repository root):
#   VERSION=x.y.z     # default: CFBundleShortVersionString of the built app
#   TAP_REPO=/path    # a checkout of the Homebrew tap; cloned into .build/tap if unset
#   TAP_SLUG=owner/homebrew-tap
#   PRERELEASE=0      # default 1 while the product is pre-alpha
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# The same file release-sign.sh reads, for the same reason: one place to look.
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091  # generated per machine from .env.example
    . "$REPO_ROOT/.env"
    set +a
fi

DIST="$REPO_ROOT/dist"
TAP_SLUG="${TAP_SLUG:-$(git remote get-url origin |
    sed -E 's#^(git@github\.com:|https://github\.com/)##; s#/.*$##')/homebrew-tap}"
PRERELEASE="${PRERELEASE:-1}"
DRY_RUN="${DRY_RUN:-}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
note() { printf '    %s\n' "$1"; }
die() { printf '\033[1merror: %s\033[0m\n' "$1" >&2; exit 1; }

run() {  # run <description> -- everything after is the command
    if [ -n "$DRY_RUN" ]; then
        note "dry run, skipped: $*"
        return 0
    fi
    "$@"
}

# --- 1. Preflight -------------------------------------------------------------
# Everything that would waste a signed build, asked before the build happens.
step "Checking the state this release would be cut from"

command -v gh >/dev/null 2>&1 || die "gh is required to publish a release"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"

GITHUB_REPO="$(git remote get-url origin |
    sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
note "repository: $GITHUB_REPO"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || note "WARNING: on '$BRANCH', not main"

# Several agents share this working tree, so a dirty file may belong to someone else. It
# still means the artifact cannot be rebuilt from its own commit, which is the one thing a
# published release has to promise.
if [ -n "$(git status --porcelain)" ]; then
    note "WARNING: the worktree is dirty; this artifact will not be reproducible from HEAD"
    git status --short | sed 's/^/    /'
fi

COMMIT="$(git rev-parse HEAD)"
if ! git merge-base --is-ancestor "$COMMIT" "origin/$BRANCH" 2>/dev/null; then
    die "HEAD is not on origin/$BRANCH — push first, so the tag names a commit others have"
fi
note "commit: $COMMIT"

VISIBILITY="$(gh repo view "$GITHUB_REPO" --json visibility --jq '.visibility' 2>/dev/null || echo UNKNOWN)"
note "visibility: $VISIBILITY"
if [ "$VISIBILITY" != "PUBLIC" ]; then
    note "WARNING: Homebrew fetches anonymously, so a cask pointing into a $VISIBILITY"
    note "         repository installs for nobody. The release will still be created."
fi

# --- 2. The artifact ----------------------------------------------------------
if [ -n "${SKIP_BUILD:-}" ]; then
    step "Reusing the artifact already in dist/"
    [ -d "$DIST/Tenon.app" ] || die "no $DIST/Tenon.app — run without SKIP_BUILD"
else
    step "Building, signing, notarizing and packaging"
    ./scripts/release.sh
fi

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$DIST/Tenon.app/Contents/Info.plist")}"
TAG="v$VERSION"
ARCHIVE="$DIST/Tenon-$VERSION-macos.zip"
[ -f "$ARCHIVE" ] || die "no $ARCHIVE"
note "version: $VERSION"

if git rev-parse "$TAG" >/dev/null 2>&1; then
    die "tag $TAG already exists — bump MARKETING_VERSION in project.yml, or delete the tag"
fi
if gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    die "release $TAG already exists on $GITHUB_REPO"
fi

# --- 3. The release -----------------------------------------------------------
step "Publishing $TAG on GitHub"

NOTES="$(mktemp "${TMPDIR:-/tmp}/tenon-release-notes.XXXXXX")"
# Expanded now rather than at exit, so the trap keeps working no matter what happens to
# the variable afterwards.
# shellcheck disable=SC2064
trap "rm -f '$NOTES'" EXIT
{
    printf 'Built from `%s`.\n\n' "$COMMIT"
    printf '## Install\n\n'
    printf '```sh\nbrew tap %s\nbrew install --cask tenon\n```\n\n' "$TAP_SLUG"
    printf 'Or download the archive below and open it in Finder.\n\n'
    # unzip cannot restore the extended attributes the signature seals; it writes them out
    # as ._* files inside the bundle and macOS then refuses the app. Measured, not guessed.
    printf '**Extract in Finder or with `ditto`, not with `unzip`.** '
    printf 'Info-ZIP writes the archived extended attributes back as stray `._*` files '
    printf 'inside the bundle, and macOS then rejects the app with "a sealed resource is '
    printf 'missing or invalid" — which looks like a corrupt download and is a corrupt '
    printf 'extraction.\n\n'
    printf '## Verify\n\n```sh\nshasum -a 256 Tenon-%s-macos.zip\n' "$VERSION"
    printf 'spctl --assess -vv /Applications/Tenon.app\n```\n\n'
    printf 'Expected: `%s`, and `accepted / source=Notarized Developer ID`.\n' \
        "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
} >"$NOTES"

run git tag -a "$TAG" -m "Tenon $VERSION"
run git push origin "$TAG"

RELEASE_ARGS=(--repo "$GITHUB_REPO" --title "Tenon $VERSION" --notes-file "$NOTES")
[ "$PRERELEASE" = "1" ] && RELEASE_ARGS+=(--prerelease)
run gh release create "$TAG" "$ARCHIVE" "$DIST/SHA256SUMS" "${RELEASE_ARGS[@]}"

# --- 4. The cask --------------------------------------------------------------
step "Updating the Homebrew cask in $TAP_SLUG"

if [ -z "${TAP_REPO:-}" ]; then
    TAP_REPO="$REPO_ROOT/.build/tap"
    if [ -d "$TAP_REPO/.git" ]; then
        git -C "$TAP_REPO" fetch --quiet origin
        git -C "$TAP_REPO" reset --hard --quiet origin/HEAD
    else
        mkdir -p "$(dirname "$TAP_REPO")"
        gh repo clone "$TAP_SLUG" "$TAP_REPO" -- --quiet
    fi
fi
note "tap checkout: $TAP_REPO"

TAP_REPO="$TAP_REPO" ./scripts/internal/make-cask.sh

if [ -n "$(git -C "$TAP_REPO" status --porcelain)" ]; then
    run git -C "$TAP_REPO" add Casks/tenon.rb
    run git -C "$TAP_REPO" commit -q -m "tenon $VERSION"
    run git -C "$TAP_REPO" push --quiet
    note "cask published"
else
    note "cask already current"
fi

# --- 5. Be a stranger ---------------------------------------------------------
# The only check that distinguishes "uploaded" from "installable". Everything above ran
# with this machine's credentials; this part deliberately has none.
step "Verifying the published release the way someone else receives it"

if [ -n "$DRY_RUN" ]; then
    note "dry run: nothing was published, so there is nothing to fetch back"
    exit 0
fi

PROBE="$(mktemp -d "${TMPDIR:-/tmp}/tenon-publish-probe.XXXXXX")"
# shellcheck disable=SC2064  # expanded now, for the reason above
trap "rm -f '$NOTES'; rm -rf '$PROBE'" EXIT
ASSET_URL="https://github.com/$GITHUB_REPO/releases/download/$TAG/Tenon-$VERSION-macos.zip"

# --header with no token, and a clean cookie jar: an authenticated shell must not make an
# unreachable asset look reachable.
STATUS="$(curl -sS -o "$PROBE/Tenon.zip" -w '%{http_code}' -L \
    --retry 3 --retry-all-errors "$ASSET_URL" || echo 000)"
if [ "$STATUS" != "200" ]; then
    die "the published asset answers HTTP $STATUS to an anonymous download.
       Homebrew fetches exactly this way, so 'brew install --cask tenon' cannot work.
       The release exists; nobody outside can install it while $GITHUB_REPO is $VISIBILITY."
fi
note "anonymous download: HTTP 200"

EXPECTED="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
ACTUAL="$(shasum -a 256 "$PROBE/Tenon.zip" | cut -d' ' -f1)"
[ "$EXPECTED" = "$ACTUAL" ] || die "downloaded checksum $ACTUAL does not match published $EXPECTED"
note "checksum matches: $ACTUAL"

ditto -x -k "$PROBE/Tenon.zip" "$PROBE/extracted"
ASSESS="$(spctl --assess -vv "$PROBE/extracted/Tenon.app" 2>&1 || true)"
grep -q "accepted" <<<"$ASSESS" || die "Gatekeeper refused the published artifact:
$ASSESS"
grep -q "source=Notarized Developer ID" <<<"$ASSESS" ||
    die "the published artifact is not notarized:
$ASSESS"
note "Gatekeeper: accepted, Notarized Developer ID"

step "Published"
note "release: https://github.com/$GITHUB_REPO/releases/tag/$TAG"
note "install: brew tap $TAP_SLUG && brew install --cask tenon"
