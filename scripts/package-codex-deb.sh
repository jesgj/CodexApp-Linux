#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
ROOT_DIR=$(unset CDPATH; cd -- "$SCRIPT_DIR/.." && pwd -P)
source "$SCRIPT_DIR/resolve-resources.sh"

ASAR_VERSION="4.2.1"
PACKAGE_NAME="codex-app"
PATCH_LINUX_RENDERING="${CODEX_PATCH_LINUX_RENDERING:-1}"
RESOURCES_SRC=$(resolve_resources_dir "$ROOT_DIR")
ASAR_PATH="$RESOURCES_SRC/app.asar"
ELECTRON_DIST_SRC="$ROOT_DIR/build/electron-runtime/node_modules/electron/dist"
BUILD_ROOT="$ROOT_DIR/build/deb-package"
WORK_DIR="$BUILD_ROOT/work"
DIST_DIR="$ROOT_DIR/dist"

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

require_path() {
  if [[ ! -e "$1" ]]; then
    fail "Required path not found: $1"
  fi
}

run_asar() {
  pixi run npx --yes "@electron/asar@$ASAR_VERSION" "$@"
}

validate_deb_version() {
  if [[ ! "$1" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~\-]*$ ]]; then
    fail "Invalid Debian package version: $1"
  fi
}

verify_linux_elf() {
  local path="$1"
  local description="$2"
  local file_type

  file_type=$(file -Lb "$path")
  if [[ "$file_type" != *ELF* || "$file_type" != *"$ELF_ARCH"* ]]; then
    fail "$description is not a Linux $ARCH ELF binary: $path ($file_type)"
  fi
}

verify_linux_executable() {
  local path="$1"
  local description="$2"

  if [[ ! -x "$path" ]]; then
    fail "$description is not executable: $path"
  fi
  verify_linux_elf "$path" "$description"
}

require_path "$RESOURCES_SRC"
require_path "$ASAR_PATH"
require_path "$ELECTRON_DIST_SRC/electron"
require_path "$RESOURCES_SRC/codex"
require_path "$RESOURCES_SRC/rg"
require_path "$RESOURCES_SRC/codex-code-mode-host"
mkdir -p "$BUILD_ROOT" "$DIST_DIR"

case "$(uname -m)" in
  x86_64)
    HOST_ARCH="amd64"
    ELF_ARCH="x86-64"
    ;;
  aarch64)
    HOST_ARCH="arm64"
    ELF_ARCH="aarch64"
    ;;
  *)
    fail "Unsupported host architecture: $(uname -m)"
    ;;
esac

ARCH="${CODEX_DEB_ARCH:-$HOST_ARCH}"
if [[ "$ARCH" != "$HOST_ARCH" ]]; then
  fail "Cross-architecture packaging is not supported: host is $HOST_ARCH, requested $ARCH"
fi

METADATA_DIR=$(mktemp -d "$BUILD_ROOT/metadata.XXXXXX")
trap 'rm -rf "$METADATA_DIR"' EXIT
(
  cd "$METADATA_DIR"
  run_asar extract-file "$ASAR_PATH" package.json >/dev/null
)
require_path "$METADATA_DIR/package.json"

APP_VERSION=$(node -e 'const pkg = require(process.argv[1]); process.stdout.write(pkg.version)' "$METADATA_DIR/package.json")
APP_ELECTRON_VERSION=$(node -e 'const pkg = require(process.argv[1]); process.stdout.write(pkg.devDependencies.electron)' "$METADATA_DIR/package.json")
VERSION="${CODEX_DEB_VERSION:-$APP_VERSION}"
validate_deb_version "$VERSION"

PACKAGE_ROOT="$BUILD_ROOT/${PACKAGE_NAME}_${VERSION}_${ARCH}"
INSTALL_ROOT="$PACKAGE_ROOT/opt/codex-linux"
PACKAGE_ASAR_PATH="$INSTALL_ROOT/resources/app.asar"
DEB_PATH="$DIST_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"

RUNTIME_ELECTRON_VERSION=$("$ELECTRON_DIST_SRC/electron" --version)
if [[ "$RUNTIME_ELECTRON_VERSION" != "v$APP_ELECTRON_VERSION" ]]; then
  fail "Electron runtime $RUNTIME_ELECTRON_VERSION does not match app Electron $APP_ELECTRON_VERSION"
fi

verify_linux_executable "$ELECTRON_DIST_SRC/electron" "Electron runtime"
verify_linux_executable "$RESOURCES_SRC/codex" "Codex CLI"
verify_linux_executable "$RESOURCES_SRC/rg" "Ripgrep helper"
verify_linux_executable "$RESOURCES_SRC/codex-code-mode-host" "Code mode host"
"$RESOURCES_SRC/codex" app-server --help >/dev/null
"$RESOURCES_SRC/rg" --version >/dev/null
"$RESOURCES_SRC/codex-code-mode-host" --help >/dev/null

NATIVE_MODULES=(
  "$RESOURCES_SRC/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  "$RESOURCES_SRC/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node"
  "$RESOURCES_SRC/app.asar.unpacked/node_modules/bufferutil/build/Release/bufferutil.node"
  "$RESOURCES_SRC/app.asar.unpacked/node_modules/utf-8-validate/build/Release/validation.node"
)
for native_module in "${NATIVE_MODULES[@]}"; do
  require_path "$native_module"
  verify_linux_elf "$native_module" "Native module"
  if ldd "$native_module" | grep -q 'not found'; then
    fail "Native module has unresolved dependencies: $native_module"
  fi
done

rm -rf "$PACKAGE_ROOT" "$WORK_DIR"
mkdir -p \
  "$INSTALL_ROOT/electron" \
  "$INSTALL_ROOT/resources" \
  "$PACKAGE_ROOT/DEBIAN" \
  "$PACKAGE_ROOT/usr/bin" \
  "$PACKAGE_ROOT/usr/share/applications" \
  "$PACKAGE_ROOT/usr/share/icons/hicolor/104x104/apps" \
  "$WORK_DIR"

rsync -a --delete "$ELECTRON_DIST_SRC/" "$INSTALL_ROOT/electron/"
rsync -a --delete \
  --exclude '*.macos-arm64.backup' \
  --exclude 'native/' \
  --exclude 'cua_node/' \
  --exclude 'codex_chronicle' \
  "$RESOURCES_SRC/" "$INSTALL_ROOT/resources/"

if [[ "$PATCH_LINUX_RENDERING" != "0" ]]; then
  CODEX_RESOURCES_DIR="$INSTALL_ROOT/resources" "$SCRIPT_DIR/patch-linux-rendering.sh"
fi

if [[ -e "$INSTALL_ROOT/resources/cua_node" || -e "$INSTALL_ROOT/resources/codex_chronicle" ]]; then
  fail "Unsupported macOS-only resources were included in the Debian package"
fi

chmod -R u=rwX,go=rX "$INSTALL_ROOT"
if [[ -f "$INSTALL_ROOT/electron/chrome-sandbox" ]]; then
  chmod 4755 "$INSTALL_ROOT/electron/chrome-sandbox"
fi

cat > "$PACKAGE_ROOT/usr/bin/codex-app" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/codex-linux"
RESOURCES_DIR="$APP_DIR/resources"
ASAR_PATH="$RESOURCES_DIR/app.asar"

export CODEX_CLI_PATH="$RESOURCES_DIR/codex"
export ELECTRON_RENDERER_URL="file://$ASAR_PATH/webview/index.html"

exec "$APP_DIR/electron/electron" "$ASAR_PATH" --disable-gpu-compositing "$@"
LAUNCHER
chmod 0755 "$PACKAGE_ROOT/usr/bin/codex-app"

mapfile -t ICON_PATHS < <(
  run_asar list "$PACKAGE_ASAR_PATH" | while IFS= read -r path; do
    if [[ "$path" =~ ^/webview/assets/codex-app-ga-logo--.+\.png$ ]]; then
      printf '%s\n' "$path"
    fi
  done
)
if [[ "${#ICON_PATHS[@]}" -eq 1 ]]; then
  ICON_ASAR_PATH="${ICON_PATHS[0]#/}"
  (
    cd "$WORK_DIR"
    run_asar extract-file "$PACKAGE_ASAR_PATH" "$ICON_ASAR_PATH" >/dev/null
  )
  ICON_SOURCE="$WORK_DIR/$(basename "$ICON_ASAR_PATH")"
elif [[ "${#ICON_PATHS[@]}" -eq 0 && -f "$INSTALL_ROOT/resources/icon-chatgpt.png" ]]; then
  ICON_SOURCE="$INSTALL_ROOT/resources/icon-chatgpt.png"
else
  fail "Expected exactly one Codex icon asset, found ${#ICON_PATHS[@]}"
fi
install -m 0644 "$ICON_SOURCE" "$PACKAGE_ROOT/usr/share/icons/hicolor/104x104/apps/codex.png"

cat > "$PACKAGE_ROOT/usr/share/applications/codex.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Codex
Comment=OpenAI Codex desktop app
Exec=codex-app %U
Icon=codex
Terminal=false
Type=Application
Categories=Development;
StartupNotify=true
DESKTOP

INSTALLED_SIZE=$(du -sk "$PACKAGE_ROOT" | cut -f1)
cat > "$PACKAGE_ROOT/DEBIAN/control" <<CONTROL
Package: $PACKAGE_NAME
Version: $VERSION
Section: devel
Priority: optional
Architecture: $ARCH
Installed-Size: $INSTALLED_SIZE
Maintainer: Local Build <local@example.invalid>
Depends: libc6, libgtk-3-0, libnss3, libxss1, libasound2, libatk-bridge2.0-0, libdrm2, libgbm1, libx11-xcb1, libxcb-dri3-0, libxcomposite1, libxdamage1, libxrandr2, libcups2, libxkbcommon0, libpango-1.0-0, libcairo2
Description: OpenAI Codex desktop app for Linux
 Local Linux $ARCH package assembled from the converted Codex Electron app.
CONTROL

cat > "$PACKAGE_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/usr/bin/env bash
set -euo pipefail

if [[ -d /opt/codex-linux ]]; then
  chmod -R u=rwX,go=rX /opt/codex-linux
fi

if [[ -f /opt/codex-linux/electron/chrome-sandbox ]]; then
  chown root:root /opt/codex-linux/electron/chrome-sandbox
  chmod 4755 /opt/codex-linux/electron/chrome-sandbox
fi

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
POSTINST

cat > "$PACKAGE_ROOT/DEBIAN/postrm" <<'POSTRM'
#!/usr/bin/env bash
set -euo pipefail

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
POSTRM

chmod 0755 "$PACKAGE_ROOT/DEBIAN/postinst" "$PACKAGE_ROOT/DEBIAN/postrm"

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$PACKAGE_ROOT/usr/share/applications/codex.desktop"
fi
dpkg-deb --build --root-owner-group "$PACKAGE_ROOT" "$DEB_PATH"

printf 'Created %s\n' "$DEB_PATH"
