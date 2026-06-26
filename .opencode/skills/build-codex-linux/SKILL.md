---
name: build-codex-linux
description: Use when converting the macOS Codex.dmg Electron app into a local runnable Linux build, especially on Pop!_OS/Ubuntu/Fedora x86_64 or ARM64, with pixi-managed extraction, Electron runtime setup, native module rebuilds, and app-server verification.
---

# Build Codex Linux

Use this skill when the user wants to run the macOS `Codex.dmg` desktop app on Linux, create a local Linux launcher, debug a converted Codex Electron bundle, or repeat the community Linux port process for a new Codex DMG.

This skill is for a local, unofficial conversion workflow. It does not produce an upstream-quality signed release. Prefer the smallest working local build first, then package as `.deb`, `.rpm`, or Flatpak only after the converted app launches and the app-server handshake succeeds.

## Goals

- Extract the macOS `Codex.dmg` without system installs when possible.
- Convert bundled macOS binaries to Linux binaries for the host architecture.
- Rebuild native Node modules for the bundled Electron version.
- Launch the app through a local Linux Electron runtime.
- Verify the renderer, native modules, and Codex app-server backend all work.

## Trigger Phrases

Use this skill for requests like:

- `build Codex Linux`
- `run Codex.dmg on Linux`
- `convert Codex.dmg for Pop OS`
- `make a Linux launcher for Codex`
- `rebuild Codex native modules`
- `Codex app-server failed on Linux`
- `unexpected argument app-server found`
- `ELECTRON_RENDERER_URL Codex`
- `package Codex as Flatpak/deb/rpm`

## Important Constraints

- Do not commit large artifacts unless the user explicitly asks.
- Ignore or keep local-only artifacts such as `Codex.dmg`, `build/`, `.pixi/`, and Electron/npm downloads out of git.
- Prefer `pixi` for build tools if the user asks to avoid system package installs.
- Do not use the standalone `codex-app-server-*` binary as `Resources/codex` for newer desktop app builds that execute `codex app-server`. Use the full `codex-*` CLI binary instead.
- Match the Electron rebuild version to the app bundle’s `package.json`, not to older notes online.

## Architecture Mapping

Detect the host architecture first:

```bash
uname -m
```

Use this mapping:

| Host `uname -m` | Electron arch | Codex release target |
| --- | --- | --- |
| `x86_64` | `x64` | `x86_64-unknown-linux-musl` |
| `aarch64` | `arm64` | `aarch64-unknown-linux-musl` |

Prefer `unknown-linux-musl` Codex releases because they are static PIE binaries and work broadly across Linux distributions.

## Workspace Layout

Recommended local layout:

```text
CodexApp/
  Codex.dmg
  pixi.toml
  pixi.lock
  scripts/run-codex-linux.sh
  build/
    extract/
    app/
    native-rebuild/
    electron-runtime/
    dmg2img-src/
```

Keep `build/`, `.pixi/`, and `Codex.dmg` ignored by git.

Example `.gitignore`:

```gitignore
/.pixi/
/build/
/Codex.dmg
/dist/
```

## Pixi Tooling

Create or update `pixi.toml` with build and extraction tools:

```toml
[workspace]
channels = ["conda-forge"]
name = "codex-linux-local"
platforms = ["linux-64"]
version = "0.1.0"

[dependencies]
bzip2 = "*"
cmake = "*"
cxx-compiler = "*"
git = "*"
libfuse = "*"
make = "*"
nodejs = "*"
openssl = "*"
p7zip = "*"
pkg-config = "*"
python = "*"
zlib = "*"
zstd = "*"
```

Install tools:

```bash
pixi install
```

## Extracting The DMG

Try `7z` first:

```bash
mkdir -p build/extract build/app
pixi run 7z x -y -obuild/extract Codex.dmg
```

If `7z` fails with `Can not open the file as [Dmg] archive`, inspect the DMG:

```bash
file Codex.dmg
xxd -l 64 Codex.dmg
```

If the file starts with zlib data and has a trailing `koly` UDIF trailer, build `dmg2img` locally:

```bash
git clone --depth 1 https://github.com/Lekensteyn/dmg2img.git build/dmg2img-src
pixi run make CFLAGS="-g -O2 -Wall -I$PWD/.pixi/envs/default/include" LDFLAGS="-L$PWD/.pixi/envs/default/lib" -C build/dmg2img-src
build/dmg2img-src/dmg2img Codex.dmg build/extract/Codex.img
```

List the converted image:

```bash
pixi run 7z l build/extract/Codex.img
```

Extract app resources only:

```bash
pixi run 7z x -y -obuild/app build/extract/Codex.img "Codex Installer/Codex.app/Contents/Resources/*"
```

If `7z l build/extract/Codex.img` only shows `disk image.img`, the DMG contains an APFS volume. Build `apfs-fuse` locally with pixi-managed tools and mount the APFS partition:

```bash
pixi run git clone --depth 1 https://github.com/sgan81/apfs-fuse.git build/apfs-fuse-src
pixi run git -C build/apfs-fuse-src submodule update --init --recursive

pixi run cmake -S build/apfs-fuse-src -B build/apfs-fuse-build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
pixi run cmake --build build/apfs-fuse-build --parallel

build/apfs-fuse-build/apfsutil build/extract/Codex.img
mkdir -p build/apfs-mount
build/apfs-fuse-build/apfs-fuse -p 0 -v 0 \
  -o uid=$(id -u),gid=$(id -g) \
  build/extract/Codex.img build/apfs-mount

mkdir -p "build/app/Codex Installer/Codex.app/Contents"
rsync -a --delete \
  "build/apfs-mount/root/Codex.app/Contents/Resources/" \
  "build/app/Codex Installer/Codex.app/Contents/Resources/"

fusermount3 -u build/apfs-mount
```

Expected resources path:

```text
build/app/Codex Installer/Codex.app/Contents/Resources
```

Expected important files:

```text
app.asar
app.asar.unpacked/
codex
node
rg
plugins/
native/
```

The extracted macOS binaries will usually be Mach-O ARM64 or x86_64 and must not be used directly on Linux.

## Determine App And Electron Version

Extract `package.json` from `app.asar`:

```bash
pixi run npx --yes @electron/asar extract-file "build/app/Codex Installer/Codex.app/Contents/Resources/app.asar" package.json
```

Read the extracted `package.json` and note:

- `version`
- `devDependencies.electron`
- `dependencies.better-sqlite3`
- `dependencies.node-pty`

Use the app’s Electron version for all rebuilds. For example, if `package.json` says `electron: 41.2.0`, rebuild native modules for Electron `41.2.0`, not `40.0.0` from older reports.

After reading it, remove the accidentally extracted root `package.json` if it is not meant to be committed.

## Replace The Codex Backend

Identify the bundled backend:

```bash
file "build/app/Codex Installer/Codex.app/Contents/Resources/codex"
```

If it is Mach-O, replace it.

For newer desktop app builds, use the full Linux CLI archive, not the standalone app-server archive:

```bash
curl -L --fail -o build/extract/codex-x86_64-unknown-linux-musl.tar.gz \
  https://github.com/openai/codex/releases/download/rust-v0.130.0/codex-x86_64-unknown-linux-musl.tar.gz

mkdir -p build/extract/codex-linux
tar -xzf build/extract/codex-x86_64-unknown-linux-musl.tar.gz -C build/extract/codex-linux

cp "build/app/Codex Installer/Codex.app/Contents/Resources/codex" \
  "build/app/Codex Installer/Codex.app/Contents/Resources/codex.macos.backup"

cp build/extract/codex-linux/codex-x86_64-unknown-linux-musl \
  "build/app/Codex Installer/Codex.app/Contents/Resources/codex"

chmod +x "build/app/Codex Installer/Codex.app/Contents/Resources/codex"
```

For ARM64 Linux, substitute `aarch64-unknown-linux-musl`.

Verify the app-server subcommand exists:

```bash
"build/app/Codex Installer/Codex.app/Contents/Resources/codex" app-server --help
```

If the smoke test later reports `unexpected argument 'app-server' found`, the wrong binary was installed. Replace `Resources/codex` with the full `codex-*` CLI release, not `codex-app-server-*`.

## Remove macOS-Only Native Binaries

The extracted bundle includes a `Resources/native/` directory with macOS ARM64 binaries that are never used on Linux:

```text
Resources/native/
  bare-modifier-monitor          Mach-O arm64 executable
  browser-use-peer-authorization.node   Mach-O arm64 bundle
  devicecheck.node               Mach-O arm64 bundle
  launch-services-helper         Mach-O arm64 executable
  remote-control-device-key.node Mach-O arm64 bundle
  sky.node                       Mach-O arm64 bundle
  sparkle.node                   Mach-O arm64 bundle
```

Remove them to save space and avoid confusion:

```bash
rm -rf "build/app/Codex Installer/Codex.app/Contents/Resources/native"
```

Verify removal:

```bash
ls "build/app/Codex Installer/Codex.app/Contents/Resources/native" 2>&1
# Expected: ls: cannot access '.../native': No such file or directory
```

## Rebuild Native Modules

The packaged `app.asar.unpacked/node_modules` often contains compiled `.node` files but lacks enough source files for direct `node-gyp` rebuilds. The robust path is to create a clean temporary npm workspace with the exact package versions from `package.json`.

Example for Electron `41.2.0`, `better-sqlite3@12.8.0`, and `node-pty@1.1.0`:

```bash
mkdir -p build/native-rebuild
```

Create `build/native-rebuild/package.json`:

```json
{
  "private": true,
  "dependencies": {
    "@electron/rebuild": "latest",
    "better-sqlite3": "12.8.0",
    "node-pty": "1.1.0"
  }
}
```

Install sources without running package install scripts:

```bash
pixi run npm install --ignore-scripts
```

Rebuild:

```bash
pixi run npx electron-rebuild --version 41.2.0 --arch x64 --only better-sqlite3,node-pty
```

For ARM64 Linux use `--arch arm64`.

For Electron `42.0.1`, `better-sqlite3@12.9.0`/`12.10.0` may fail to compile against the newer V8 external pointer API. Apply this minimal rebuild-workspace patch before rerunning `electron-rebuild`:

```diff
--- a/node_modules/better-sqlite3/src/util/macros.cpp
+++ b/node_modules/better-sqlite3/src/util/macros.cpp
@@
-#define OnlyAddon static_cast<Addon*>(info.Data().As<v8::External>()->Value())
+#define OnlyAddon static_cast<Addon*>(info.Data().As<v8::External>()->Value(v8::kExternalPointerTypeTagDefault))
--- a/node_modules/better-sqlite3/src/better_sqlite3.cpp
+++ b/node_modules/better-sqlite3/src/better_sqlite3.cpp
@@
-	v8::Local<v8::External> data = v8::External::New(isolate, addon);
+	v8::Local<v8::External> data = v8::External::New(isolate, addon, v8::kExternalPointerTypeTagDefault);
--- a/node_modules/better-sqlite3/src/util/helpers.cpp
+++ b/node_modules/better-sqlite3/src/util/helpers.cpp
@@
-		func,
-		0,
+		func,
+		nullptr,
```

If the exact bundled `better-sqlite3` version still fails, try the latest compatible patch release in the same major line and copy only the rebuilt `.node` binary back into the app.

Copy rebuilt binaries into the app:

```bash
cp build/native-rebuild/node_modules/better-sqlite3/build/Release/better_sqlite3.node \
  "build/app/Codex Installer/Codex.app/Contents/Resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node"

cp build/native-rebuild/node_modules/node-pty/build/Release/pty.node \
  "build/app/Codex Installer/Codex.app/Contents/Resources/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node"
```

Verify:

```bash
file "build/app/Codex Installer/Codex.app/Contents/Resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
file "build/app/Codex Installer/Codex.app/Contents/Resources/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node"
ldd "build/app/Codex Installer/Codex.app/Contents/Resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
ldd "build/app/Codex Installer/Codex.app/Contents/Resources/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node"
```

Expected result: ELF x86-64 or aarch64 shared objects, not Mach-O bundles.

## Install Local Electron Runtime

Install the exact Electron runtime version from the app’s `package.json`:

```bash
mkdir -p build/electron-runtime
```

Create `build/electron-runtime/package.json`:

```json
{
  "private": true,
  "dependencies": {
    "electron": "41.2.0"
  }
}
```

Install:

```bash
pixi run npm install
```

If `node_modules/electron/dist/electron` is missing after install, an environment setting may have skipped Electron's binary download. Run:

```bash
env -u ELECTRON_SKIP_BINARY_DOWNLOAD pixi run node node_modules/electron/install.js
```

Verify:

```bash
build/electron-runtime/node_modules/electron/dist/electron --version
```

## Launcher Script

Create `scripts/run-codex-linux.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
RESOURCES_DIR="$ROOT_DIR/build/app/Codex Installer/Codex.app/Contents/Resources"
ASAR_PATH="$RESOURCES_DIR/app.asar"
ELECTRON_BIN="$ROOT_DIR/build/electron-runtime/node_modules/electron/dist/electron"

export CODEX_CLI_PATH="$RESOURCES_DIR/codex"
export ELECTRON_RENDERER_URL="file://$ASAR_PATH/webview/index.html"

exec "$ELECTRON_BIN" "$ASAR_PATH" --disable-gpu-compositing "$@"
```

Make it executable:

```bash
chmod +x scripts/run-codex-linux.sh
```

`ELECTRON_RENDERER_URL` matters because running `electron app.asar` directly can leave `app.isPackaged === false`, making the app try to load a Vite dev server. Point it at the renderer inside the ASAR.

`CODEX_CLI_PATH` matters because the app-server launcher can discover or prefer the wrong `codex` binary if the environment or resources path is not what the macOS bundle expected.

## Linux Rendering Patch

On X11 sessions without a compositor, transparent Electron windows can render the converted app blurry. Patch the ASAR before local smoke testing or packaging:

```bash
scripts/patch-linux-rendering.sh
```

The patch makes Linux use opaque window backgrounds in the minified main process bundle and disables transparent sub-windows on Linux. The Debian package script applies this patch by default; set `CODEX_PATCH_LINUX_RENDERING=0` only when intentionally testing the unpatched upstream window behavior.

## Smoke Test

Run a short launch test:

```bash
timeout 12s scripts/run-codex-linux.sh
```

Successful signs:

- `Launching app ... platform=linux`
- `window ready-to-show`
- `window main frame finished load`
- `Current reported app-server version: currentVersion=...`
- `initialize_handshake_result ... outcome=success`
- `Codex CLI initialized`
- `app_server_connection.state_changed ... next=connected`
- Renderer log such as `app routes mounted`

Non-fatal warnings may appear:

- `VAAPI version is too old`
- `url.parse() DeprecationWarning`
- unsupported experimental feature warnings if the desktop frontend is newer than the CLI protocol

Failure signs and fixes:

| Error | Likely Cause | Fix |
| --- | --- | --- |
| `Can not open the file as [Dmg] archive` | Old p7zip cannot parse this UDIF DMG | Build/use `dmg2img`, then run `7z` on the raw image |
| `gyp: deps/common.gypi not found` | Packaged module folder lacks source files | Rebuild in clean `build/native-rebuild` npm workspace |
| `unexpected argument 'app-server' found` | Installed standalone `codex-app-server` as `Resources/codex` | Install full `codex-*` CLI binary |
| Blank window / Vite dev server error | `app.isPackaged` false when running ASAR directly | Set `ELECTRON_RENDERER_URL=file://.../app.asar/webview/index.html` |
| Native module load error | `.node` binary still Mach-O or wrong ABI | Rebuild with matching Electron version and host arch |

## Optional Runtime Dependencies

Newer Codex desktop builds may auto-install a primary runtime bundle into `~/.cache/codex-runtimes`. This is normal if logs show `primary_runtime_install_started`. Let it complete unless the user specifically wants a fully offline package.

The extracted bundle may include macOS `node`, `rg`, and other helpers. Do not replace them preemptively unless logs show the Linux app actually executes them. The Codex app-server and primary runtime may provide Linux equivalents at runtime.

## Debian Package After Local Success

Only build a `.deb` after `scripts/run-codex-linux.sh` works and the app-server handshake succeeds. Use a package name and installed command that do not conflict with the official Codex CLI. The recommended local package name is `codex-app`, with the installed launcher at `/usr/bin/codex-app`.

Recommended install layout:

```text
/opt/codex-linux/
  electron/
  resources/
    app.asar
    app.asar.unpacked/
    codex
    plugins/
/usr/bin/codex-app
/usr/share/applications/codex.desktop
/usr/share/icons/hicolor/104x104/apps/codex.png
```

The installed launcher must preserve the same environment used by the local launcher:

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/codex-linux"
RESOURCES_DIR="$APP_DIR/resources"
ASAR_PATH="$RESOURCES_DIR/app.asar"

export CODEX_CLI_PATH="$RESOURCES_DIR/codex"
export ELECTRON_RENDERER_URL="file://$ASAR_PATH/webview/index.html"

exec "$APP_DIR/electron/electron" "$ASAR_PATH" --disable-gpu-compositing "$@"
```

The desktop entry should call `codex-app`, not `codex`:

```ini
[Desktop Entry]
Name=Codex
Comment=OpenAI Codex desktop app
Exec=codex-app %U
Icon=codex
Terminal=false
Type=Application
Categories=Development;
StartupNotify=true
```

Normalize permissions before building the package, especially because extracted macOS bundle directories may retain restrictive modes such as `0700`. If `/opt/codex-linux/resources` is installed as unreadable by normal users, Electron will report `Unable to find Electron app at /opt/codex-linux/resources/app.asar` even when the file exists.

Apply this in the package staging tree before `dpkg-deb --build`:

```bash
chmod -R u+rwX,go+rX "$INSTALL_ROOT"
```

Also include the same permission normalization in `DEBIAN/postinst`, so upgrades or reinstalls over a previously broken package fix existing install-tree permissions:

```bash
if [[ -d /opt/codex-linux ]]; then
  chmod -R u+rwX,go+rX /opt/codex-linux || true
fi
```

If Electron uses `chrome-sandbox`, fix its setuid bit in `postinst`:

```bash
if [[ -f /opt/codex-linux/electron/chrome-sandbox ]]; then
  chown root:root /opt/codex-linux/electron/chrome-sandbox || true
  chmod 4755 /opt/codex-linux/electron/chrome-sandbox || true
fi
```

Build with:

```bash
dpkg-deb --build --root-owner-group "$PACKAGE_ROOT" "$DEB_PATH"
```

For the working Pop!_OS/Ubuntu x86_64 package, the result was:

```text
dist/codex-app_<app-version>_amd64.deb
```

Install or reinstall with:

```bash
sudo apt install ./dist/codex-app_<app-version>_amd64.deb
sudo apt install --reinstall ./dist/codex-app_<app-version>_amd64.deb
```

The `_apt` sandbox warning for a local file inside the project directory is usually harmless:

```text
N: La descarga está siendo realizada en un sandbox como superusuario ... no es accesible por el usuario _apt
```

Verify after install:

```bash
stat -c '%A %U:%G %n' /opt/codex-linux/resources /opt/codex-linux/resources/app.asar /usr/bin/codex-app
codex-app
```

Expected installed permissions include:

```text
drwxr-xr-x root:root /opt/codex-linux/resources
-rw-r--r-- or -rw-rw-r-- root:root /opt/codex-linux/resources/app.asar
-rwxr-xr-x root:root /usr/bin/codex-app
```

Keep user login/session data out of the package. The `.deb` should include only app binaries/resources; users will be prompted to sign in with their own account at runtime.

For `.rpm`, use the same layout and launcher semantics, with equivalent `%post` permission and `chrome-sandbox` handling.

For Flatpak:

- Include the Linux Electron runtime and converted resources.
- Ensure sandbox permissions include network access, home/workspace file access as appropriate, and PTY support.
- Validate `node-pty` inside the sandbox.
- Consider bundling or preinstalling Codex primary runtime dependencies if offline behavior matters.

## Final Verification Checklist

Before reporting success, verify:

- `file Resources/codex` reports Linux ELF for the host arch.
- `Resources/codex app-server --help` works.
- `file better_sqlite3.node` reports Linux ELF shared object.
- `file pty.node` reports Linux ELF shared object.
- `electron --version` matches the app bundle’s Electron version.
- `scripts/patch-linux-rendering.sh` was applied, unless intentionally skipped.
- `timeout 12s scripts/run-codex-linux.sh` reaches `outcome=success` for app-server initialization.
- If building `.deb`, `dpkg-deb --contents dist/codex-app_*.deb` shows `/usr/bin/codex-app`, `/opt/codex-linux/resources/app.asar`, and readable `/opt/codex-linux/resources/` permissions.
- If installing `.deb`, `codex-app` launches and does not fail with `Unable to find Electron app at /opt/codex-linux/resources/app.asar`.
- `.gitignore` excludes large local artifacts.
- `git status --short` only shows intended small source/config files.

## Successful Reference Result

On Pop!_OS 22.04 x86_64, a successful local conversion used:

- `pixi 0.50.2`
- Electron `41.2.0`
- Codex app package version `26.506.31421`
- Codex CLI release `rust-v0.130.0`
- Full backend target `codex-x86_64-unknown-linux-musl`
- Native modules rebuilt for Electron `41.2.0` and arch `x64`

For Codex app package version `26.513.31313`, the new DMG used an APFS volume. A successful Pop!_OS 22.04 x86_64 conversion used Electron `42.0.1`, Codex CLI release `rust-v0.131.0`, `better-sqlite3` rebuilt with the V8 external-pointer patch, and produced `dist/codex-app_26.513.31313_amd64.deb`.

For Codex app package version `26.608.12217`, a successful Pop!_OS 22.04 x86_64 conversion used Electron `42.1.0`, Codex CLI release `rust-v0.139.0`, `better-sqlite3` and `node-pty` rebuilt for Linux, and produced `dist/codex-app_26.608.12217_amd64.deb`. The Linux rendering patch was required to avoid blurry transparent-window rendering on X11 without a compositor.

The successful smoke test showed:

```text
[AppServerConnection] Current reported app-server version: currentVersion=0.130.0 hostId=local
[AppServerConnection] initialize_handshake_result durationMs=1257 initializeRequestId=__codex_initialize__ outcome=success transportKind=stdio
[AppServerConnection] Codex CLI initialized
[AppServerConnection] app_server_connection.state_changed ... next=connected ... transport=stdio
[electron-message-handler] [startup][renderer] app routes mounted
```

## User-Facing Completion Note

When finishing, tell the user:

- The launcher command, usually `scripts/run-codex-linux.sh`.
- Which Electron version and Codex binary target were used.
- Whether the app-server handshake succeeded.
- Any warnings that remain and whether they are fatal.
- That opencode must be restarted before this new skill is available in future sessions.
