// Input validation and normalisation. These guard every value that reaches the
// network or persisted state, and replace the original's scattered, partial
// checks (e.g. unbounded brightness, no IP validation).

import { TEMP_MIN, TEMP_MAX } from './color.js';

/** Lowest `dimming` a WiZ bulb accepts; values below this are ignored by firmware. */
export const DIMMING_MIN = 10;
export const DIMMING_MAX = 100;

const octet = '(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)';
const IPV4 = new RegExp(`^${octet}(\\.${octet}){3}$`);

/** True for a dotted-quad IPv4 literal. WiZ is addressed by LAN IP only. */
export function isValidIp(value) {
  return typeof value === 'string' && IPV4.test(value.trim());
}

/** True for a 6-digit hex colour, with or without a leading `#`. */
export function isValidHex(value) {
  return typeof value === 'string' && /^#?[0-9a-f]{6}$/i.test(value.trim());
}

/** Return a clean `"#rrggbb"` (lower-case) or `fallback` when `value` is invalid. */
export function normalizeHex(value, fallback) {
  if (!isValidHex(value)) return fallback;
  const v = value.trim();
  return `#${(v.startsWith('#') ? v.slice(1) : v).toLowerCase()}`;
}

/** Format a bare 12-hex-digit MAC as `AA:BB:CC:DD:EE:FF`; pass anything else through. */
export function formatMac(mac) {
  if (typeof mac !== 'string' || !/^[0-9a-f]{12}$/i.test(mac)) return mac;
  return mac.match(/.{2}/g).join(':').toUpperCase();
}

export function clampInt(n, lo, hi) {
  const v = Math.round(Number(n));
  if (Number.isNaN(v)) return lo;
  return Math.max(lo, Math.min(hi, v));
}

/** Clamp a UI brightness percentage to [0, 100]. */
export const clampBrightness = (n) => clampInt(n, 0, 100);

/** Clamp a colour temperature to the WiZ-supported Kelvin range. */
export const clampTemp = (k) => clampInt(k, TEMP_MIN, TEMP_MAX);

/** Dynamic-scene animation speed band the bulb meaningfully honours. */
export const SPEED_MIN = 10;
export const SPEED_MAX = 200;

/** Clamp a dynamic-scene speed to the meaningful [10, 200] band. */
export const clampSpeed = (n) => clampInt(n, SPEED_MIN, SPEED_MAX);

/**
 * Convert a 0–100 brightness percentage to a wire `dimming` value, clamped to
 * the firmware-accepted [10, 100] band. (The original sent 0–100 verbatim, so a
 * brightness of 0–9 was silently dropped by the bulb.)
 */
export const toDimming = (brightness) => clampInt(brightness, DIMMING_MIN, DIMMING_MAX);

/** Clamp an RGB triple to integer [0, 255] channels. */
export const clampRgb = (rgb) => rgb.map((c) => clampInt(c, 0, 255));
