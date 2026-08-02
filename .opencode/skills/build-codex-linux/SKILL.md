---
name: build-codex-linux
description: Use when converting the macOS ChatGPT.dmg or legacy Codex.dmg Electron app into a runnable Linux build or Debian package, including DMG extraction, Linux Codex CLI replacement, Electron native module rebuilds, rendering fixes, and app-server verification.
---

# Build ChatGPT/Codex For Linux

Use this skill to build, run, debug, or package the converted OpenAI desktop app in this repository. The current verified path is the rebranded `ChatGPT.dmg` release. Keep legacy `Codex.dmg` guidance only as a fallback for older releases.

This is an unofficial local conversion without the upstream desktop source. Build the smallest working local version first. Package it only after the renderer and Codex app-server handshake succeed.

## Current Verified Build

Use these values unless inspection of a newer DMG proves they changed:

| Component | Current value |
| --- | --- |
| Input | `ChatGPT.dmg` |
| Bundle | `ChatGPT Installer/ChatGPT.app` |
| App version | `26.721.41059` |
| Electron | `42.3.0` |
| Codex CLI | `rust-v0.146.0-alpha.3.1` |
| Linux target | `codex-x86_64-unknown-linux-musl` |
| `better-sqlite3` | `12.9.0` |
| `node-pty` | `1.1.0` |
| `bufferutil` | `4.0.1` |
| `utf-8-validate` | `6.0.0` |
| Linux helper archive | `codex-package-x86_64-unknown-linux-musl` |
| Debian output | `dist/codex-app_26.721.41059_amd64.deb` |

Current resource root:

```text
build/app/ChatGPT Installer/ChatGPT.app/Contents/Resources
```

The current DMG contains an HFS+ volume. Older Codex releases may use APFS and the legacy path:

```text
build/app/Codex Installer/Codex.app/Contents/Resources
```

## Rules

- Inspect versions and paths from the input bundle before downloading or rebuilding anything.
- Use the full Linux `codex-*` CLI. Never install the standalone `codex-app-server-*` binary as `Resources/codex` because the desktop app executes `codex app-server`.
- Match native rebuilds and the local runtime to the exact Electron version in the ASAR package metadata.
- Keep the official `codex` CLI command separate from the desktop launcher. The package command is `codex-app`.
- Do not modify `~/.codex/config.toml` as part of building or launching the app.
- Do not package login data, tokens, user configuration, caches, or sessions.
- Replace `rg`, `codex-code-mode-host`, and `codex-resources/bwrap` with matching Linux ELF artifacts before packaging.
- Do not package the current DMG's macOS-only `cua_node/` or `codex_chronicle`; the unavailable Linux `node_repl` means Browser Use IAB is unsupported.
- Keep `ChatGPT.dmg`, `Codex.dmg`, `.pixi/`, `build/`, and `dist/` out of git.
- Do not commit large generated artifacts unless explicitly requested.
- Preserve unrelated worktree changes.

## Architecture

Detect the host:

```bash
uname -m
```

| Host | Electron arch | Codex release target | Debian arch |
| --- | --- | --- | --- |
| `x86_64` | `x64` | `x86_64-unknown-linux-musl` | `amd64` |
| `aarch64` | `arm64` | `aarch64-unknown-linux-musl` | `arm64` |

Prefer static `unknown-linux-musl` Codex releases for broad Linux compatibility.

## Repository Layout

```text
ChatGPT.dmg
pixi.toml
pixi.lock
scripts/
  resolve-resources.sh
  run-codex-linux.sh
  patch-linux-rendering.sh
  package-codex-deb.sh
build/
  extract/
  app/
  native-rebuild/
  electron-runtime/
  linux-rendering-patch/
dist/
```

Install the pixi environment first:

```bash
pixi install
```

The existing `pixi.toml` provides the extraction and native build toolchain. Avoid system package installation unless the user requests it.

## 1. Inspect And Extract The DMG

Confirm the input and host architecture:

```bash
file ChatGPT.dmg
uname -m
mkdir -p build/extract build/app
```

Try listing or extracting with pixi's `7z` first:

```bash
pixi run 7z l ChatGPT.dmg
pixi run 7z x -y -obuild/extract ChatGPT.dmg
```

If `7z` cannot open the UDIF image, build `dmg2img` locally and convert it:

```bash
pixi run git clone --depth 1 https://github.com/Lekensteyn/dmg2img.git build/dmg2img-src
pixi run make CFLAGS="-g -O2 -Wall -I$PWD/.pixi/envs/default/include" \
  LDFLAGS="-L$PWD/.pixi/envs/default/lib" -C build/dmg2img-src
build/dmg2img-src/dmg2img ChatGPT.dmg build/extract/ChatGPT.img
pixi run 7z l build/extract/ChatGPT.img
```

Extract the current HFS+ app bundle into `build/app`. Preserve the bundle directory names and verify this path exists afterward:

```text
build/app/ChatGPT Installer/ChatGPT.app/Contents/Resources/app.asar
```

If the converted image exposes only an inner partition image, list that image with `7z` and extract the app from it. Do not guess archive paths; use the names shown by `7z l`.

### Legacy APFS Fallback

Use this only when image inspection confirms APFS:

```bash
pixi run git clone --depth 1 https://github.com/sgan81/apfs-fuse.git build/apfs-fuse-src
pixi run git -C build/apfs-fuse-src submodule update --init --recursive
pixi run cmake -S build/apfs-fuse-src -B build/apfs-fuse-build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5
pixi run cmake --build build/apfs-fuse-build --parallel
```

Inspect partitions with `apfsutil`, mount the correct volume with `apfs-fuse`, copy `Contents/Resources/` with `rsync -a`, then unmount it with `fusermount3 -u`. Do not assume the partition and volume indexes from an older DMG.

## 2. Inspect App Versions

Set the current resource path for shell commands:

```bash
RESOURCES="build/app/ChatGPT Installer/ChatGPT.app/Contents/Resources"
```

Extract the ASAR metadata:

```bash
pixi run npx --yes @electron/asar extract-file "$RESOURCES/app.asar" package.json
```

Record:

- app `version`
- `devDependencies.electron`
- `dependencies.better-sqlite3`
- `dependencies.node-pty`
- `dependencies.bufferutil`
- `dependencies.utf-8-validate`

Remove the extracted root `package.json` after reading it if it is not part of the repository.

Also inspect native inputs before replacing them:

```bash
file "$RESOURCES/codex"
file "$RESOURCES/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
file "$RESOURCES/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node"
```

The macOS files in the current release are ARM64 Mach-O binaries even on an x86_64 Linux host.

## 3. Replace The Codex Backend

For the current x86_64 build:

```bash
curl -L --fail -o build/extract/codex-x86_64-unknown-linux-musl.tar.gz \
  https://github.com/openai/codex/releases/download/rust-v0.146.0-alpha.3.1/codex-x86_64-unknown-linux-musl.tar.gz
mkdir -p build/extract/codex-linux
tar -xzf build/extract/codex-x86_64-unknown-linux-musl.tar.gz \
  -C build/extract/codex-linux
cp "$RESOURCES/codex" "$RESOURCES/codex.macos-arm64.backup"
cp build/extract/codex-linux/codex-x86_64-unknown-linux-musl "$RESOURCES/codex"
chmod +x "$RESOURCES/codex"
```

For ARM64 Linux, use the `aarch64-unknown-linux-musl` archive and binary.

Verify immediately:

```bash
file "$RESOURCES/codex"
"$RESOURCES/codex" --version
"$RESOURCES/codex" app-server --help
```

If `app-server` is reported as an unexpected argument, the wrong release artifact was installed.

### Replace Linux Platform Helpers

The same release provides Linux replacements for helpers that the current DMG ships as macOS binaries. For the verified x86_64 build, download and verify the companion archive:

```bash
curl -L --fail -o build/extract/codex-package-x86_64-unknown-linux-musl.tar.gz \
  https://github.com/openai/codex/releases/download/rust-v0.146.0-alpha.3.1/codex-package-x86_64-unknown-linux-musl.tar.gz
printf '%s  %s\n' \
  71696f571d99b83ca09ef482653315fe8b7bfc1c18253662da5406e8d3f17158 \
  build/extract/codex-package-x86_64-unknown-linux-musl.tar.gz | sha256sum -c -
mkdir -p build/extract/codex-package-linux
tar -xzf build/extract/codex-package-x86_64-unknown-linux-musl.tar.gz \
  -C build/extract/codex-package-linux
```

Back up the macOS files and install the Linux helpers:

```bash
cp "$RESOURCES/rg" "$RESOURCES/rg.macos-arm64.backup"
cp "$RESOURCES/codex-code-mode-host" "$RESOURCES/codex-code-mode-host.macos-arm64.backup"
cp "$RESOURCES/codex-resources/bwrap" "$RESOURCES/codex-resources/bwrap.macos-arm64.backup"
cp build/extract/codex-package-linux/codex-path/rg "$RESOURCES/rg"
cp build/extract/codex-package-linux/bin/codex-code-mode-host "$RESOURCES/codex-code-mode-host"
cp build/extract/codex-package-linux/codex-resources/bwrap "$RESOURCES/codex-resources/bwrap"
chmod +x "$RESOURCES/rg" "$RESOURCES/codex-code-mode-host" "$RESOURCES/codex-resources/bwrap"
```

Verify the executable helpers before packaging:

```bash
file "$RESOURCES/rg" "$RESOURCES/codex-code-mode-host" "$RESOURCES/codex-resources/bwrap"
"$RESOURCES/rg" --version
"$RESOURCES/codex-code-mode-host" --help
```

## 4. Remove macOS-Only Native Resources

The current release includes macOS-only helpers such as `avatar-overlay.node`, `input-monitoring-permission.node`, and `remote-hosted-pip` under `Resources/native/`. Remove that directory after confirming its files are Mach-O:

```bash
rm -rf "$RESOURCES/native"
```

The current `cua_node/bin/node_repl` and `codex_chronicle` are macOS ARM64 Mach-O executables. The Debian packager explicitly excludes `cua_node/` and `codex_chronicle` rather than shipping unusable platform binaries. This leaves the Browser Use IAB backend unavailable and may log `browser_use_setup_failed ... reason=node-repl-missing`; it does not prevent the main Codex app-server handshake.

## 5. Rebuild Native Modules

Create `build/native-rebuild/package.json` with the inspected versions. The current file is:

```json
{
  "private": true,
  "dependencies": {
    "@electron/rebuild": "latest",
    "better-sqlite3": "12.9.0",
    "bufferutil": "^4.0.1",
    "electron": "42.3.0",
    "node-pty": "1.1.0",
    "utf-8-validate": "^6.0.0"
  }
}
```

Install source packages without running their install scripts, then rebuild for Electron 42:

```bash
pixi run npm install --ignore-scripts
pixi run npx electron-rebuild --version 42.3.0 --arch x64 \
  --only better-sqlite3,node-pty,bufferutil,utf-8-validate
```

Run those commands with `build/native-rebuild` as the working directory. Use `--arch arm64` on ARM64 Linux.

If `better-sqlite3@12.9.0` fails against the Electron 43 V8 external pointer API, patch only the temporary rebuild workspace:

```diff
--- a/node_modules/better-sqlite3/src/util/macros.cpp
+++ b/node_modules/better-sqlite3/src/util/macros.cpp
@@
-#define OnlyAddon static_cast<Addon*>(info.Data().As<v8::External>()->Value())
+#define OnlyAddon static_cast<Addon*>(info.Data().As<v8::External>()->Value(v8::kExternalPointerTypeTagDefault))
--- a/node_modules/better-sqlite3/src/better_sqlite3.cpp
+++ b/node_modules/better-sqlite3/src/better_sqlite3.cpp
@@
-v8::Local<v8::External> data = v8::External::New(isolate, addon);
+v8::Local<v8::External> data = v8::External::New(isolate, addon, v8::kExternalPointerTypeTagDefault);
--- a/node_modules/better-sqlite3/src/util/helpers.cpp
+++ b/node_modules/better-sqlite3/src/util/helpers.cpp
@@
-func,
-0,
+func,
+nullptr,
```

Copy only the rebuilt binaries into the unpacked ASAR tree:

```bash
mkdir -p "$RESOURCES/app.asar.unpacked/node_modules/bufferutil/build/Release"
mkdir -p "$RESOURCES/app.asar.unpacked/node_modules/utf-8-validate/build/Release"
cp build/native-rebuild/node_modules/better-sqlite3/build/Release/better_sqlite3.node \
  "$RESOURCES/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
cp build/native-rebuild/node_modules/node-pty/build/Release/pty.node \
  "$RESOURCES/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node"
cp build/native-rebuild/node_modules/bufferutil/build/Release/bufferutil.node \
  "$RESOURCES/app.asar.unpacked/node_modules/bufferutil/build/Release/bufferutil.node"
cp build/native-rebuild/node_modules/utf-8-validate/build/Release/validation.node \
  "$RESOURCES/app.asar.unpacked/node_modules/utf-8-validate/build/Release/validation.node"
```

Verify both report Linux ELF shared objects and have resolvable dependencies:

```bash
file "$RESOURCES/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
file "$RESOURCES/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node"
file "$RESOURCES/app.asar.unpacked/node_modules/bufferutil/build/Release/bufferutil.node"
file "$RESOURCES/app.asar.unpacked/node_modules/utf-8-validate/build/Release/validation.node"
ldd "$RESOURCES/app.asar.unpacked/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
ldd "$RESOURCES/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node"
```

## 6. Install The Matching Electron Runtime

The current `build/electron-runtime/package.json` is:

```json
{
  "private": true,
  "dependencies": {
    "electron": "42.3.0"
  }
}
```

Install it from `build/electron-runtime`:

```bash
pixi run npm install
```

If the Electron binary was skipped:

```bash
env -u ELECTRON_SKIP_BINARY_DOWNLOAD pixi run node node_modules/electron/install.js
```

Verify:

```bash
build/electron-runtime/node_modules/electron/dist/electron --version
```

The result must match the ASAR metadata, currently `v42.3.0`.

## 7. Patch Linux Rendering

Run the repository script before local smoke testing:

```bash
scripts/patch-linux-rendering.sh
```

It extracts the ASAR, dynamically locates the current minified opaque-background function, forces opaque Linux surfaces, disables transparent Linux subwindows, and repacks the ASAR. It also prepends a Linux primary-window close hook that stops the voice overlay before following Electron's normal quit lifecycle. It is idempotent and keeps its backup under `build/linux-rendering-patch/`.

This patch is required on X11 systems without a compositor to avoid blurred transparent windows. Packaging applies it by default. Set `CODEX_PATCH_LINUX_RENDERING=0` only for intentional unpatched testing.

All repository scripts resolve the preferred extracted ChatGPT resource path automatically. To target another resource tree, set `CODEX_RESOURCES_DIR` to a directory containing `app.asar`. When testing the patch against a copied raw ASAR, copy its sibling `app.asar.unpacked/` directory too; `@electron/asar` needs it to resolve unpacked entries.

## 8. Launch And Smoke Test

The current launcher already uses the ChatGPT bundle path and sets both required variables:

```bash
scripts/run-codex-linux.sh
```

Its essential behavior is:

```bash
export CODEX_CLI_PATH="$RESOURCES_DIR/codex"
export ELECTRON_RENDERER_URL="file://$ASAR_PATH/webview/index.html"
exec "$ELECTRON_BIN" "$ASAR_PATH" --disable-gpu-compositing "$@"
```

`CODEX_CLI_PATH` prevents accidental discovery of another CLI binary. `ELECTRON_RENDERER_URL` prevents a direct ASAR launch from looking for a Vite development server.

For a bounded smoke test:

```bash
timeout 12s scripts/run-codex-linux.sh
```

Success indicators:

- `Launching app ... platform=linux`
- `window ready-to-show`
- `window main frame finished load`
- `initialize_handshake_result ... outcome=success`
- `Codex CLI initialized`
- `app_server_connection.state_changed ... next=connected`
- `app routes mounted`

Usually non-fatal warnings include old VAAPI, `url.parse()` deprecation, and frontend/CLI experimental feature mismatches.

Common failures:

| Error | Cause | Fix |
| --- | --- | --- |
| DMG cannot be opened | `7z` cannot parse that UDIF | Convert with `dmg2img`, then inspect the image |
| Only `disk image.img` appears | Nested partition image or APFS | Inspect the inner image; use `apfs-fuse` only if confirmed |
| `deps/common.gypi not found` | Packaged native module lacks build sources | Rebuild in the clean npm workspace |
| `unexpected argument 'app-server'` | Standalone app-server binary installed | Replace it with the full Codex CLI |
| Blank window or Vite URL error | Renderer URL not set | Use `scripts/run-codex-linux.sh` |
| Native module load failure | Mach-O file or Electron ABI mismatch | Rebuild for the inspected Electron version and host arch |
| Blurry window | Transparent Electron surface on X11 | Apply `scripts/patch-linux-rendering.sh` |
| `browser_use_setup_failed ... node-repl-missing` | The current macOS-only CUA runtime is intentionally excluded | Browser Use IAB is unavailable until a compatible Linux `node_repl` exists |
| Electron version changed | New DMG may use older Electron (e.g. 43→42) | Always inspect `devDependencies.electron` in the ASAR metadata before rebuilding |

## 9. Build And Install The Debian Package

After the smoke test succeeds:

```bash
scripts/package-codex-deb.sh
```

Current defaults:

- package: `codex-app`
- version: `26.721.41059`
- architecture: `amd64`
- output: `dist/codex-app_26.721.41059_amd64.deb`

Override metadata only when building a different inspected release:

```bash
CODEX_DEB_VERSION=<version> CODEX_DEB_ARCH=<amd64-or-arm64> \
  scripts/package-codex-deb.sh
```

The package derives its default version from ASAR metadata, verifies the Electron runtime, Linux helper binaries, and rebuilt native modules, then patches only the staging ASAR. It installs Electron and resources under `/opt/codex-linux`, the desktop launcher as `/usr/bin/codex-app`, and a desktop entry/icon under `/usr/share`. It excludes macOS backups, `native/`, `cua_node/`, and `codex_chronicle`, and fixes resource readability and the `chrome-sandbox` owner/mode in `postinst`.

Install or replace an older local package:

```bash
sudo apt install ./dist/codex-app_26.721.41059_amd64.deb
sudo apt install --reinstall ./dist/codex-app_26.721.41059_amd64.deb
```

Use reinstall after package layout changes so obsolete files from the previous package are removed.

Verify package metadata and contents before installation:

```bash
dpkg-deb -I dist/codex-app_26.721.41059_amd64.deb
dpkg-deb --contents dist/codex-app_26.721.41059_amd64.deb
```

Verify after installation:

```bash
stat -c '%A %U:%G %n' \
  /opt/codex-linux/resources \
  /opt/codex-linux/resources/app.asar \
  /usr/bin/codex-app
codex-app
```

The local package must not replace the official `codex` command.

## Final Checklist

- Input DMG and app bundle paths were discovered, not assumed.
- The recorded app, Electron, native module, and Codex CLI versions agree.
- `Resources/codex` is a Linux ELF for the host architecture.
- `Resources/codex app-server --help` succeeds.
- `better_sqlite3.node`, `pty.node`, `bufferutil.node`, and `validation.node` are Linux ELF shared objects.
- `ldd` reports no unexpected missing native dependencies.
- Electron runtime version matches the ASAR metadata.
- macOS-only `Resources/native/` is absent.
- Linux rendering patch is applied.
- Local smoke test reaches a successful app-server handshake.
- Package launcher points to `/opt/codex-linux/resources/codex`.
- Package contains no user credentials, configuration, cache, or sessions.
- Package excludes macOS-only `cua_node/` and `codex_chronicle`; Browser Use IAB remains unavailable.
- `codex-app` launches after installation.
- `codex --version` still resolves the independent official CLI.
- Git status contains only intended source/configuration changes.

## Completion Report

Report:

- input DMG and discovered bundle path
- app, Electron, native module, and Codex CLI versions
- host architecture and Linux Codex target
- rendering patch result
- app-server handshake result
- package path and install status
- any remaining warnings and whether they are fatal

Because this is an OpenCode project skill, tell the user to quit and restart OpenCode after changing this file. The running process does not hot-reload skills.
