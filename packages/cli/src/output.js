// Minimal ANSI colour helpers — no `chalk` dependency. Styling collapses to a
// no-op when stdout isn't a TTY or `NO_COLOR` is set, so piped/redirected output
// stays clean and machine-parseable.

/** True when it's safe to emit ANSI escapes. */
export const colorEnabled = Boolean(process.stdout.isTTY) && !('NO_COLOR' in process.env);

const wrap = (open, close) => (text) =>
  colorEnabled ? `[${open}m${text}[${close}m` : String(text);

export const bold = wrap(1, 22);
export const dim = wrap(2, 22);
export const red = wrap(31, 39);
export const green = wrap(32, 39);
export const yellow = wrap(33, 39);
export const cyan = wrap(36, 39);
export const gray = wrap(90, 39);

/** A filled swatch in 24-bit colour, or `''` when colour is off — callers print
 *  the hex label alongside (and skip the empty fragment when composing). */
export function swatch([r, g, b]) {
  if (!colorEnabled) return '';
  return `[48;2;${r};${g};${b}m  [49m`;
}

/** Write a line to stdout. */
export const print = (line = '') => process.stdout.write(`${line}\n`);

/** Write a line to stderr. */
export const printErr = (line = '') => process.stderr.write(`${line}\n`);
