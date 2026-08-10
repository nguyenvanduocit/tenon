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

# The terminfo entry is the one build input that is compiled here rather than downloaded,
# so what has to be proved is that compiling is lossless: the entry installed into an empty
# directory must decompile back to exactly the committed source, extended capabilities and
# all. A tic that silently drops `Tc` or `Sync` would otherwise ship a terminal that claims
# less than Ghostty does.
terminfo_destination="$fixture_directory/terminfo"
install_terminfo scripts/ghostty.terminfo "$terminfo_destination"

if [[ ! -f "$terminfo_destination/78/xterm-ghostty" || ! -f "$terminfo_destination/67/ghostty" ]]; then
    echo "install_terminfo did not compile both entry names" >&2
    exit 1
fi

if ! diff -q \
    <(terminfo_entry_body "$terminfo_destination") \
    <(grep -v '^#' scripts/ghostty.terminfo) >/dev/null; then
    echo "the compiled terminfo entry does not match its source" >&2
    exit 1
fi

# A destination left behind by an older or corrupted install has to be replaced rather than
# trusted, because the failure it causes appears at runtime inside the terminal.
printf 'not a terminfo entry\n' >"$terminfo_destination/78/xterm-ghostty"
install_terminfo scripts/ghostty.terminfo "$terminfo_destination"
if ! diff -q \
    <(terminfo_entry_body "$terminfo_destination") \
    <(grep -v '^#' scripts/ghostty.terminfo) >/dev/null; then
    echo "install_terminfo left a corrupted entry in place" >&2
    exit 1
fi

if install_terminfo "$fixture_directory/absent.terminfo" \
    "$fixture_directory/unused" >/dev/null 2>&1; then
    echo "install_terminfo accepted a missing source file" >&2
    exit 1
fi

echo "setup-ghosttykit integrity tests passed"
