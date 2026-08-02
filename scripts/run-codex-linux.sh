#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
ROOT_DIR=$(unset CDPATH; cd -- "$SCRIPT_DIR/.." && pwd -P)
source "$SCRIPT_DIR/resolve-resources.sh"

RESOURCES_DIR=$(resolve_resources_dir "$ROOT_DIR")
ASAR_PATH="$RESOURCES_DIR/app.asar"
ELECTRON_BIN="$ROOT_DIR/build/electron-runtime/node_modules/electron/dist/electron"

if [[ ! -x "$ELECTRON_BIN" ]]; then
  printf 'Linux Electron runtime is not executable: %s\n' "$ELECTRON_BIN" >&2
  exit 1
fi

if [[ ! -x "$RESOURCES_DIR/codex" ]]; then
  printf 'Linux Codex CLI is not executable: %s\n' "$RESOURCES_DIR/codex" >&2
  exit 1
fi

export CODEX_CLI_PATH="$RESOURCES_DIR/codex"
export ELECTRON_RENDERER_URL="file://$ASAR_PATH/webview/index.html"

exec "$ELECTRON_BIN" "$ASAR_PATH" --disable-gpu-compositing "$@"
