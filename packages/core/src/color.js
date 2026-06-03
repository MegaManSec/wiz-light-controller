// Colour maths for the WiZ controller. All conversions are pure and side-effect
// free so they can be shared verbatim between the engine, the CLI, and the
// browser renderer. RGB channels are integers in [0, 255]; HSV components are
// floats in [0, 1]. Ported from the original `colorsys`-based Python.

/** Inclusive white-temperature range supported by WiZ bulbs, in Kelvin. */
export const TEMP_MIN = 2200;
export const TEMP_MAX = 6500;

const clampByte = (n) => Math.max(0, Math.min(255, Math.round(n)));

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
