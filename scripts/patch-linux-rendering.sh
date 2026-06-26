#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
ROOT_DIR=$(unset CDPATH; cd -- "$SCRIPT_DIR/.." && pwd -P)

RESOURCES_DIR="$ROOT_DIR/build/app/Codex Installer/Codex.app/Contents/Resources"
ASAR_PATH="$RESOURCES_DIR/app.asar"
WORK_DIR="$ROOT_DIR/build/linux-rendering-patch"
EXTRACT_DIR="$WORK_DIR/app"
BACKUP_PATH="$WORK_DIR/app.asar.pre-linux-rendering-patch"

if [[ ! -f "$ASAR_PATH" ]]; then
  printf 'Required app.asar not found: %s\n' "$ASAR_PATH" >&2
  exit 1
fi

rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"

npx --yes @electron/asar extract "$ASAR_PATH" "$EXTRACT_DIR"

mapfile -t MAIN_FILES < <(find "$EXTRACT_DIR/.vite/build" -maxdepth 1 -type f -name 'main-*.js' | sort)
if [[ "${#MAIN_FILES[@]}" -ne 1 ]]; then
  printf 'Expected exactly one .vite/build/main-*.js file, found %s\n' "${#MAIN_FILES[@]}" >&2
  printf '%s\n' "${MAIN_FILES[@]}" >&2
  exit 1
fi

MAIN_FILE="${MAIN_FILES[0]}"

node - "$MAIN_FILE" <<'NODE'
const fs = require("node:fs")

const file = process.argv[2]
let source = fs.readFileSync(file, "utf8")
let changed = false

function replaceOnce(oldText, newText, label) {
  if (source.includes(newText)) {
    console.log(`${label}: already patched`)
    return
  }

  if (!source.includes(oldText)) {
    throw new Error(`${label}: expected minified pattern not found`)
  }

  source = source.replace(oldText, newText)
  changed = true
  console.log(`${label}: patched`)
}

replaceOnce(
  "function S3({platform:e,appearance:t,opaqueWindowSurfaceEnabled:n,prefersDarkColors:r}){return n?{backgroundColor:r?G4:K4,backgroundMaterial:e===`win32`?`none`:null}:e===`win32`&&!g3(t)?{backgroundColor:W4,backgroundMaterial:`mica`}:{backgroundColor:W4,backgroundMaterial:null}}",
  "function S3({platform:e,appearance:t,opaqueWindowSurfaceEnabled:n,prefersDarkColors:r}){return n||e===`linux`?{backgroundColor:r?G4:K4,backgroundMaterial:e===`win32`?`none`:null}:e===`win32`&&!g3(t)?{backgroundColor:W4,backgroundMaterial:`mica`}:{backgroundColor:W4,backgroundMaterial:null}}",
  "Linux opaque background"
)

replaceOnce(
  "...n===`darwin`?{type:`panel`}:{}}}",
  "...n===`darwin`?{type:`panel`}:{},...n===`linux`?{transparent:!1}:{}}}",
  "Linux transparent window override"
)

if (changed) {
  fs.writeFileSync(file, source)
}
NODE

if [[ ! -f "$BACKUP_PATH" ]]; then
  cp "$ASAR_PATH" "$BACKUP_PATH"
fi

npx --yes @electron/asar pack "$EXTRACT_DIR" "$ASAR_PATH"

printf 'Patched Linux rendering in %s\n' "$ASAR_PATH"
