#!/usr/bin/env bash
# Install the pinned project generator into .build/tools, the same way the pinned Ghostty
# artifact is installed: one version, one recorded checksum, verified before it is used.
#
# `brew install xcodegen` was what CI ran before, and it takes whatever Homebrew ships that
# day. On 2026-08-10 that became 2.46.0, which orders targets by declaration instead of
# alphabetically, so the project generated on a runner stopped matching the one generated
# by the 2.45.4 a developer happened to have. Nothing in the repository had changed. The
# generator is a build input, and an unpinned build input eventually disagrees with itself.
#
# The pin is 2.45.4 because that is the generator the shipped 0.1.0 was built with, verified
# end to end. 2.46.0 was tried and rejected on evidence rather than on age: besides the
# reordering, it adds an Embed Frameworks phase copying TenonIntentCore.framework into the
# bundle, and nothing in the app links that framework dynamically — `otool -L` on the shipped
# binary and on TenonCore names only TenonCore, OrderedCollections and JSONSchema. It would
# ship a fourth framework nobody loads, and make the artifact differ from the one Apple
# notarized. Upgrading is its own change, gated on a build that runs.
#
# Bumping it: change VERSION and ARCHIVE_SHA256 together, run this, run `xcodegen generate`,
# and commit the regenerated project in the same change — the point of pinning is that those
# three move as one.
set -euo pipefail

readonly VERSION="2.45.4"
readonly REPO="yonaskolb/XcodeGen"
readonly ARCHIVE_SHA256="090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"

# Where the rest of the repository expects to find it. `share/xcodegen/SettingPresets` ships
# beside the binary and is read at generate time, so the whole tree is installed, not just
# the executable.
readonly INSTALL_DIR=".build/tools/xcodegen"
readonly BINARY="$INSTALL_DIR/bin/xcodegen"

installed_version() {
    [[ -x "$BINARY" ]] || return 1
    "$BINARY" --version 2>/dev/null | sed -n 's/^Version: //p'
}

main() {
    cd "$(dirname "$0")/.."

    if [[ "$(installed_version || true)" == "$VERSION" ]]; then
        echo "XcodeGen $VERSION already installed"
        return
    fi

    local staging
    staging="$(mktemp -d "./.xcodegen-install.XXXXXX")"
    # Expanded now, not at exit: the trap outlives this function, and by the time it runs
    # a `local` would be out of scope.
    # shellcheck disable=SC2064
    trap "rm -rf '$staging'" EXIT

    echo "==> Downloading XcodeGen $VERSION from $REPO"
    curl --fail --location --show-error --proto '=https' --tlsv1.2 \
        --retry 3 --output "$staging/xcodegen.zip" \
        "https://github.com/$REPO/releases/download/$VERSION/xcodegen.zip"

    echo "==> Verifying pinned SHA-256 checksum"
    local actual
    actual="$(shasum -a 256 "$staging/xcodegen.zip" | awk '{print $1}')"
    if [[ "$actual" != "$ARCHIVE_SHA256" ]]; then
        echo "checksum mismatch for xcodegen.zip: expected $ARCHIVE_SHA256, got $actual" >&2
        return 1
    fi

    # ditto rather than unzip: the archive carries extended attributes, and unzip writes
    # them back out as ._* files instead of restoring them.
    ditto -x -k "$staging/xcodegen.zip" "$staging/extracted"
    [[ -x "$staging/extracted/xcodegen/bin/xcodegen" ]] || {
        echo "the archive did not contain bin/xcodegen" >&2
        return 1
    }

    echo "==> Installing to $INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    rm -rf "$INSTALL_DIR"
    mv "$staging/extracted/xcodegen" "$INSTALL_DIR"

    # What was installed is what will run — checked against the binary rather than against
    # the name of the file it came out of.
    local got
    got="$(installed_version || true)"
    if [[ "$got" != "$VERSION" ]]; then
        echo "installed XcodeGen reports '$got', expected '$VERSION'" >&2
        rm -rf "$INSTALL_DIR"
        return 1
    fi
    echo "XcodeGen $VERSION ready"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
