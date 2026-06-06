// Colour maths for the WiZ controller. All conversions are pure and side-effect
// free so they can be shared verbatim between the engine, the CLI, and the
// browser renderer. RGB channels are integers in [0, 255]; HSV components are
// floats in [0, 1]. Ported from the original `colorsys`-based Python.

/** Inclusive white-temperature range supported by WiZ bulbs, in Kelvin. */
export const TEMP_MIN = 2200;
export const TEMP_MAX = 6500;

const clampByte = (n) => {
  const r = Math.round(n);
  return Number.isFinite(r) ? Math.max(0, Math.min(255, r)) : 0;
};

/**
 * Convert an `[r, g, b]` triple (0–255) to `[h, s, v]` (0–1).
 * Matches Python's `colorsys.rgb_to_hsv`.
 */
export function rgbToHsv([r, g, b]) {
  const rf = r / 255;
  const gf = g / 255;
  const bf = b / 255;
  const max = Math.max(rf, gf, bf);
  const min = Math.min(rf, gf, bf);
  const v = max;
  if (max === min) return [0, 0, v];

  const d = max - min;
  const s = d / max;
  const rc = (max - rf) / d;
  const gc = (max - gf) / d;
  const bc = (max - bf) / d;

  let h;
  if (rf === max) h = bc - gc;
  else if (gf === max) h = 2 + rc - bc;
  else h = 4 + gc - rc;

  h = (h / 6) % 1;
  if (h < 0) h += 1;
  return [h, s, v];
}

/**
 * Convert `[h, s, v]` (0–1) to an `[r, g, b]` triple (0–255).
 * Matches Python's `colorsys.hsv_to_rgb`.
 */
export function hsvToRgb([h, s, v]) {
  if (s === 0) {
    const c = clampByte(v * 255);
    return [c, c, c];
  }

  const i = Math.floor(h * 6) % 6;
  const f = h * 6 - Math.floor(h * 6);
  const p = v * (1 - s);
  const q = v * (1 - s * f);
  const t = v * (1 - s * (1 - f));

  const table = [
    [v, t, p],
    [q, v, p],
    [p, v, t],
    [p, q, v],
    [t, p, v],
    [v, p, q],
  ];
  const [rf, gf, bf] = table[(i + 6) % 6];
  return [clampByte(rf * 255), clampByte(gf * 255), clampByte(bf * 255)];
}

/** `[r, g, b]` → `"#rrggbb"` (lower-case). */
export function rgbToHex([r, g, b]) {
  const hex = (n) => clampByte(n).toString(16).padStart(2, '0');
  return `#${hex(r)}${hex(g)}${hex(b)}`;
}

/** `"#rrggbb"` (with or without `#`) → `[r, g, b]`, or `null` if malformed. */
export function hexToRgb(hex) {
  if (typeof hex !== 'string') return null;
  const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return null;
  const v = parseInt(m[1], 16);
  return [(v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
}

/**
 * Approximate the RGB appearance of a black-body temperature in Kelvin
 * (Tanner Helland's well-known fit). Good enough for UI gradients and the
 * brightness-tint source. Ported directly from the Python.
 */
export function kelvinToRgb(kelvin) {
  const t = kelvin / 100;
  let r;
  let g;
  let b;

  if (t <= 66) {
    r = 255;
    g = 99.4708025861 * Math.log(t) - 161.1195681661;
    b = t <= 19 ? 0 : 138.5177312231 * Math.log(t - 10) - 305.0447927307;
  } else {
    r = 329.698727446 * (t - 60) ** -0.1332047592;
    g = 288.1221695283 * (t - 60) ** -0.0755148492;
    b = 255;
  }

  return [clampByte(r), clampByte(g), clampByte(b)];
}

/**
 * Combined white-channel level (`c + w`) at which a colour washes fully to white.
 * Fit to the official WiZ app (≈280); see {@link perceivedRgb}.
 */
const WHITE_WASH_FULL = 280;

/**
 * Approximate the colour the eye sees from a bulb's full channel state. WiZ RGB
 * bulbs drive two white LEDs (`c` cool, `w` warm) on top of R/G/B. The official
 * app shows colour at full value (max channel = 255 — its hex "must contain FF")
 * with brightness on a separate control, and its white LEDs **wash the colour
 * toward white** (desaturate it) rather than tinting it. So this normalises the
 * rgb to full value, then blends toward white by `t = (c + w) / WHITE_WASH_FULL`;
 * cool and warm behave identically and simply add. With no white lit it returns
 * the rgb untouched (so colours we set ourselves are unaffected). Fit to — and
 * matching to ~1 level/channel — the WiZ iOS app across measured colours (FF658C,
 * 7D52FF, 52FFC1, FF6449, FF6DBF). Display-only — never send the result back to
 * the bulb, or the colour will drift.
 *
 * @param {[number, number, number]} rgb  chromatic channels (0–255)
 * @param {number} [c]  cool-white channel value (0–255)
 * @param {number} [w]  warm-white channel value (0–255)
 * @returns {[number, number, number]}
 */
export function perceivedRgb([r, g, b], c = 0, w = 0) {
  if (!c && !w) return [clampByte(r), clampByte(g), clampByte(b)];
  const max = Math.max(r, g, b, 1); // normalise the colour to full value (max → 255)
  const t = Math.min(1, (Math.max(0, c) + Math.max(0, w)) / WHITE_WASH_FULL);
  const wash = (chan) => ((chan / max) * (1 - t) + t) * 255;
  return [clampByte(wash(r)), clampByte(wash(g)), clampByte(wash(b))];
}

/**
 * Map a click at `(x, y)` on a square colour wheel of side `size` to hue and
 * saturation, or `null` when the point lies outside the wheel.
 */
export function wheelToHS(x, y, size) {
  const c = size / 2;
  const dx = x - c;
  const dy = y - c;
  const dist = Math.hypot(dx, dy);
  if (dist > c) return null;
  const hue = (Math.atan2(dy, dx) + Math.PI) / (2 * Math.PI);
  const sat = Math.min(1, dist / c);
  return { h: hue, s: sat };
}

/** Inverse of {@link wheelToHS}: the marker position for a given hue/sat. */
export function hsToWheel(h, s, size) {
  const c = size / 2;
  const r = s * c;
  const angle = h * 2 * Math.PI - Math.PI;
  return { x: c + Math.cos(angle) * r, y: c + Math.sin(angle) * r };
}
