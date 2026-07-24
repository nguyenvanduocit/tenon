#!/usr/bin/env bash
# Fetch the prebuilt GhosttyKit.xcframework + resources (Muxy pattern: zig never
# runs in this repo). Pinned to a dated release of the muxy-app/ghostty soft fork
# until Tenon stands up its own fork + release pipeline (Phase 0.5).
set -euo pipefail

TAG="build-2026-04-29"
REPO="muxy-app/ghostty"

cd "$(dirname "$0")/.."

if [ -d GhosttyKit.xcframework ] && [ -f GhosttyKit/ghostty.h ] && [ -d Resources/ghostty ]; then
    echo "GhosttyKit $TAG already set up"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading GhosttyKit $TAG from $REPO"
curl -fsSL -o "$TMP/xcframework.tar.gz" \
    "https://github.com/$REPO/releases/download/$TAG/GhosttyKit.xcframework.tar.gz"
curl -fsSL -o "$TMP/resources.tar.gz" \
    "https://github.com/$REPO/releases/download/$TAG/GhosttyKit-resources.tar.gz"

echo "==> Extracting"
tar -xzf "$TMP/xcframework.tar.gz"
mkdir -p Resources
tar -xzf "$TMP/resources.tar.gz" -C Resources

echo "==> Syncing ghostty.h from xcframework"
cp GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h GhosttyKit/ghostty.h

echo "GhosttyKit $TAG ready"
