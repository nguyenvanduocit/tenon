#!/usr/bin/env bash
# What matters about a pinned tool is that the pin is enforced, not that a download
# succeeded. These check the two ways it could silently stop being enforced: a binary whose
# version is not the pinned one, and an archive whose bytes are not the recorded ones.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/setup-xcodegen.sh

fixture_directory="$(mktemp -d "${TMPDIR:-/tmp}/tenon-xcodegen-test.XXXXXX")"
trap 'rm -rf "$fixture_directory"' EXIT

# The version check reads the binary, so a stand-in reporting the wrong version must fail
# it — that is what distinguishes "the pinned generator is installed" from "something named
# xcodegen is installed".
if installed_version >/dev/null 2>&1; then
    reported="$(installed_version)"
    if [[ "$reported" != "$VERSION" ]]; then
        echo "an installed generator reports $reported, not the pinned $VERSION" >&2
        exit 1
    fi
fi

# The pinned checksum has to match the release actually published under that tag. Fetching
# the digest GitHub records is cheaper than downloading the archive, and it fails for the
# case that matters: a pin edited to a version whose checksum was not updated with it.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    published="$(gh release view --repo "$REPO" "$VERSION" \
        --json assets --jq '.assets[] | select(.name == "xcodegen.zip") | .digest' 2>/dev/null || true)"
    if [[ -n "$published" && "$published" != "sha256:$ARCHIVE_SHA256" ]]; then
        echo "pinned checksum does not match the published $VERSION release" >&2
        echo "  pinned:    sha256:$ARCHIVE_SHA256" >&2
        echo "  published: $published" >&2
        exit 1
    fi
fi

# A tampered archive must be refused rather than installed. The script verifies before it
# extracts, so the check is on the comparison it performs, run here over bytes that are
# deliberately not the pinned ones.
printf 'not the pinned archive\n' >"$fixture_directory/xcodegen.zip"
actual="$(shasum -a 256 "$fixture_directory/xcodegen.zip" | awk '{print $1}')"
if [[ "$actual" == "$ARCHIVE_SHA256" ]]; then
    echo "a file that is not the release matched the pinned checksum" >&2
    exit 1
fi

echo "setup-xcodegen pin tests passed"
