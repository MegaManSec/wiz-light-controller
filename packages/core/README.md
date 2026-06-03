# wiz-light-core

The engine behind [WiZ Light Controller](../../README.md): a small, dependency-free JavaScript library for controlling Philips WiZ smart bulbs over the LAN (UDP, port 38899) — no cloud, no account. It has zero runtime dependencies (Node built-ins only) and is the single, tested implementation shared by the [`wiz` CLI](../cli/README.md) and the native macOS app.

## Install

```bash
pnpm add wiz-light-core
```

Requires Node 24+. ESM-only (`"type": "module"`).

## What's inside

- **`protocol.js`** — the UDP transport. `sendPilot` (fire-and-forget `setPilot`), `queryPilot` (`getPilot`, resolving to the bulb's state or `null` on timeout — it never rejects), and the stateful `WizLight` controller, which debounces rapid updates (slider drags) into one send and retries it to ride out UDP loss and firmware micro-sleeps. The socket factory is injectable, so the protocol is testable without real sockets.
- **`discovery.js`** — `discover()` broadcasts `getSystemConfig` and resolves the set of bulbs on the LAN, deduplicated by MAC. Supports an `onFound` callback, an `AbortSignal`, and an injectable socket.
- **`color.js`** — pure colour maths: `rgbToHsv` / `hsvToRgb`, `rgbToHex` / `hexToRgb`, `kelvinToRgb`, and colour-wheel geometry (`wheelToHS` / `hsToWheel`).
- **`validate.js`** — input guards and clamps: `isValidIp`, `isValidHex`, `normalizeHex`, `formatMac`, `clampBrightness`, `clampTemp`, `clampRgb`, and `toDimming` (the firmware-valid `dimming >= 10` floor).
- **`model.js`** — the logical `LightState` and its translation to/from the wire format (`parsePilot` / `buildSetPilotParams`), per-device capability parsing from `getModelConfig` (`deviceBoundsFromConfig`, `describeDevice`, `dimToWarmCurveFromConfig`), the Warm-Glow curve (`warmGlowKelvin`), and presets.
- **stores** — corruption-tolerant, atomic JSON persistence (settings, presets, saved lights, last state), wired to one directory by `createStores(dir)`.

The pure, browser-safe modules are also published as subpath exports — `wiz-light-core/color`, `wiz-light-core/validate`, `wiz-light-core/model` — so a UI layer can import the colour maths and the model without pulling in any Node built-ins.

## Example

```js
import { WizLight, discover } from 'wiz-light-core';

const bulbs = await discover(); // [{ ip, mac, moduleName }, …]
const light = new WizLight(bulbs[0].ip);

light.apply({ on: true, mode: 'rgb', rgb: [255, 0, 128], brightness: 80 });
const live = await light.getPilot(); // current state, or null if unreachable
light.close();
```

## Tests

```bash
node --test        # from this package (or `pnpm test:core` from the repo root)
```
