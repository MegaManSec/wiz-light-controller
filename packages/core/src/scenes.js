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

/** Scenes that render on a white-only (no colour LEDs) bulb. Everything else needs RGB. */
const WHITE_SCENE_IDS = new Set([6, 9, 10, 11, 12, 13, 14, 29, 30]);

/** Scene id → name, or `null` for an unknown / out-of-range id (incl. 0 = "no scene"). */
export function sceneName(id) {
  return SCENES[id] ?? null;
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
 * @returns {{ id: number, name: string }[]}
 */
export function scenesForDevice(modelConfig) {
  const { rgb, white } = deviceCapabilities(modelConfig);
  const whiteOnly = white && !rgb;
  return Object.entries(SCENES)
    .filter(([id]) => !whiteOnly || WHITE_SCENE_IDS.has(Number(id)))
    .map(([id, name]) => ({ id: Number(id), name }));
}
