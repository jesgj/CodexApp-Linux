#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
RESOURCES_DIR="$ROOT_DIR/build/app/Codex Installer/Codex.app/Contents/Resources"
ASAR_PATH="$RESOURCES_DIR/app.asar"
ELECTRON_BIN="$ROOT_DIR/build/electron-runtime/node_modules/electron/dist/electron"

export CODEX_CLI_PATH="$RESOURCES_DIR/codex"
export ELECTRON_RENDERER_URL="file://$ASAR_PATH/webview/index.html"

exec "$ELECTRON_BIN" "$ASAR_PATH" "$@"
