#!/usr/bin/env bash
# Fetch the prebuilt GhosttyKit.xcframework + resources (Muxy pattern: zig never
# runs in this repo). Pinned to a dated release of the muxy-app/ghostty soft fork
# until Tenon stands up its own fork + release pipeline (Phase 0.5).
set -euo pipefail

readonly TAG="build-2026-04-29"
readonly REPO="muxy-app/ghostty"
readonly XCFRAMEWORK_SHA256="8f30a557470383e21f1dcfcf0b8278a3a08eb6ca5a886c32238425fa8b43bf8e"
readonly RESOURCES_SHA256="877081c96cf4bc97fa7a15c397ad285f6e5c544ec43778b0903011eff9a74ca2"
readonly LIBRARY_SHA256="e7872f5fb91005abcfb6260dcc74dd7ae2a3bf296be167066a84963bde2252c8"
readonly HEADER_SHA256="e0ee70d9fddb2066dab91904e48a704cda441497f2630fc3df28a7004a180d11"
readonly RESOURCES_TREE_SHA256="4811bcb285f008936c7c578dc4c335c663b9932bad2757ca5a7e18d69a412968"

verify_sha256() {
    local archive="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "checksum mismatch for $(basename "$archive"): expected $expected, got $actual" >&2
        return 1
    fi
}

tree_sha256() {
    local root="$1"
    (
        cd "$root"
        find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
            shasum -a 256 "$file"
        done
    ) | shasum -a 256 | awk '{print $1}'
}

verify_payload() {
    local framework="$1"
    local header="$2"
    local resources="$3"
    verify_sha256 "$framework/macos-arm64_x86_64/ghostty-internal.a" "$LIBRARY_SHA256" || return 1
    verify_sha256 "$framework/macos-arm64_x86_64/Headers/ghostty.h" "$HEADER_SHA256" || return 1
    verify_sha256 "$header" "$HEADER_SHA256" || return 1
    cmp -s "$framework/macos-arm64_x86_64/Headers/ghostty.h" "$header" || return 1
    local actual_resources_sha256
    actual_resources_sha256="$(tree_sha256 "$resources")"
    if [[ "$actual_resources_sha256" != "$RESOURCES_TREE_SHA256" ]]; then
        echo "resource tree checksum mismatch: expected $RESOURCES_TREE_SHA256, got $actual_resources_sha256" >&2
        return 1
    fi
}

validate_archive_paths() {
    local archive="$1"
    tar -tzf "$archive" >/dev/null
    validate_archive_listing "$(basename "$archive")" < <(tar -tzf "$archive")
}

validate_archive_listing() {
    local archive_name="$1"
    local entry
    while IFS= read -r entry; do
        if [[ "$entry" == /* || "$entry" == ".." || "$entry" == ../* || "$entry" == */../* || "$entry" == */.. ]]; then
            echo "unsafe archive entry in $archive_name: $entry" >&2
            return 1
        fi
    done
}

expected_provenance() {
    printf '%s\n' \
        "repository=$REPO" \
        "tag=$TAG" \
        "xcframework_sha256=$XCFRAMEWORK_SHA256" \
        "resources_sha256=$RESOURCES_SHA256" \
        "library_sha256=$LIBRARY_SHA256" \
        "header_sha256=$HEADER_SHA256" \
        "resources_tree_sha256=$RESOURCES_TREE_SHA256"
}

installation_is_current() {
    [[ -d GhosttyKit.xcframework ]] || return 1
    [[ -f GhosttyKit/ghostty.h ]] || return 1
    [[ -d Resources/ghostty ]] || return 1
    [[ -f GhosttyKit.xcframework/.tenon-provenance ]] || return 1
    diff -q <(expected_provenance) GhosttyKit.xcframework/.tenon-provenance >/dev/null || return 1
    verify_payload GhosttyKit.xcframework GhosttyKit/ghostty.h Resources/ghostty
}

main() {
    cd "$(dirname "$0")/.."

    if installation_is_current; then
        echo "GhosttyKit $TAG already set up and verified"
        return
    fi

    local download_directory
    local install_directory
    download_directory="$(mktemp -d "${TMPDIR:-/tmp}/tenon-ghostty-download.XXXXXX")"
    install_directory="$(mktemp -d "./.ghosttykit-install.XXXXXX")"
    trap "rm -rf '$download_directory' '$install_directory'" EXIT

    local xcframework_archive="$download_directory/GhosttyKit.xcframework.tar.gz"
    local resources_archive="$download_directory/GhosttyKit-resources.tar.gz"

    echo "==> Downloading GhosttyKit $TAG from $REPO"
    curl --fail --location --show-error --proto '=https' --tlsv1.2 \
        --retry 3 --output "$xcframework_archive" \
        "https://github.com/$REPO/releases/download/$TAG/GhosttyKit.xcframework.tar.gz"
    curl --fail --location --show-error --proto '=https' --tlsv1.2 \
        --retry 3 --output "$resources_archive" \
        "https://github.com/$REPO/releases/download/$TAG/GhosttyKit-resources.tar.gz"

    echo "==> Verifying pinned SHA-256 checksums"
    verify_sha256 "$xcframework_archive" "$XCFRAMEWORK_SHA256"
    verify_sha256 "$resources_archive" "$RESOURCES_SHA256"
    validate_archive_paths "$xcframework_archive"
    validate_archive_paths "$resources_archive"

    local stage="$install_directory/stage"
    mkdir -p "$stage/Resources"
    echo "==> Extracting into staging"
    tar -xzf "$xcframework_archive" -C "$stage"
    tar -xzf "$resources_archive" -C "$stage/Resources"
    [[ -f "$stage/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h" ]]
    [[ -f "$stage/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a" ]]
    [[ -d "$stage/Resources/ghostty" ]]
    cp "$stage/GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h" "$stage/ghostty.h"
    verify_payload "$stage/GhosttyKit.xcframework" "$stage/ghostty.h" "$stage/Resources/ghostty"
    expected_provenance >"$stage/GhosttyKit.xcframework/.tenon-provenance"

    echo "==> Installing verified artifacts"
    local previous="$install_directory/previous"
    mkdir -p "$previous"
    if [[ -e GhosttyKit.xcframework ]]; then
        mv GhosttyKit.xcframework "$previous/GhosttyKit.xcframework"
    fi
    if [[ -e Resources/ghostty ]]; then
        mv Resources/ghostty "$previous/ghostty"
    fi
    if [[ -e GhosttyKit/ghostty.h ]]; then
        mv GhosttyKit/ghostty.h "$previous/ghostty.h"
    fi

    if ! mv "$stage/GhosttyKit.xcframework" GhosttyKit.xcframework; then
        [[ ! -e "$previous/GhosttyKit.xcframework" ]] \
            || mv "$previous/GhosttyKit.xcframework" GhosttyKit.xcframework
        [[ ! -e "$previous/ghostty" ]] || mv "$previous/ghostty" Resources/ghostty
        [[ ! -e "$previous/ghostty.h" ]] || mv "$previous/ghostty.h" GhosttyKit/ghostty.h
        return 1
    fi
    mkdir -p Resources
    if ! mv "$stage/Resources/ghostty" Resources/ghostty; then
        rm -rf GhosttyKit.xcframework
        [[ ! -e "$previous/GhosttyKit.xcframework" ]] \
            || mv "$previous/GhosttyKit.xcframework" GhosttyKit.xcframework
        [[ ! -e "$previous/ghostty" ]] || mv "$previous/ghostty" Resources/ghostty
        [[ ! -e "$previous/ghostty.h" ]] || mv "$previous/ghostty.h" GhosttyKit/ghostty.h
        return 1
    fi

    mkdir -p GhosttyKit
    if ! mv "$stage/ghostty.h" GhosttyKit/ghostty.h; then
        rm -rf GhosttyKit.xcframework Resources/ghostty
        [[ ! -e "$previous/GhosttyKit.xcframework" ]] \
            || mv "$previous/GhosttyKit.xcframework" GhosttyKit.xcframework
        [[ ! -e "$previous/ghostty" ]] || mv "$previous/ghostty" Resources/ghostty
        [[ ! -e "$previous/ghostty.h" ]] || mv "$previous/ghostty.h" GhosttyKit/ghostty.h
        return 1
    fi
    echo "GhosttyKit $TAG ready"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
