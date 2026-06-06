// Dynamic-scene catalogue. WiZ bulbs run these animations in firmware; `getPilot`
// reports only the numeric `sceneId` — never a name — so the id↔name mapping is a
// fixed convention (matching pywizlight / the official app), not device-reported.
// IDs 1–32 are the validated, named set; the firmware accepts higher numbers but
// they aren't confirmed scenes, so we don't list them. No Node built-ins.

import { deviceCapabilities } from './model.js';

/** @type {Readonly<Record<number, string>>} */
export const SCENES = Object.freeze({
  1: 'Ocean',
  2: 'Romance',
  3: 'Sunset',
  4: 'Party',
  5: 'Fireplace',
  6: 'Cozy',
  7: 'Forest',
  8: 'Pastel Colors',
  9: 'Wake-up',
  10: 'Bedtime',
  11: 'Warm White',
  12: 'Daylight',
  13: 'Cool White',
  14: 'Night Light',
  15: 'Focus',
  16: 'Relax',
  17: 'True Colors',
  18: 'TV Time',
  19: 'Plantgrowth',
  20: 'Spring',
  21: 'Summer',
  22: 'Fall',
  23: 'Deepdive',
  24: 'Jungle',
  25: 'Mojito',
  26: 'Club',
  27: 'Christmas',
  28: 'Halloween',
  29: 'Candlelight',
  30: 'Golden White',
  31: 'Pulse',
  32: 'Steampunk',
});

/**
 * Short, human descriptions of each scene's colours/effect, for tooltips and the
 * CLI listing. **Approximate** — the bulb never reports them and the colour data
 * isn't published; these mirror the WiZ app's visual scenes, so treat them as a
 * hint, not a spec.
 * @type {Readonly<Record<number, string>>}
 */
export const SCENE_HINTS = Object.freeze({
  1: 'Rolling blues and teals',
  2: 'Soft warm pinks and reds',
  3: 'Orange → pink → purple fade',
  4: 'Fast multicolour cycle',
  5: 'Flickering warm orange',
  6: 'Dim, cosy warm white',
  7: 'Gentle shifting greens',
  8: 'Soft drifting pastels',
  9: 'Slowly brightens, warm → cool',
  10: 'Slowly dims to warm',
  11: 'Steady warm white',
  12: 'Neutral daylight white',
  13: 'Crisp cool white',
  14: 'Very dim warm glow',
  15: 'Bright, cool focus white',
  16: 'Soft, calm warm white',
  17: 'Saturated colour cycle',
  18: 'Muted ambient backlight',
  19: 'Magenta/pink grow light',
  20: 'Fresh greens and pastels',
  21: 'Warm, vivid summer hues',
  22: 'Ambers and deep oranges',
  23: 'Deep ocean blues',
  24: 'Greens and warm yellows',
  25: 'Lime and mint greens',
  26: 'Bold pulsing club colours',
  27: 'Festive red and green',
  28: 'Eerie orange and purple',
  29: 'Warm candle flicker',
  30: 'Warm golden white',
  31: 'Single colour, pulsing',
  32: 'Warm amber and brass',
});

/** Scenes that render on a white-only (no colour LEDs) bulb. Everything else needs RGB. */
const WHITE_SCENE_IDS = new Set([6, 9, 10, 11, 12, 13, 14, 29, 30]);

/** Scene id → name, or `null` for an unknown / out-of-range id (incl. 0 = "no scene"). */
export function sceneName(id) {
  return SCENES[id] ?? null;
}

/** Scene id → short description (see {@link SCENE_HINTS}), or `''` if unknown. */
export function sceneHint(id) {
  return SCENE_HINTS[id] ?? '';
}

/**
 * Resolve a user-supplied scene reference — a numeric id (number or string) or a
 * name (case-insensitive) — to `{ id, name }`, or `null` if it matches nothing.
 *
 * @param {number|string|null|undefined} nameOrId
 * @returns {{ id: number, name: string }|null}
 */
export function findScene(nameOrId) {
  if (nameOrId == null) return null;

  const asNum = Number(nameOrId);
  if (Number.isInteger(asNum) && SCENES[asNum]) return { id: asNum, name: SCENES[asNum] };

  if (typeof nameOrId === 'string') {
    const needle = nameOrId.trim().toLowerCase();
    for (const [id, name] of Object.entries(SCENES)) {
      if (name.toLowerCase() === needle) return { id: Number(id), name };
    }
  }
  return null;
}

/**
 * The scenes a given device can show, derived from its `getModelConfig` via
 * {@link deviceCapabilities}: an RGB bulb gets all of them; a *positively*
 * white-only bulb gets just the white-capable subset; when capabilities can't be
 * determined we stay permissive and return everything.
 *
 * @param {Record<string, unknown>|null|undefined} modelConfig
 * @returns {{ id: number, name: string, hint: string }[]}
 */
export function scenesForDevice(modelConfig) {
  const { rgb, white } = deviceCapabilities(modelConfig);
  const whiteOnly = white && !rgb;
  return Object.entries(SCENES)
    .filter(([id]) => !whiteOnly || WHITE_SCENE_IDS.has(Number(id)))
    .map(([id, name]) => ({ id: Number(id), name, hint: SCENE_HINTS[id] ?? '' }));
}
