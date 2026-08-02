# Codex App Linux

Unofficial local workflow for rebuilding the macOS ChatGPT/Codex desktop app (`ChatGPT.dmg`) into a runnable Linux build and optional Debian package.

## Disclaimer

This project is not official, not supported by OpenAI, and is not affiliated with the official Codex desktop app distribution.

The Linux build is produced by converting the macOS Electron bundle without access to the original desktop app source code. It may have bugs, missing features, broken auto-update behavior, platform-specific issues, or compatibility problems after new Codex releases.

Use it at your own risk.

## What This Does

- Extracts `ChatGPT.dmg`
- Extracts or mounts the app resources, including APFS DMGs when needed
- Replaces the bundled macOS Codex backend with the Linux Codex CLI binary
- Replaces required macOS helper binaries (`rg`, `codex-code-mode-host`, and `bwrap`)
- Removes macOS-only native binaries such as Sparkle helpers
- Rebuilds native modules for Linux (`better-sqlite3`, `node-pty`)
- Runs the app with a matching Linux Electron runtime
- Optionally builds a `.deb` package named `codex-app`

## Install The Debian Package

The `.deb` file is not committed to git. It is expected to be downloaded from a GitHub Release or built locally into `dist/`.

Install with:

```bash
sudo apt install ./dist/codex-app_26.721.41059_amd64.deb
```

If replacing an older local build:

```bash
sudo apt install --reinstall ./dist/codex-app_26.721.41059_amd64.deb
```

Launch with:

```bash
codex-app
```

## Local Build

This repo uses pixi-managed tooling. The main workflow is documented in:

```text
.opencode/skills/build-codex-linux/SKILL.md
```

High-level local flow:

```bash
pixi install
# place ChatGPT.dmg at the repo root
# follow .opencode/skills/build-codex-linux/SKILL.md
scripts/run-codex-linux.sh
scripts/package-codex-deb.sh
```

The scripts automatically locate the current extracted ChatGPT resources. Set `CODEX_RESOURCES_DIR=/path/to/Resources` only when testing or packaging a different extracted bundle.

For X11 sessions without a compositor, patch the converted ASAR before launching locally:

```bash
scripts/patch-linux-rendering.sh
```

The Debian packaging script applies this patch automatically by default. Set `CODEX_PATCH_LINUX_RENDERING=0` to skip it.

On Linux, closing the final main window now follows Electron's normal quit lifecycle and stops the voice-mode overlay instead of leaving it active in the tray.

## Notes

- `ChatGPT.dmg`, `Codex.dmg`, `build/`, `.pixi/`, and `dist/` are intentionally ignored.
- The package installs as `codex-app` to avoid conflicting with the official `codex` CLI command.
- The Linux package disables GPU compositing and patches transparent Electron windows to opaque Linux surfaces to avoid blurry rendering on X11 without a compositor.
- The package excludes the current DMG's macOS-only `cua_node` and `codex_chronicle` payloads. The main app works, but the Browser Use IAB backend remains unavailable because no Linux `node_repl` artifact is available.
- App login/session data is not packaged; users sign in with their own account at runtime.
- New upstream Codex releases may require changes to Electron version, native module rebuilds, or extraction steps.

## License

The scripts, documentation, and configuration in this repository are licensed under the MIT License. This license does not apply to the official Codex desktop app, `ChatGPT.dmg`, `Codex.dmg`, OpenAI trademarks, or third-party binaries used by the conversion workflow.
