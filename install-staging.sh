#!/usr/bin/env bash
# Build the current checkout and install it beside the stable Tenon app.
#
# This keeps the Tenon instance hosting the development session alive while a
# fresh candidate is built and installed. The staging app has its own bundle
# name and LaunchServices identity, so replacing it never replaces or quits
# /Applications/Tenon.app.
#
# Usage and overrides are the same as install.sh:
#   ./install-staging.sh
#   CONFIGURATION=Debug APP_DEST=/some/dir ./install-staging.sh
#
# Production and staging are each singletons inside their own isolated runtime
# channel, so both bundles may stay open while this build is exercised.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

export INSTALL_APP_NAME="Tenon Staging.app"
export INSTALL_DISPLAY_NAME="Tenon Staging"
export INSTALL_BUNDLE_ID="com.firegroup.tenon.staging"

exec "$REPO_ROOT/install.sh" "$@"
