// The light's logical state and its translation to/from the WiZ `setPilot` /
// `getPilot` wire format. Keeping this separate from the transport (protocol.js)
// makes both trivially testable.

import {
  clampBrightness,
  clampTemp,
  clampRgb,
  clampInt,
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
 * all zero, otherwise a present `temp` means white mode.
 *
 * @param {Record<string, unknown>|null|undefined} result
 * @returns {LightState|null}
 */
export function parsePilot(result) {
  if (!result || typeof result !== 'object') return null;

  const on = result.state === undefined ? true : Boolean(result.state);
  const brightness =
    result.dimming === undefined ? DEFAULT_STATE.brightness : clampBrightness(result.dimming);

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
 * `{ state: false }` is sent. Optional per-device `bounds` (the bulb's real
 * `minDimLevel` and `cctRange`, negotiated from `getModelConfig`) clamp the wire
 * values to what that specific bulb supports; without them the WiZ-standard
 * defaults (`DIMMING_MIN`, `TEMP_MIN`/`TEMP_MAX`) apply.
 *
 * @param {LightState} state
 * @param {{ dimMin?: number, tempMin?: number, tempMax?: number }} [bounds]
 * @returns {Record<string, number|boolean>}
 */
export function buildSetPilotParams(state, bounds = {}) {
  if (!state.on) return { state: false };

  const dimMin = bounds.dimMin ?? DIMMING_MIN;
  const tempMin = bounds.tempMin ?? TEMP_MIN;
  const tempMax = bounds.tempMax ?? TEMP_MAX;

  const params = { state: true, dimming: clampInt(state.brightness, dimMin, DIMMING_MAX) };
  if (state.mode === 'white') {
    params.temp = clampInt(state.temp, tempMin, tempMax);
  } else {
    const [r, g, b] = clampRgb(state.rgb);
    Object.assign(params, { r, g, b });
  }
  return params;
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
 * A short, human capability summary derived from a `getModelConfig` result —
 * e.g. `"RGB + tunable white 2700–6500 K"`. Read entirely from what the device
 * reports: the count of *active* PWM channels (`pwmRanges`, pairs of `[lo, hi]`),
 * the white-channel count (`nowc`), and the white range (`cctRange`, via
 * {@link deviceBoundsFromConfig}). Three or more active channels means colour (a
 * white-only light has at most two: cool + warm), so we never claim a capability
 * the device doesn't expose. Returns `''` when nothing is determinable.
 *
 * @param {Record<string, unknown>|null|undefined} modelConfig
 * @returns {string}
 */
export function describeDevice(modelConfig) {
  if (!modelConfig || typeof modelConfig !== 'object') return '';
  const { tempMin, tempMax } = deviceBoundsFromConfig(modelConfig);

  // Count active PWM channels — pairs [lo, hi] with hi > lo — ignoring padding.
  const pwm = Array.isArray(modelConfig.pwmRanges) ? modelConfig.pwmRanges : [];
  let channels = 0;
  for (let i = 0; i + 1 < pwm.length; i += 2) {
    if (Number(pwm[i + 1]) > Number(pwm[i])) channels += 1;
  }
  const whiteChannels = Number(modelConfig.nowc);

  const hasRgb = channels >= 3;
  const hasRange = Number.isFinite(tempMin) && Number.isFinite(tempMax) && tempMin < tempMax;
  const hasTunableWhite = hasRange || whiteChannels >= 2;
  const hasWhite = hasTunableWhite || Number.isFinite(tempMin) || whiteChannels >= 1;

  const parts = [];
  if (hasRgb) parts.push('RGB');
  if (hasTunableWhite) {
    parts.push(hasRange ? `tunable white ${tempMin}–${tempMax} K` : 'tunable white');
  } else if (hasWhite) {
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

/** Apply a preset on top of a state, returning a new state. */
export function applyPreset(state, preset) {
  const brightness = clampBrightness(preset.brightness ?? state.brightness);
  if (preset.mode === 'white') {
    return { ...state, on: true, mode: 'white', temp: clampTemp(preset.temp), brightness };
  }
  return {
    ...state,
    on: true,
    mode: 'rgb',
    rgb: clampRgb([preset.r, preset.g, preset.b]),
    brightness,
  };
}

/** True when `state` already reflects `preset` (used to highlight the active preset). */
export function stateMatchesPreset(state, preset) {
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
