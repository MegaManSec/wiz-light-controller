// The command implementations. Each handler receives a parsed context
// ({ positionals, values, stores }) and either prints output or throws an Error
// with a friendly message; the entry point renders the error and sets exit code.
//
// Core-dependent logic is kept thin: every handler is a small orchestration over
// `wiz-light-core` so the lead's post-install smoke test exercises real behaviour.

import {
  WizLight,
  queryPilot,
  getModelConfig,
  deviceBoundsFromConfig,
  parsePilot,
  buildSetPilotParams,
  applyPreset,
  findScene,
  scenesForDevice,
  sceneName,
  DEFAULT_STATE,
  hexToRgb,
  rgbToHex,
  perceivedRgb,
  isValidIp,
  clampBrightness,
  clampSpeed,
  SPEED_MIN,
  SPEED_MAX,
  formatMac,
  discover,
} from 'wiz-light-core';

import { COMMANDS } from './help.js';
import { bold, dim, green, cyan, swatch, print } from './output.js';

/** A command failed in a way worth showing the user (vs. an unexpected crash). */
export class CliError extends Error {}

const fail = (message) => {
  throw new CliError(message);
};

// ---------- shared resolution helpers ----------

/**
 * Resolve the target bulb IP: explicit positional first, else the last-used IP
 * from the store. Validates and throws a clear message when neither is usable.
 */
async function resolveIp(positional, stores) {
  const ip = positional ?? (await stores.lastState.loadIp());
  if (!ip) fail('No IP given and no previous bulb remembered. Pass an <ip> (e.g. 10.0.0.5).');
  if (!isValidIp(ip)) fail(`Not a valid IPv4 address: ${ip}`);
  return ip;
}

/** Parse and validate the optional `--brightness` flag, or return undefined. */
function parseBrightness(values) {
  if (values.brightness === undefined) return undefined;
  // A value-less `--brightness` parses (non-strict argv) as boolean `true`, which
  // `Number(true)` would silently turn into 1 — require an actual value instead.
  if (typeof values.brightness !== 'string') fail('--brightness needs a value from 0 to 100.');
  const n = Number(values.brightness);
  if (!Number.isFinite(n) || n < 0 || n > 100) {
    fail('--brightness must be a number from 0 to 100.');
  }
  return clampBrightness(n);
}

/** Parse and validate the optional `--speed` flag (dynamic scenes), or undefined. */
function parseSpeed(values) {
  if (values.speed === undefined) return undefined;
  const range = `from ${SPEED_MIN} to ${SPEED_MAX}`;
  if (typeof values.speed !== 'string') fail(`--speed needs a value ${range}.`);
  const n = Number(values.speed);
  if (!Number.isFinite(n) || n < SPEED_MIN || n > SPEED_MAX)
    fail(`--speed must be a number ${range}.`);
  return clampSpeed(n);
}

/** Parse an optional positive-integer flag (e.g. `--attempts`, `--timeout`). */
function parsePositiveInt(value, label) {
  if (value === undefined) return undefined;
  if (typeof value !== 'string') fail(`--${label} needs a positive number.`);
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) fail(`--${label} must be a positive number.`);
  return Math.floor(n);
}

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Query a bulb a few times before giving up — WiZ bulbs drop the occasional
 *  datagram and have brief firmware "micro-sleeps", so a single getPilot can
 *  spuriously fail (mirrors the desktop app's retry). */
async function queryWithRetry(ip, attempts = 3) {
  for (let i = 0; i < attempts; i += 1) {
    const result = await queryPilot(ip);
    if (result) return result;
    if (i < attempts - 1) await delay(150);
  }
  return null;
}

/** The bulb's real send bounds (white range + dimming floor) from
 *  `getModelConfig`, or `{}` when unreported — so the CLI clamps to what the
 *  device actually supports instead of the WiZ-standard defaults. */
async function deviceBounds(ip) {
  return deviceBoundsFromConfig(await getModelConfig(ip));
}

/** Query a bulb's live state, failing cleanly when it can't be reached. */
async function liveState(ip) {
  const state = parsePilot(await queryWithRetry(ip));
  if (!state) fail(`Could not reach a WiZ bulb at ${ip}.`);
  return state;
}

const light = (ip) => new WizLight(ip);

// ---------- formatting ----------

function formatState(ip, state, result = {}) {
  const power = state.on ? green('on') : dim('off');
  const lines = [`${bold(ip)}  ${power}`];
  if (state.scene) {
    const name = sceneName(state.scene.id) ?? `#${state.scene.id}`;
    const at = state.scene.speed != null ? ` · speed ${state.scene.speed}` : '';
    lines.push(`  scene       ${cyan(name)}${at}`);
  } else {
    lines.push(`  mode        ${state.mode}`);
    if (state.mode === 'rgb') {
      // Fold the bulb's white channels (c/w) in so the swatch matches what the eye
      // sees (and the official app), not just the raw colour LEDs.
      const rgb = perceivedRgb(state.rgb, result.c, result.w);
      lines.push(`  colour      ${swatch(rgb)} ${rgbToHex(rgb)}`);
    } else {
      lines.push(`  temperature ${state.temp}K`);
    }
  }
  lines.push(`  brightness  ${state.brightness}%`);
  return lines.join('\n');
}

function presetLine(name, p) {
  const at = `@ ${p.brightness ?? 100}%`;
  if (p.mode === 'white') return `  ${cyan(name)} — ${p.temp}K ${at}`;
  const rgb = [p.r, p.g, p.b];
  return `  ${swatch(rgb)} ${cyan(name)} — ${rgbToHex(rgb)} ${at}`;
}

// ---------- commands ----------

async function cmdDiscover({ values }) {
  // Validate up front: a non-numeric `--attempts` would otherwise become NaN and
  // make discovery loop forever.
  const timeoutMs = parsePositiveInt(values.timeout, 'timeout');
  const attempts = parsePositiveInt(values.attempts, 'attempts');
  const lights = await discover({ timeoutMs, attempts });

  if (values.json) {
    print(JSON.stringify(lights, null, 2));
    return;
  }
  if (lights.length === 0) {
    print(dim('No bulbs found.'));
    return;
  }
  for (const l of lights) {
    print(`${bold(l.name)} — ${l.ip} — ${dim(formatMac(l.mac))}`);
  }
}

async function cmdStatus({ positionals, stores }) {
  const ip = await resolveIp(positionals[0], stores);
  // Keep the raw result (not just the parsed state) so the swatch can fold in the
  // bulb's white channels (c/w) for a true-to-eye colour.
  const result = await queryWithRetry(ip);
  const state = parsePilot(result);
  if (!state) fail(`Could not reach a WiZ bulb at ${ip}.`);
  await stores.lastState.saveIp(ip);
  print(formatState(ip, state, result));
}

const powerCommand =
  (on) =>
  async ({ positionals, stores }) => {
    const ip = await resolveIp(positionals[0], stores);
    // One-shot: send immediately rather than via the debounced `power()` path.
    await light(ip).sendNow({ state: on });
    await stores.lastState.saveIp(ip);
    print(`${bold(ip)} turned ${on ? green('on') : dim('off')}`);
  };

async function cmdColor({ positionals, values, stores }) {
  const ip = await resolveIp(positionals[0], stores);
  const rest = positionals.slice(1);
  if (rest.length === 0) fail('Give a colour: a hex string or three 0-255 values.');

  let rgb;
  if (rest.length === 1) {
    rgb = hexToRgb(rest[0]);
    if (!rgb) fail(`Not a valid hex colour: ${rest[0]} (expected #rrggbb).`);
  } else if (rest.length === 3) {
    rgb = rest.map((n) => Number(n));
    // Require whole numbers: a fractional channel can't be shown by the bulb and
    // would render a malformed ANSI swatch (the engine clamps the wire value, but
    // the printed preview reads the raw input).
    if (rgb.some((c) => !Number.isInteger(c) || c < 0 || c > 255)) {
      fail('RGB channels must be three whole numbers from 0 to 255.');
    }
  } else {
    fail('Give either a hex string or exactly three 0-255 values.');
  }

  const brightness = parseBrightness(values) ?? DEFAULT_STATE.brightness;
  const bounds = await deviceBounds(ip);
  const params = buildSetPilotParams(
    { ...DEFAULT_STATE, on: true, mode: 'rgb', rgb, brightness },
    bounds,
  );
  await light(ip).sendNow(params);
  await stores.lastState.saveIp(ip);
  print(`${bold(ip)} set to ${swatch(rgb)} ${rgbToHex(rgb)} @ ${brightness}%`);
}

async function cmdTemp({ positionals, values, stores }) {
  const ip = await resolveIp(positionals[0], stores);
  const kelvin = Number(positionals[1]);
  if (!Number.isFinite(kelvin)) fail('Give a colour temperature in Kelvin (e.g. 4000).');

  const brightness = parseBrightness(values) ?? DEFAULT_STATE.brightness;
  const bounds = await deviceBounds(ip);
  const params = buildSetPilotParams(
    { ...DEFAULT_STATE, on: true, mode: 'white', temp: kelvin, brightness },
    bounds,
  );
  await light(ip).sendNow(params);
  await stores.lastState.saveIp(ip);
  print(`${bold(ip)} set to ${params.temp}K @ ${brightness}%`);
}

async function cmdBrightness({ positionals, stores }) {
  const ip = await resolveIp(positionals[0], stores);
  if (positionals[1] === undefined) fail('Give a brightness from 0 to 100.');
  const value = Number(positionals[1]);
  if (!Number.isFinite(value) || value < 0 || value > 100) {
    fail('Brightness must be a number from 0 to 100.');
  }

  // Preserve the current colour/mode — only change brightness.
  const state = await liveState(ip);
  const params = buildSetPilotParams(
    { ...state, on: true, brightness: clampBrightness(value) },
    await deviceBounds(ip),
  );
  await light(ip).sendNow(params);
  await stores.lastState.saveIp(ip);
  print(`${bold(ip)} brightness set to ${clampBrightness(value)}%`);
}

async function cmdPresets({ values, stores }) {
  const presets = await stores.presets.load();
  if (values.json) {
    print(JSON.stringify(presets, null, 2));
    return;
  }
  const groups = [
    ['RGB', presets.rgb],
    ['White', presets.white],
  ];
  for (const [label, group] of groups) {
    const entries = Object.entries(group ?? {});
    if (entries.length === 0) continue;
    print(bold(label));
    for (const [name, p] of entries) print(presetLine(name, p));
  }
}

async function cmdPreset({ positionals, values, stores }) {
  const ip = await resolveIp(positionals[0], stores);
  const name = positionals[1];
  if (!name) fail('Give a preset name (see `wiz presets`).');

  const presets = await stores.presets.load();
  const preset = presets.rgb?.[name] ?? presets.white?.[name];
  if (!preset) fail(`Unknown preset: ${name}. Run \`wiz presets\` to list them.`);

  const brightness = parseBrightness(values);
  const next = applyPreset(await liveStateOrDefault(ip), {
    ...preset,
    brightness: brightness ?? preset.brightness,
  });
  await light(ip).sendNow(buildSetPilotParams(next, await deviceBounds(ip)));
  await stores.lastState.saveIp(ip);
  print(`${bold(ip)} → preset ${cyan(name)}`);
}

/** Like {@link liveState} but tolerant: presets define a full state, so an
 *  unreachable query just falls back to defaults rather than aborting. */
async function liveStateOrDefault(ip) {
  return parsePilot(await queryWithRetry(ip)) ?? { ...DEFAULT_STATE };
}

async function cmdScenes({ positionals, values, stores }) {
  // scenesForDevice(null) returns every scene, so an unreachable/omitted bulb still
  // lists them; a reachable one narrows to what it can actually show.
  const ip = positionals[0] ?? (await stores.lastState.loadIp());
  const model = ip && isValidIp(ip) ? await getModelConfig(ip) : null;
  const list = scenesForDevice(model);
  if (values.json) {
    print(JSON.stringify(list, null, 2));
    return;
  }
  print(bold('Scenes'));
  for (const { id, name, hint } of list) {
    print(`  ${dim(String(id).padStart(2))}  ${cyan(name)}${hint ? dim(` — ${hint}`) : ''}`);
  }
}

async function cmdScene({ positionals, values, stores }) {
  const ip = await resolveIp(positionals[0], stores);
  // Join the rest so a multi-word name ("Pastel Colors") works even unquoted.
  const wanted = positionals.slice(1).join(' ').trim();
  if (!wanted) fail('Give a scene name or id (see `wiz scenes`).');
  const scene = findScene(wanted);
  if (!scene) fail(`Unknown scene: ${wanted}. Run \`wiz scenes\` to list them.`);

  const speed = parseSpeed(values);
  const brightness = parseBrightness(values) ?? DEFAULT_STATE.brightness;
  const next = {
    ...DEFAULT_STATE,
    on: true,
    brightness,
    scene: speed === undefined ? { id: scene.id } : { id: scene.id, speed },
  };
  await light(ip).sendNow(buildSetPilotParams(next, await deviceBounds(ip)));
  await stores.lastState.saveIp(ip);
  const at = speed === undefined ? '' : ` @ speed ${speed}`;
  print(`${bold(ip)} → scene ${cyan(scene.name)}${at}`);
}

async function cmdLights({ values, stores }) {
  const saved = await stores.savedLights.load();
  const entries = Object.entries(saved);
  if (values.json) {
    print(JSON.stringify(saved, null, 2));
    return;
  }
  if (entries.length === 0) {
    print(dim('No saved lights. Use `wiz save <ip> <name>`.'));
    return;
  }
  for (const [mac, { name, ip }] of entries) {
    print(`${bold(name)} — ${ip} — ${dim(formatMac(mac))}`);
  }
}

async function cmdSave({ positionals, stores }) {
  const ip = await resolveIp(positionals[0], stores);
  const name = positionals[1];
  if (!name) fail('Give a name to save this light under (e.g. `wiz save 10.0.0.5 Desk`).');

  const result = await queryWithRetry(ip);
  if (!result) fail(`Could not reach a WiZ bulb at ${ip}.`);
  if (!result.mac) fail(`Bulb at ${ip} did not report a MAC address; cannot save it.`);

  await stores.savedLights.set(result.mac, name, ip);
  await stores.lastState.saveIp(ip);
  print(`Saved ${bold(name)} (${dim(formatMac(result.mac))}) at ${ip}`);
}

/** Dispatch table. Keys are canonical command names; `status` carries the `sync` alias. */
export const handlers = {
  discover: cmdDiscover,
  status: cmdStatus,
  on: powerCommand(true),
  off: powerCommand(false),
  color: cmdColor,
  temp: cmdTemp,
  brightness: cmdBrightness,
  presets: cmdPresets,
  preset: cmdPreset,
  scenes: cmdScenes,
  scene: cmdScene,
  lights: cmdLights,
  save: cmdSave,
};

/** Resolve aliases (e.g. `sync` → `status`) to a canonical command name. */
export function resolveCommand(name) {
  if (handlers[name]) return name;
  for (const [canonical, meta] of Object.entries(COMMANDS)) {
    if (meta.aliases?.includes(name)) return canonical;
  }
  return undefined;
}
