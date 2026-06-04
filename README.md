<p align="center">
  <img src="assets/app_iconhigh.png" alt="WiZ Light Controller app icon" width="200">
</p>

<h1 align="center">WiZ Light Controller</h1>

Fast, **local, cloud-free** control for Philips WiZ smart bulbs. It talks to bulbs directly over your LAN (UDP) — no account, no cloud round-trip, no telemetry. At its heart is one small, dependency-free JavaScript engine (`wiz-light-core`) that is reused by two front-ends: a `wiz` **CLI** and a **native macOS menu-bar app** (Swift), which runs the engine's pure colour and light-state logic via **JavaScriptCore** — so both share a single, tested implementation.

## Features

Mirrors the original app's capabilities:

- **Discovery** — find WiZ bulbs on your network (UDP broadcast), keyed by MAC.
- **Saved lights** — remember bulbs by **MAC** with a friendly name; the IP is re-resolved on discovery, so it survives DHCP changes.
- **Colour** — a **colour wheel** plus direct **RGB / HSV / hex** entry, with per-device colour memory.
- **White temperature** — tunable white over the bulb's own negotiated range (e.g. **2200–6500 K**).
- **Brightness** — 0–100% (clamped to the firmware-valid floor; see below).
- **Presets** — seeded RGB + white presets, with apply / match.
- **Sync from light** — read a bulb's current state (`getPilot`) back into the UI.
- **Settings** — accent/highlight colour and auto-sync, persisted locally.

## Install

### macOS app

1. Download **`WiZ-Light-Controller-macOS.zip`** from the [latest release](https://github.com/MegaManSec/wiz-light-controller/releases/latest) and unzip it.
2. Move **`WiZ Light Controller.app`** to `/Applications`.
3. The build may be unsigned, so macOS blocks it on first launch — **right-click → Open**, or launch it and choose **Open Anyway** under **System Settings → Privacy & Security**. (If macOS calls the app "damaged", clear the download quarantine: `xattr -dr com.apple.quarantine "/Applications/WiZ Light Controller.app"`.)
4. Approve **Local Network** access when prompted — it's required to reach the bulbs over your LAN. (You can grant it later under **System Settings → Privacy & Security → Local Network**.)

It lives in the menu bar with no Dock icon: click the bulb for the quick dropdown, or the controls button in its header for the full window.

### CLI and engine (npm)

Published to npm; the CLI needs **Node ≥ 24**.

```bash
pnpm add -g wiz-light-cli      # install the `wiz` command globally
wiz discover                   # find bulbs on your LAN — then `wiz --help`
```

Or use the engine as a library in your own project:

```bash
pnpm add wiz-light-core
```

(Both also install with npm: `npm i -g wiz-light-cli` / `npm i wiz-light-core`.)

## Monorepo layout

A pnpm workspace:

```
packages/core   wiz-light-core   Pure engine: WiZ UDP protocol, broadcast discovery, colour maths, light-state model, persisted stores. Zero runtime dependencies.
packages/cli    wiz-light-cli    Dependency-free `wiz` CLI on top of wiz-light-core.
apps/macos                       Native macOS menu-bar app (SwiftPM). Runs wiz-light-core's pure logic in JavaScriptCore; UDP/persistence/UI in Swift.
legacy/                          Original GPL-3.0 Python app (wiz.py), preserved as-is.
scripts/                         Repo tooling (build-jscore.mjs, release-notes.mjs).
```

## Build from source

For hacking on the project — the prebuilt app and published packages are under [Install](#install) above. Requires **Node 24** and **pnpm 10** (via Corepack — `corepack enable`).

```bash
pnpm install              # integrity-checked: pnpm install --frozen-lockfile
```

### Engine

```bash
pnpm test:core            # run the engine's node:test suite
```

### CLI

```bash
pnpm --filter wiz-light-cli start -- discover     # find bulbs on your LAN
pnpm --filter wiz-light-cli start -- --help       # all commands
```

(To install the published `wiz` command, see [Install](#install). From a checkout, link it instead: `pnpm --filter wiz-light-cli exec npm link`.)

### macOS app

Needs **Xcode** (Swift toolchain) on **macOS 13+**. The JavaScriptCore bundle is generated from `wiz-light-core`, so build it first:

```bash
pnpm build:jscore             # generate the JSCore bundle from wiz-light-core
make -C apps/macos app        # assemble + ad-hoc-sign "WiZ Light Controller.app"
make -C apps/macos run        # build (if needed) and launch it
```

For a signed, distributable build, set `CODESIGN_IDENTITY` to your Developer ID Application identity (see [`apps/macos`](apps/macos/README.md)).

## Security

Local-only by design, with a deliberately small surface:

- **Zero-dependency engine.** `wiz-light-core` and `wiz-light-cli` use **Node built-ins only** — nothing third-party at runtime.
- **Supply chain.** CI installs with a **frozen lockfile**; pnpm 10 blocks dependency lifecycle (postinstall) scripts except an explicit `pnpm.onlyBuiltDependencies` allowlist.
- **Native app.** Runs under the **App Sandbox** with only the two LAN networking entitlements it needs (`network.client` / `network.server`) and a clear Local-Network usage description. There is **no bundled browser or Node** — JavaScriptCore is a hardened Apple system framework. CI builds **ad-hoc signed** by default; tagged releases are **Developer ID** signed and notarized when the signing secrets are present.

See [`apps/macos`](apps/macos/README.md) for the app's full security, signing, and notarization model.

## Requirements

- **Node 24** and **pnpm 10** (pinned; use Corepack).
- **macOS app:** **Xcode 15+** on **macOS 13+** (Apple frameworks only — no third-party Swift dependencies).
- Your machine on the **same LAN** as the bulbs.

## Packages

- [`packages/core`](packages/core/README.md) — `wiz-light-core`, the engine (protocol, discovery, colour, model, stores).
- [`packages/cli`](packages/cli/README.md) — `wiz-light-cli`, the `wiz` command-line interface.
- [`apps/macos`](apps/macos/README.md) — the native macOS menu-bar app.

## License

[GPL-3.0-or-later](LICENSE). Originally a Python app by [Eshaan Pisal](https://github.com/kek353) (GPL-3.0), preserved under [`legacy/`](legacy/).
