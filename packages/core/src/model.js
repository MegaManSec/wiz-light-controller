// The light's logical state and its translation to/from the WiZ `setPilot` /
// `getPilot` wire format. Keeping this separate from the transport (protocol.js)
// makes both trivially testable.

import {
  clampBrightness,
  clampTemp,
  clampRgb,
  clampInt,
  clampSpeed,
  DIMMING_MIN,
  DIMMING_MAX,
} from './validate.js';
import { TEMP_MIN, TEMP_MAX } from './color.js';

/**
 * @typedef {Object} LightState
 * @property {boolean} on
 * @property {'rgb'|'white'} mode
 * @property {[number, number, number]} rgb   Last RGB colour (0–255).
 * @property {number} temp                    Last white temperature (Kelvin).
 * @property {number} brightness              0–100.
 * @property {{ id: number, speed?: number }} [scene]  Set only while a dynamic scene runs.
 */

/** @type {LightState} */
export const DEFAULT_STATE = Object.freeze({
  on: false,
  mode: 'rgb',
  rgb: [255, 255, 255],
  temp: 4000,
  brightness: 100,
});

/**
 * Interpret a `getPilot` result into a {@link LightState}, or `null` if the
 * response is empty/unusable. The bulb reports RGB *and* temp fields, so mode is
 * inferred exactly as the original did: RGB wins when r/g/b are present and not
 * all zero, otherwise a present `temp` means white mode. A running dynamic scene
 * (non-zero `sceneId`) takes precedence and is surfaced as `scene`.
 *
 * @param {Record<string, unknown>|null|undefined} result
 * @returns {LightState|null}
 */
export function parsePilot(result) {
  if (!result || typeof result !== 'object') return null;

  const on = result.state === undefined ? true : Boolean(result.state);
  const brightness =
    result.dimming === undefined ? DEFAULT_STATE.brightness : clampBrightness(result.dimming);

  // A running dynamic scene reports a non-zero `sceneId` (and no r/g/b); surface
  // it so the UI can show e.g. "Party · speed 120". `sceneId` 0 means "no scene".
  const sceneId = Number(result.sceneId);
  if (Number.isInteger(sceneId) && sceneId > 0) {
    const scene = { id: sceneId };
    if (result.speed != null) scene.speed = clampSpeed(result.speed);
    return { on, mode: 'rgb', rgb: DEFAULT_STATE.rgb, temp: DEFAULT_STATE.temp, brightness, scene };
  }

  const { r, g, b, temp } = result;
  const hasRgb = r != null && g != null && b != null && (r || g || b);

  if (hasRgb) {
    return { on, mode: 'rgb', rgb: clampRgb([r, g, b]), temp: DEFAULT_STATE.temp, brightness };
  }
  if (temp != null) {
    return { on, mode: 'white', rgb: DEFAULT_STATE.rgb, temp: clampTemp(temp), brightness };
  }
  // Bulb is on but reports neither (rare); treat as a plain on/off state.
  return { on, mode: 'rgb', rgb: DEFAULT_STATE.rgb, temp: DEFAULT_STATE.temp, brightness };
}

/**
 * Build the `setPilot` `params` for a desired {@link LightState}. When off, only
 * `{ state: false }` is sent. A `state.scene` overrides colour/temp — it emits
 * `sceneId` (+ optional `speed`) with dimming. Optional per-device `bounds` (the bulb's real
 * `minDimLevel` and `cctRange`, negotiated from `getModelConfig`) clamp the wire
 * values to what that specific bulb supports; without them the WiZ-standard
 * defaults (`DIMMING_MIN`, `TEMP_MIN`/`TEMP_MAX`) apply.
 *
 * @param {LightState} state
 * @param {{ dimMin?: number, tempMin?: number, tempMax?: number }} [bounds]
 * @param {{ whiteMix?: boolean }} [options]  when set, an RGB colour's achromatic
 *   part is routed to the white channels (`c`/`w`) so the bright white LEDs help —
 *   brighter, slightly less saturated. Off by default (faithful pure RGB).
 * @returns {Record<string, number|boolean>}
 */
export function buildSetPilotParams(state, bounds = {}, { whiteMix = false } = {}) {
  if (!state.on) return { state: false };

  const dimMin = bounds.dimMin ?? DIMMING_MIN;
  const tempMin = bounds.tempMin ?? TEMP_MIN;
  const tempMax = bounds.tempMax ?? TEMP_MAX;

  const params = { state: true, dimming: clampInt(state.brightness, dimMin, DIMMING_MAX) };
  if (state.scene) {
    // A dynamic scene overrides colour/temp; speed is optional (omitted keeps the
    // bulb's current speed). Dimming still applies.
    params.sceneId = Number(state.scene.id);
    if (state.scene.speed != null) params.speed = clampSpeed(state.scene.speed);
    return params;
  }
  if (state.mode === 'white') {
    params.temp = clampInt(state.temp, tempMin, tempMax);
  } else if (whiteMix) {
    Object.assign(params, rgbToWhiteMixed(clampRgb(state.rgb)));
  } else {
    const [r, g, b] = clampRgb(state.rgb);
    Object.assign(params, { r, g, b });
  }
  return params;
}

/**
 * Split an RGB colour into a chromatic remainder plus an achromatic "white"
 * component, so the bulb's bright white LEDs carry the non-saturated part of the
 * colour: `white = min(r, g, b)` drives both white channels (`c`/`w`), and the
 * remainder stays on the RGB LEDs. A fully-saturated colour (min 0) gets no white
 * and is unchanged — a pure hue can only use the dimmer colour LEDs.
 *
 * @param {[number, number, number]} rgb  0–255 channels (already clamped)
 * @returns {{ r: number, g: number, b: number, c: number, w: number }}
 */
export function rgbToWhiteMixed([r, g, b]) {
  const white = Math.min(r, g, b);
  return { r: r - white, g: g - white, b: b - white, c: white, w: white };
}

/**
 * Exact inverse of {@link rgbToWhiteMixed}: reconstruct the original colour from
 * wire channels whose achromatic part rides the white LEDs. Only our own split
 * is invertible — it always drives both white channels equally — so a pilot with
 * `c !== w` (e.g. a colour set by the official app, which weights cool/warm
 * separately) returns `null` and display callers fall back to
 * {@link perceivedRgb}. Inverting — rather than folding the *perceived* colour
 * back into the state — keeps read-backs stable: perceived values are
 * display-only and wash toward white if ever re-sent.
 *
 * @param {[number, number, number]} rgb  chromatic remainder channels (0–255)
 * @param {number} [c]  cool-white channel value
 * @param {number} [w]  warm-white channel value
 * @returns {[number, number, number]|null}
 */
export function whiteMixedToRgb(rgb, c = 0, w = 0) {
  if (c !== w) return null;
  const white = clampInt(c, 0, 255);
  return clampRgb(rgb.map((channel) => Number(channel) + white));
}

/**
 * Derive per-device send bounds from a `getModelConfig` result: the bulb's real
 * white range (`cctRange`) and dimming floor (`minDimLevel`). Returns a `bounds`
 * object for {@link buildSetPilotParams}; unknown fields are omitted so the
 * WiZ-standard defaults apply.
 *
 * @param {Record<string, unknown>|null|undefined} modelConfig
 * @returns {{ dimMin?: number, tempMin?: number, tempMax?: number }}
 */
export function deviceBoundsFromConfig(modelConfig) {
  const bounds = {};
  if (!modelConfig || typeof modelConfig !== 'object') return bounds;

  const cct = modelConfig.cctRange;
  if (Array.isArray(cct)) {
    const values = cct.map(Number).filter((n) => Number.isFinite(n) && n > 0);
    if (values.length) {
      bounds.tempMin = Math.min(...values);
      bounds.tempMax = Math.max(...values);
    }
  }
  const dimMin = Number(modelConfig.minDimLevel);
  if (Number.isFinite(dimMin) && dimMin > 0) bounds.dimMin = dimMin;

  return bounds;
}

/**
 * The device's colour capabilities, read from a `getModelConfig` result: whether
 * it has RGB LEDs (≥3 *active* PWM channels — a white-only light has at most two,
 * cool + warm), tunable white (a real `cctRange` or ≥2 white channels via `nowc`),
 * and any white at all, plus the white range. The single source for
 * {@link describeDevice} and {@link scenesForDevice}; never claims a capability the
 * device doesn't expose. All false when nothing is determinable.
 *
 * @param {Record<string, unknown>|null|undefined} modelConfig
 * @returns {{ rgb: boolean, tunableWhite: boolean, white: boolean, tempMin?: number, tempMax?: number }}
 */
export function deviceCapabilities(modelConfig) {
  if (!modelConfig || typeof modelConfig !== 'object') {
    return { rgb: false, tunableWhite: false, white: false };
  }
  const { tempMin, tempMax } = deviceBoundsFromConfig(modelConfig);

  // Count active PWM channels — pairs [lo, hi] with hi > lo — ignoring padding.
  const pwm = Array.isArray(modelConfig.pwmRanges) ? modelConfig.pwmRanges : [];
  let channels = 0;
  for (let i = 0; i + 1 < pwm.length; i += 2) {
    if (Number(pwm[i + 1]) > Number(pwm[i])) channels += 1;
  }
  const whiteChannels = Number(modelConfig.nowc);

  const hasRange = Number.isFinite(tempMin) && Number.isFinite(tempMax) && tempMin < tempMax;
  const tunableWhite = hasRange || whiteChannels >= 2;
  const white = tunableWhite || Number.isFinite(tempMin) || whiteChannels >= 1;

  // tempMin/tempMax only when the bulb reports a range (so the result matches the
  // not-determinable path above, rather than carrying explicit `undefined`s).
  const caps = { rgb: channels >= 3, tunableWhite, white };
  if (Number.isFinite(tempMin)) caps.tempMin = tempMin;
  if (Number.isFinite(tempMax)) caps.tempMax = tempMax;
  return caps;
}

/**
 * A short, human capability summary derived from a `getModelConfig` result —
 * e.g. `"RGB + tunable white 2700–6500 K"`, via {@link deviceCapabilities}.
 * Returns `''` when nothing is determinable.
 *
 * @param {Record<string, unknown>|null|undefined} modelConfig
 * @returns {string}
 */
export function describeDevice(modelConfig) {
  const { rgb, tunableWhite, white, tempMin, tempMax } = deviceCapabilities(modelConfig);
  const hasRange = Number.isFinite(tempMin) && Number.isFinite(tempMax) && tempMin < tempMax;

  const parts = [];
  if (rgb) parts.push('RGB');
  if (tunableWhite) {
    parts.push(hasRange ? `tunable white ${tempMin}–${tempMax} K` : 'tunable white');
  } else if (white) {
    parts.push('white');
  }
  return parts.join(' + ');
}

/**
 * Parse the dim-to-warm curve from a `getUserConfig` result (`dim2WarmPoints` =
 * `[[kelvin, brightness%], …]`) into `{ kelvin, brightness }` points sorted by
 * brightness. Empty when the bulb doesn't report one.
 *
 * @param {Record<string, unknown>|null|undefined} userConfig
 * @returns {{ kelvin: number, brightness: number }[]}
 */
export function dimToWarmCurveFromConfig(userConfig) {
  const raw = userConfig && typeof userConfig === 'object' ? userConfig.dim2WarmPoints : null;
  if (!Array.isArray(raw)) return [];
  return raw
    .map((pair) =>
      Array.isArray(pair) && pair.length >= 2
        ? { kelvin: Number(pair[0]), brightness: Number(pair[1]) }
        : null,
    )
    .filter((p) => p && Number.isFinite(p.kelvin) && Number.isFinite(p.brightness))
    .sort((a, b) => a.brightness - b.brightness);
}

/**
 * Map a brightness (%) to a "dim-to-warm" / Warm Glow colour temperature. The
 * bulb's raw curve warms only below ~50% and can dip below the device's real
 * floor, which would leave the lower half flat; instead we take the curve's
 * Kelvin span *clamped to the device `range`* and stretch it across the whole
 * brightness range, so every level shifts (dimmest = warmest, brightest = the
 * curve's cool end). Falls back to `TEMP_MIN`/`TEMP_MAX` without a curve/range.
 *
 * @param {number} brightness  0–100
 * @param {{ kelvin: number }[]} [curve]  from {@link dimToWarmCurveFromConfig}
 * @param {{ min?: number, max?: number }} [range]  device white range
 * @returns {number} Kelvin
 */
export function warmGlowKelvin(brightness, curve = [], range = {}) {
  const kelvins = curve.map((p) => Number(p?.kelvin)).filter((k) => Number.isFinite(k) && k > 0);
  const lo = Number.isFinite(range.min) ? range.min : TEMP_MIN;
  const hi = Number.isFinite(range.max) ? range.max : TEMP_MAX;
  const warm = Math.max(lo, kelvins.length ? Math.min(...kelvins) : lo);
  const cool = Math.min(hi, kelvins.length ? Math.max(...kelvins) : hi);
  if (cool <= warm) return warm;
  const t = clampInt(brightness, 0, 100) / 100;
  return Math.round(warm + (cool - warm) * t);
}

/**
 * @typedef {Object} Preset
 * @property {'rgb'|'white'} mode
 * @property {number} [r] @property {number} [g] @property {number} [b]
 * @property {number} [temp]
 * @property {number} brightness
 */

/** Apply a preset on top of a state, returning a new state. Any active scene is
 *  cleared — a preset is a static colour/white, so it exits scene mode. */
export function applyPreset(state, preset) {
  const brightness = clampBrightness(preset.brightness ?? state.brightness);
  const base = { ...state };
  delete base.scene;
  if (preset.mode === 'white') {
    return { ...base, on: true, mode: 'white', temp: clampTemp(preset.temp), brightness };
  }
  return {
    ...base,
    on: true,
    mode: 'rgb',
    rgb: clampRgb([preset.r, preset.g, preset.b]),
    brightness,
  };
}

/** True when `state` already reflects `preset` (used to highlight the active
 *  preset). Never matches while the light is off or a dynamic scene is running —
 *  the bulb isn't showing the preset then, whatever the remembered colour says. */
export function stateMatchesPreset(state, preset) {
  if (!state.on || state.scene) return false;
  if (preset.mode !== state.mode) return false;
  if ((preset.brightness ?? 100) !== state.brightness) return false;
  if (preset.mode === 'rgb') {
    return preset.r === state.rgb[0] && preset.g === state.rgb[1] && preset.b === state.rgb[2];
  }
  return preset.temp === state.temp;
}

/** Built-in presets, seeded on first run. Mirrors the original defaults. */
export const DEFAULT_PRESETS = Object.freeze({
  rgb: {
    Red: { mode: 'rgb', r: 255, g: 0, b: 0, brightness: 100 },
    Green: { mode: 'rgb', r: 0, g: 255, b: 0, brightness: 100 },
    Blue: { mode: 'rgb', r: 0, g: 0, b: 255, brightness: 100 },
    Purple: { mode: 'rgb', r: 128, g: 0, b: 255, brightness: 100 },
    Sunset: { mode: 'rgb', r: 255, g: 120, b: 40, brightness: 100 },
    Aqua: { mode: 'rgb', r: 0, g: 255, b: 255, brightness: 100 },
  },
  white: {
    'Full White': { mode: 'white', temp: 6500, brightness: 100 },
    Warmish: { mode: 'white', temp: 4000, brightness: 100 },
    Relax: { mode: 'white', temp: 3000, brightness: 100 },
    'Full Warm': { mode: 'white', temp: TEMP_MIN, brightness: 100 },
    'Dim Relax': { mode: 'white', temp: 2700, brightness: 40 },
    'Dim White': { mode: 'white', temp: 6500, brightness: 40 },
  },
});
