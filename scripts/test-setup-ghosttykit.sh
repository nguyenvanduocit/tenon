#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/setup-ghosttykit.sh

fixture_directory="$(mktemp -d "${TMPDIR:-/tmp}/tenon-ghostty-test.XXXXXX")"
trap 'rm -rf "$fixture_directory"' EXIT

printf 'known payload\n' >"$fixture_directory/payload"
known_sha="$(shasum -a 256 "$fixture_directory/payload" | awk '{print $1}')"
verify_sha256 "$fixture_directory/payload" "$known_sha"

if verify_sha256 "$fixture_directory/payload" \
    "0000000000000000000000000000000000000000000000000000000000000000" \
    >/dev/null 2>&1; then
    echo "verify_sha256 accepted a mismatched digest" >&2
    exit 1
fi

mkdir -p "$fixture_directory/safe/root"
printf 'safe\n' >"$fixture_directory/safe/root/file"
tar -czf "$fixture_directory/safe.tar.gz" -C "$fixture_directory/safe" root
validate_archive_paths "$fixture_directory/safe.tar.gz"

if printf '%s\n' '../outside' | validate_archive_listing hostile.tar.gz >/dev/null 2>&1; then
    echo "archive validation accepted a parent-directory traversal" >&2
    exit 1
fi

if printf '%s\n' '/tmp/outside' | validate_archive_listing hostile.tar.gz >/dev/null 2>&1; then
    echo "archive validation accepted an absolute path" >&2
    exit 1
fi

mkdir -p "$fixture_directory/tree/nested"
printf 'one\n' >"$fixture_directory/tree/a"
printf 'two\n' >"$fixture_directory/tree/nested/b"
tree_before="$(tree_sha256 "$fixture_directory/tree")"
printf 'changed\n' >"$fixture_directory/tree/nested/b"
tree_after="$(tree_sha256 "$fixture_directory/tree")"
if [[ "$tree_before" == "$tree_after" ]]; then
    echo "tree_sha256 did not detect a changed installed resource" >&2
    exit 1
fi

echo "setup-ghosttykit integrity tests passed"
