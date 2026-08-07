#!/usr/bin/env bash
# prune-build-cache.sh — delete regenerable build junk from .build before a build.
#
# Tenon builds through exactly two trees, both inside the gitignored .build:
#
#   arm64-apple-macosx/   SwiftPM — swift build/test/run, and install.sh's tenon-cli
#   xcode/                ONE xcodebuild derived data path, shared by every configuration
#
# and the dependency graph is checked out once, into checkouts/ + repositories/, which
# both of them read (xcodebuild is aimed at it with -clonedSourcePackagesDirPath).
#
# Any other build tree in there is a duplicate universe: its own dependency checkout,
# its own module cache, gigabytes of it. This script recognises them by shape — a
# SwiftPM scratch path carries workspace-state.json, a derived data path carries
# Build/ or ModuleCache.noindex — so a tree invented by a future script or a stray
# xcodebuild invocation gets collected too, without being named here.
#
# What it never touches: the two trees above, the shared dependency caches
# (checkouts/, repositories/, artifacts/, prebuilts/), and their incremental object
# files — losing those turns a 10-second edit-run loop into a full rebuild.
#
# sourcekit-lsp's index store (.build/index-build) has its own dependency checkout, so
# it is collected as well. An editor with background indexing on will rebuild it.
#
# Usage:
#   ./scripts/prune-build-cache.sh          # drop duplicate trees, keep both real ones
#   DEEP=1 ./scripts/prune-build-cache.sh   # also drop both build trees (deps survive)
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD=".build"
[ -d "$BUILD" ] || exit 0

# Several agents share this one checkout. Deleting caches out from under a running
# compile breaks it, so a build in flight means this run does nothing at all.
if pgrep -f 'swift-build|swift-frontend|swift-driver|xcodebuild' >/dev/null 2>&1; then
    echo "==> Skipping build-cache prune: another build is running"
    exit 0
fi

# The trees and caches that make an incremental build fast.
KEEP="arm64-apple-macosx xcode checkouts repositories artifacts prebuilts"

freed_kb=0
drop() {  # drop <path> <why>
    [ -e "$1" ] || return 0
    local kb
    kb="$(du -sk "$1" | cut -f1)"
    printf '    %-24s %6s  %s\n' "$(basename "$1")" "$(du -sh "$1" | cut -f1)" "$2"
    rm -rf "$1"
    freed_kb=$((freed_kb + kb))
}

echo "==> Pruning build cache ($(du -sh "$BUILD" | cut -f1) in $PWD/$BUILD)"

for entry in "$BUILD"/*; do
    [ -d "$entry" ] || continue
    # .build/debug and .build/release are SwiftPM's own symlinks into the tree it owns.
    if [ -L "$entry" ]; then continue; fi
    name="$(basename "$entry")"
    case " $KEEP " in *" $name "*) continue ;; esac

    if [ -f "$entry/workspace-state.json" ]; then
        drop "$entry" "duplicate SwiftPM scratch path"
    elif [ -d "$entry/Build" ] || [ -d "$entry/ModuleCache.noindex" ]; then
        drop "$entry" "duplicate Xcode derived data"
    fi
done

# Inside the derived data path, two stores are regenerable and large: the dependency
# checkout Xcode makes when nobody aims it at the shared one, and its source index.
# ModuleCache.noindex stays — one copy of it is what makes the next build quick.
drop "$BUILD/xcode/SourcePackages" "deps are shared via -clonedSourcePackagesDirPath"
drop "$BUILD/xcode/Index.noindex" "Xcode source index, regenerates"

if [ -n "${DEEP:-}" ]; then
    drop "$BUILD/arm64-apple-macosx" "DEEP: SwiftPM build tree"
    drop "$BUILD/xcode" "DEEP: Xcode derived data"
fi

if [ "$freed_kb" -eq 0 ]; then
    echo "    nothing to prune"
else
    printf '    freed %s — %s remains\n' \
        "$(echo "$freed_kb" | awk '{ if ($1 >= 1048576) printf "%.1f GB", $1/1048576;
                                     else printf "%d MB", $1/1024 }')" \
        "$(du -sh "$BUILD" | cut -f1)"
fi
