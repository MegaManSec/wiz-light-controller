# WiZ Light Controller — macOS app

A native menu-bar app for Philips WiZ lights. The colour maths and light-state model are the shared, tested [`wiz-light-core`](../../packages/core/README.md) engine, run inside JavaScriptCore via `WizKit`; the UDP transport, LAN discovery, and persistence are Swift on top of Apple frameworks only (SwiftUI, AppKit, JavaScriptCore, Foundation, Darwin POSIX sockets). No third-party Swift dependencies.

## Layout

- `Sources/WizKit/` — the engine layer. `WizCore` bridges the JS bundle; `WizClient` (UDP `setPilot`/`getPilot`, debounced + retried), `Discovery` (broadcast `getSystemConfig`), and `Stores` (persistence) are the Swift transport.
- `Sources/WizApp/` — the SwiftUI/AppKit menu-bar app: a status item + SwiftUI dropdown popover (`DropdownView`), and a controller window (colour wheel, RGB/HSV/hex sliders, brightness, white temperature, presets, discovery, settings).
- `build/` — packaging inputs: `Info.plist`, `WizLightController.entitlements`.
- `Makefile` — build / icon / bundle / sign.

## Build, test, run

```sh
swift build --package-path apps/macos       # debug build (WizKit + WizApp)
swift test  --package-path apps/macos       # WizKit + Stores unit tests

make -C apps/macos app                      # assemble "build/WiZ Light Controller.app"
make -C apps/macos run                      # open the assembled app
```

`make app` runs a release build, generates `build/AppIcon.icns` from `../../assets/app_iconhigh.png`, assembles the `.app`, copies the JS engine bundle (`wiz-core.global.js`) into `Contents/Resources/` so `WizCore` finds it via `Bundle.main` at runtime, and codesigns the result.

The app is a menu-bar (`LSUIElement`) app — it has no Dock icon until you open the controller window. Click the menu-bar bulb for a quick dropdown (power, brightness, and colour / white-temperature, with an RGB / White / Warm Glow mode switch); the controls button in its header opens the full window, which adds the colour wheel, presets (including Warm Glow levels), a "Brighter colours" white-LED blend, and discovery / settings.

> Note: the JavaScriptCore bundle is generated from `wiz-light-core` by `pnpm build:jscore` (run from the repo root) — regenerate it before building if you've changed the engine.

## Security model

The app runs under the **App Sandbox** with two network entitlements:

- `com.apple.security.network.client` — outbound UDP (`setPilot`/`getPilot`, broadcasts).
- `com.apple.security.network.server` — inbound UDP (discovery / `getPilot` replies).

Broadcast discovery (to `255.255.255.255` plus each interface's directed subnet broadcast) works under these two. The Apple-approval-gated multicast entitlement (`com.apple.developer.networking.multicast`) is **not** used — it would only be needed if discovery switched to IP multicast.

`Info.plist` declares `NSLocalNetworkUsageDescription`, shown when macOS prompts for local-network access. (Note: rebuilding re-signs the app, which resets that grant — re-allow it under System Settings → Privacy & Security → Local Network.)

The shared engine runs in JavaScriptCore (a system framework) — there is **no bundled JS runtime** and no network access from the engine itself; all IO is the Swift transport.

## Signing / notarization

By default `make app` signs **ad-hoc** (`-`), which is enough to run locally. For distribution, pass a Developer ID identity:

```sh
make -C apps/macos app CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

On a `v*` tag, CI notarizes and staples the app (so Gatekeeper accepts it on other Macs) when the Apple signing secrets are configured; without them it falls back to the ad-hoc build above.
