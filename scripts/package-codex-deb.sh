#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd -P)
ROOT_DIR=$(unset CDPATH; cd -- "$SCRIPT_DIR/.." && pwd -P)

PACKAGE_NAME="codex-app"
VERSION="${CODEX_DEB_VERSION:-26.513.31313}"
ARCH="${CODEX_DEB_ARCH:-amd64}"

RESOURCES_SRC="$ROOT_DIR/build/app/Codex Installer/Codex.app/Contents/Resources"
ELECTRON_DIST_SRC="$ROOT_DIR/build/electron-runtime/node_modules/electron/dist"
ASAR_PATH="$RESOURCES_SRC/app.asar"

BUILD_ROOT="$ROOT_DIR/build/deb-package"
WORK_DIR="$BUILD_ROOT/work"
PACKAGE_ROOT="$BUILD_ROOT/${PACKAGE_NAME}_${VERSION}_${ARCH}"
INSTALL_ROOT="$PACKAGE_ROOT/opt/codex-linux"
DIST_DIR="$ROOT_DIR/dist"
DEB_PATH="$DIST_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"

require_path() {
  if [[ ! -e "$1" ]]; then
    printf 'Required path not found: %s\n' "$1" >&2
    exit 1
  fi
}

require_path "$RESOURCES_SRC"
require_path "$ELECTRON_DIST_SRC/electron"
require_path "$ASAR_PATH"
require_path "$RESOURCES_SRC/codex"

rm -rf "$PACKAGE_ROOT" "$WORK_DIR"
mkdir -p \
  "$INSTALL_ROOT/electron" \
  "$INSTALL_ROOT/resources" \
  "$PACKAGE_ROOT/DEBIAN" \
  "$PACKAGE_ROOT/usr/bin" \
  "$PACKAGE_ROOT/usr/share/applications" \
  "$PACKAGE_ROOT/usr/share/icons/hicolor/104x104/apps" \
  "$DIST_DIR" \
  "$WORK_DIR"

rsync -a --delete "$ELECTRON_DIST_SRC/" "$INSTALL_ROOT/electron/"
rsync -a --delete \
  --exclude 'codex.macos-arm64.backup' \
  --exclude 'native' \
  "$RESOURCES_SRC/" "$INSTALL_ROOT/resources/"

chmod -R u+rwX,go+rX "$INSTALL_ROOT"

cat > "$PACKAGE_ROOT/usr/bin/codex-app" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/codex-linux"
RESOURCES_DIR="$APP_DIR/resources"
ASAR_PATH="$RESOURCES_DIR/app.asar"

export CODEX_CLI_PATH="$RESOURCES_DIR/codex"
export ELECTRON_RENDERER_URL="file://$ASAR_PATH/webview/index.html"

exec "$APP_DIR/electron/electron" "$ASAR_PATH" "$@"
LAUNCHER
chmod 0755 "$PACKAGE_ROOT/usr/bin/codex-app"

(
  cd "$WORK_DIR"
  npx --yes asar extract-file "$ASAR_PATH" webview/assets/codex-app-ga-logo--UgmJjKM.png >/dev/null
)
install -m 0644 \
  "$WORK_DIR/codex-app-ga-logo--UgmJjKM.png" \
  "$PACKAGE_ROOT/usr/share/icons/hicolor/104x104/apps/codex.png"

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
 Local Linux x86_64 package assembled from the converted Codex Electron app.
CONTROL

cat > "$PACKAGE_ROOT/DEBIAN/postinst" <<'POSTINST'
#!/usr/bin/env bash
set -euo pipefail

if [[ -f /opt/codex-linux/electron/chrome-sandbox ]]; then
  chown root:root /opt/codex-linux/electron/chrome-sandbox || true
  chmod 4755 /opt/codex-linux/electron/chrome-sandbox || true
fi

if [[ -d /opt/codex-linux ]]; then
  chmod -R u+rwX,go+rX /opt/codex-linux || true
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

desktop-file-validate "$PACKAGE_ROOT/usr/share/applications/codex.desktop"
dpkg-deb --build --root-owner-group "$PACKAGE_ROOT" "$DEB_PATH"

printf 'Created %s\n' "$DEB_PATH"
