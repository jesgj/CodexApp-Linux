#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
ROOT_DIR=$(unset CDPATH; cd -- "$SCRIPT_DIR/.." && pwd -P)
source "$SCRIPT_DIR/resolve-resources.sh"

ASAR_VERSION="4.2.1"
RESOURCES_DIR=$(resolve_resources_dir "$ROOT_DIR")
ASAR_PATH="$RESOURCES_DIR/app.asar"
WORK_DIR="$ROOT_DIR/build/linux-rendering-patch"
EXTRACT_DIR="$WORK_DIR/app"
PACKED_ASAR="$WORK_DIR/app.asar.patched"
CHANGED_MARKER="$WORK_DIR/changed"

run_asar() {
  pixi run npx --yes "@electron/asar@$ASAR_VERSION" "$@"
}

if [[ ! -f "$ASAR_PATH" ]]; then
  printf 'Required app.asar not found: %s\n' "$ASAR_PATH" >&2
  exit 1
fi

SOURCE_HASH=$(sha256sum "$ASAR_PATH" | cut -d ' ' -f1)
BACKUP_PATH="$WORK_DIR/${SOURCE_HASH}.asar.pre-linux-rendering-patch"

rm -rf "$EXTRACT_DIR" "$PACKED_ASAR" "$CHANGED_MARKER"
mkdir -p "$EXTRACT_DIR"

run_asar extract "$ASAR_PATH" "$EXTRACT_DIR"

mapfile -t MAIN_FILES < <(find "$EXTRACT_DIR/.vite/build" -maxdepth 1 -type f -name 'main-*.js' | sort)
if [[ "${#MAIN_FILES[@]}" -ne 1 ]]; then
  printf 'Expected exactly one .vite/build/main-*.js file, found %s\n' "${#MAIN_FILES[@]}" >&2
  printf '%s\n' "${MAIN_FILES[@]}" >&2
  exit 1
fi

MAIN_FILE="${MAIN_FILES[0]}"

node - "$MAIN_FILE" "$CHANGED_MARKER" <<'NODE'
const fs = require("node:fs")

const file = process.argv[2]
const changedMarker = process.argv[3]
let source = fs.readFileSync(file, "utf8")
let changed = false

function requireSingle(matches, label) {
  if (matches.length !== 1) {
    throw new Error(`${label}: expected exactly one match, found ${matches.length}`)
  }
  return matches[0]
}

function patchOpaqueBackground() {
  const unpatched = [...source.matchAll(/(function \w+\(\{platform:(\w+),appearance:\w+,opaqueWindowSurfaceEnabled:(\w+),prefersDarkColors:\w+\}\)\{return )(\w+)\?/g)]
    .filter((match) => match[3] === match[4])
  const patched = [...source.matchAll(/(function \w+\(\{platform:(\w+),appearance:\w+,opaqueWindowSurfaceEnabled:(\w+),prefersDarkColors:\w+\}\)\{return )(\w+)\|\|\2==='linux'\?/g)]
    .filter((match) => match[3] === match[4])

  if (patched.length === 1) {
    console.log("Linux opaque background: already patched")
    return
  }
  if (patched.length > 1) {
    throw new Error(`Linux opaque background: expected at most one patched match, found ${patched.length}`)
  }

  const [, prefix, platform, , condition] = requireSingle(unpatched, "Linux opaque background")
  source = source.replace(`${prefix}${condition}?`, `${prefix}${condition}||${platform}==='linux'?`)
  changed = true
  console.log("Linux opaque background: patched")
}

function patchTransparentWindows() {
  const patched = [...source.matchAll(/\.\.\.(\w+)===`darwin`\?\{type:`panel`\}:\{\},\.\.\.\1===`linux`\?\{transparent:!1\}:\{\}\}\}/g)]
  if (patched.length === 1) {
    console.log("Linux transparent window override: already patched")
    return
  }
  if (patched.length > 1) {
    throw new Error(`Linux transparent window override: expected at most one patched match, found ${patched.length}`)
  }

  const [fullMatch, platform] = requireSingle(
    [...source.matchAll(/\.\.\.(\w+)===`darwin`\?\{type:`panel`\}:\{\}\}\}/g)],
    "Linux transparent window override"
  )
  const replacement = `...${platform}===\`darwin\`?{type:\`panel\`}:{},...${platform}===\`linux\`?{transparent:!1}:{}}}`
  source = source.replace(fullMatch, replacement)
  changed = true
  console.log("Linux transparent window override: patched")
}

function patchVoiceOverlayClose() {
  const electronBindings = [...new Set([...source.matchAll(/([A-Za-z_$][\w$]*)\.app\.quit\(\)/g)].map((match) => match[1]))]
  if (electronBindings.length !== 1) {
    throw new Error("Linux voice overlay close: expected one Electron binding")
  }

  const electron = electronBindings[0]
  const listener = `uue(this,i),${electron}.app.on(\`linux-close-voice-overlay\`,()=>{this.markAppQuitting(),this.close()})}isOpen()`
  if (source.includes(listener)) {
    console.log("Linux voice overlay shutdown listener: already patched")
  } else {
    const existingListeners = [...source.matchAll(/uue\(this,i\),[A-Za-z_$][\w$]*\.app\.on\(`linux-close-voice-overlay`,\(\)=>\{this\.markAppQuitting\(\),this\.close\(\)\}\)}/g)]
    if (existingListeners.length !== 0) {
      throw new Error("Linux voice overlay shutdown listener: unexpected existing listener")
    }
    const [listenerAnchor] = requireSingle(
      [...source.matchAll(/uue\(this,i\)}isOpen\(\)/g)],
      "Linux voice overlay shutdown listener"
    )
    source = source.replace(listenerAnchor, listener)
    changed = true
    console.log("Linux voice overlay shutdown listener: patched")
  }

  const patched = [...source.matchAll(/([A-Za-z_$][\w$]*)\.on\(`close`,([A-Za-z_$][\w$]*)=>\{this\.persistPrimaryWindowBounds\(\1\);let ([A-Za-z_$][\w$]*)=this\.getPrimaryWindows\(\)\.some\(([A-Za-z_$][\w$]*)=>\4!==\1\);if\(process\.platform===`linux`&&!this\.isAppQuitting&&!\3\)\{\2\.preventDefault\(\),([A-Za-z_$][\w$]*)\.app\.emit\(`linux-close-voice-overlay`\),\5\.app\.quit\(\);return\}/g)]
  if (patched.length === 1) {
    if (patched[0][5] !== electron) {
      throw new Error("Linux voice overlay close: Electron binding mismatch")
    }
    console.log("Linux voice overlay close: already patched")
    return
  }
  if (patched.length > 1) {
    throw new Error(`Linux voice overlay close: expected at most one patched match, found ${patched.length}`)
  }

  const targetedPatched = [...source.matchAll(/if\(process\.platform===`linux`&&!this\.isAppQuitting&&!([A-Za-z_$][\w$]*)&&[A-Za-z_$][\w$]*\.BrowserWindow\.getAllWindows\(\)\.some\(overlayWindow=>this\.windowAppearances\.get\(overlayWindow\.id\)===`avatarOverlay`&&overlayWindow\.isVisible\(\)\)\)\{([A-Za-z_$][\w$]*)\.preventDefault\(\),([A-Za-z_$][\w$]*)\.app\.emit\(`linux-close-voice-overlay`\),\3\.app\.quit\(\);return\}/g)]
  if (targetedPatched.length > 1) {
    throw new Error(`Linux voice overlay close: expected at most one targeted patch, found ${targetedPatched.length}`)
  }

  const legacyTargeted = [...source.matchAll(/if\(process\.platform===`linux`&&!this\.isAppQuitting&&!([A-Za-z_$][\w$]*)&&[A-Za-z_$][\w$]*\.BrowserWindow\.getAllWindows\(\)\.some\(overlayWindow=>this\.windowAppearances\.get\(overlayWindow\.id\)===`avatarOverlay`&&overlayWindow\.isVisible\(\)\)\)\{([A-Za-z_$][\w$]*)\.preventDefault\(\),([A-Za-z_$][\w$]*)\.app\.quit\(\);return\}/g)]
  if (legacyTargeted.length > 1) {
    throw new Error(`Linux voice overlay close: expected at most one legacy targeted patch, found ${legacyTargeted.length}`)
  }

  let fullMatch
  let hasOtherWindows
  let closeEvent
  let sourceElectron
  let preserveTrayBranch = false
  if (targetedPatched.length === 1) {
    [fullMatch, hasOtherWindows, closeEvent, sourceElectron] = targetedPatched[0]
    console.log("Linux voice overlay close: upgraded")
  } else if (legacyTargeted.length === 1) {
    [fullMatch, hasOtherWindows, closeEvent, sourceElectron] = legacyTargeted[0]
    console.log("Linux voice overlay close: upgraded")
  } else {
    [fullMatch, hasOtherWindows, closeEvent] = requireSingle(
      [...source.matchAll(/if\(\(process\.platform===`win32`\|\|process\.platform===`linux`\)&&!this\.isAppQuitting&&this\.options\.canHideLastWindowToTray\?\.\(\)===!0&&!([A-Za-z_$][\w$]*)\)\{([A-Za-z_$][\w$]*)\.preventDefault\(\),[A-Za-z_$][\w$]*\.hide\(\);return\}/g)],
      "Linux voice overlay close"
    )
    preserveTrayBranch = true
    console.log("Linux voice overlay close: patched")
  }
  if (sourceElectron != null && sourceElectron !== electron) {
    throw new Error("Linux voice overlay close: Electron binding mismatch")
  }

  const replacement = `if(process.platform===\`linux\`&&!this.isAppQuitting&&!${hasOtherWindows}){${closeEvent}.preventDefault(),${electron}.app.emit(\`linux-close-voice-overlay\`),${electron}.app.quit();return}`
  source = source.replace(fullMatch, preserveTrayBranch ? `${replacement}${fullMatch}` : replacement)
  changed = true
}

function patchPrimaryWindowCloseHook() {
  // Some upstream primary windows skip the y-guarded close handler below.
  const electronBindings = [...new Set([...source.matchAll(/([A-Za-z_$][\w$]*)\.app\.quit\(\)/g)].map((match) => match[1]))]
  if (electronBindings.length !== 1) {
    throw new Error("Linux primary window close: expected one Electron binding")
  }

  const electron = electronBindings[0]
  const patched = [...source.matchAll(/this\.installWebContentsDiagnostics\(([A-Za-z_$][\w$]*)\),this\.registerWindow\(\1,([A-Za-z_$][\w$]*),([A-Za-z_$][\w$]*),([A-Za-z_$][\w$]*),`register`\),\4===`primary`&&\1\.prependListener\(`close`,closeEvent=>\{let otherPrimary=this\.getPrimaryWindows\(\)\.some\(primaryWindow=>primaryWindow!==\1\);if\(process\.platform===`linux`&&!this\.isAppQuitting&&!otherPrimary\)\{closeEvent\.preventDefault\(\),([A-Za-z_$][\w$]*)\.app\.emit\(`linux-close-voice-overlay`\),\5\.app\.quit\(\);return\}\}\),\3&&\1\.on\(`close`/g)]
  if (patched.length === 1) {
    if (patched[0][5] !== electron) {
      throw new Error("Linux primary window close: Electron binding mismatch")
    }
    console.log("Linux primary window close hook: already patched")
    return
  }
  if (patched.length > 1) {
    throw new Error(`Linux primary window close: expected at most one patched match, found ${patched.length}`)
  }

  const [fullMatch, window, windowOptions, isPrimary, appearance] = requireSingle(
    [...source.matchAll(/this\.installWebContentsDiagnostics\(([A-Za-z_$][\w$]*)\),this\.registerWindow\(\1,([A-Za-z_$][\w$]*),([A-Za-z_$][\w$]*),([A-Za-z_$][\w$]*),`register`\),\3&&\1\.on\(`close`/g)],
    "Linux primary window close"
  )
  const replacement = `this.installWebContentsDiagnostics(${window}),this.registerWindow(${window},${windowOptions},${isPrimary},${appearance},\`register\`),${appearance}===\`primary\`&&${window}.prependListener(\`close\`,closeEvent=>{let otherPrimary=this.getPrimaryWindows().some(primaryWindow=>primaryWindow!==${window});if(process.platform===\`linux\`&&!this.isAppQuitting&&!otherPrimary){closeEvent.preventDefault(),${electron}.app.emit(\`linux-close-voice-overlay\`),${electron}.app.quit();return}}),${isPrimary}&&${window}.on(\`close\``
  source = source.replace(fullMatch, replacement)
  changed = true
  console.log("Linux primary window close hook: patched")
}

patchOpaqueBackground()
patchTransparentWindows()
patchVoiceOverlayClose()
patchPrimaryWindowCloseHook()

if (changed) {
  fs.writeFileSync(file, source)
  fs.writeFileSync(changedMarker, "changed\n")
}
NODE

if [[ ! -f "$CHANGED_MARKER" ]]; then
  printf 'Linux rendering already patched in %s\n' "$ASAR_PATH"
  exit 0
fi

if [[ ! -f "$BACKUP_PATH" ]]; then
  cp "$ASAR_PATH" "$BACKUP_PATH"
fi

run_asar pack "$EXTRACT_DIR" "$PACKED_ASAR"
mv -f "$PACKED_ASAR" "$ASAR_PATH"

printf 'Patched Linux rendering in %s\n' "$ASAR_PATH"
