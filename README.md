# Codex App Linux

Unofficial local workflow for rebuilding the macOS Codex desktop app (`Codex.dmg`) into a runnable Linux build and optional Debian package.

## Disclaimer

This project is not official, not supported by OpenAI, and is not affiliated with the official Codex desktop app distribution.

The Linux build is produced by converting the macOS Electron bundle without access to the original desktop app source code. It may have bugs, missing features, broken auto-update behavior, platform-specific issues, or compatibility problems after new Codex releases.

Use it at your own risk.

## What This Does

- Extracts `Codex.dmg`
- Extracts or mounts the app resources, including APFS DMGs when needed
- Replaces the bundled macOS Codex backend with the Linux Codex CLI binary
- Removes macOS-only native binaries such as Sparkle helpers
- Rebuilds native modules for Linux (`better-sqlite3`, `node-pty`)
- Runs the app with a matching Linux Electron runtime
- Optionally builds a `.deb` package named `codex-app`

## Install The Debian Package

The `.deb` file is not committed to git. It is expected to be downloaded from a GitHub Release or built locally into `dist/`.

Install with:

```bash
sudo apt install ./dist/codex-app_26.513.31313_amd64.deb
```

If replacing an older local build:

```bash
sudo apt install --reinstall ./dist/codex-app_26.513.31313_amd64.deb
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
# place Codex.dmg at the repo root
# follow .opencode/skills/build-codex-linux/SKILL.md
scripts/run-codex-linux.sh
scripts/package-codex-deb.sh
```

## Notes

- `Codex.dmg`, `build/`, `.pixi/`, and `dist/` are intentionally ignored.
- The package installs as `codex-app` to avoid conflicting with the official `codex` CLI command.
- App login/session data is not packaged; users sign in with their own account at runtime.
- New upstream Codex releases may require changes to Electron version, native module rebuilds, or extraction steps.

## License

The scripts, documentation, and configuration in this repository are licensed under the MIT License. This license does not apply to the official Codex desktop app, `Codex.dmg`, OpenAI trademarks, or third-party binaries used by the conversion workflow.
