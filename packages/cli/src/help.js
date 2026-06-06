// Help and usage text. Kept declarative so the top-level listing and the
// per-command `--help` output never drift from one source.

import { bold, dim, cyan } from './output.js';

export const USAGE = 'wiz <command> [args] [options]';

/**
 * Command catalogue: summary for the top-level list plus a detailed usage block
 * for `wiz <command> --help`. `<ip>` is optional everywhere — it falls back to
 * the last-used bulb when omitted.
 */
export const COMMANDS = {
  discover: {
    summary: 'Find WiZ bulbs on the local network',
    usage: 'wiz discover [--timeout <ms>] [--attempts <n>] [--json]',
    details: [
      'Broadcasts on the LAN and lists every bulb that answers.',
      '',
      '  --timeout <ms>    Listen window per attempt (default 2000)',
      '  --attempts <n>    Number of broadcasts (default 3)',
      '  --json            Print machine-readable JSON',
    ],
  },
  status: {
    summary: 'Show a bulb’s current state',
    aliases: ['sync'],
    usage: 'wiz status [<ip>]',
    details: ['Queries the bulb and prints power, mode, colour/temperature and brightness.'],
  },
  on: {
    summary: 'Turn a bulb on',
    usage: 'wiz on [<ip>]',
  },
  off: {
    summary: 'Turn a bulb off',
    usage: 'wiz off [<ip>]',
  },
  color: {
    summary: 'Set an RGB colour',
    usage: 'wiz color [<ip>] <#rrggbb | r g b> [--brightness <0-100>]',
    details: [
      'Accepts a hex string or three 0-255 channel values.',
      '',
      '  --brightness <0-100>   Brightness percent (default 100)',
      '',
      'Examples:',
      '  wiz color 10.0.0.5 #ff8800',
      '  wiz color 10.0.0.5 255 136 0 --brightness 60',
    ],
  },
  temp: {
    summary: 'Set a white colour temperature',
    usage: 'wiz temp [<ip>] <kelvin> [--brightness <0-100>]',
    details: ['Kelvin is clamped to the WiZ range (2200-6500).'],
  },
  brightness: {
    summary: 'Set brightness, preserving colour',
    usage: 'wiz brightness [<ip>] <0-100>',
    details: ['Reads the current colour/mode first so only brightness changes.'],
  },
  presets: {
    summary: 'List saved presets',
    usage: 'wiz presets [--json]',
  },
  preset: {
    summary: 'Apply a named preset',
    usage: 'wiz preset [<ip>] <name> [--brightness <0-100>]',
    details: ['Looks the name up across the RGB and white preset groups.'],
  },
  scenes: {
    summary: 'List the bulb’s dynamic scenes',
    usage: 'wiz scenes [<ip>] [--json]',
    details: [
      'Lists the built-in scenes by id. Given an <ip> (or a remembered bulb), shows',
      'only the scenes that bulb supports; otherwise lists them all.',
    ],
  },
  scene: {
    summary: 'Run a dynamic scene',
    usage: 'wiz scene [<ip>] <name|id> [--speed <1-100>] [--brightness <0-100>]',
    details: [
      'Accepts a scene name (case-insensitive) or its id — see `wiz scenes`.',
      '',
      '  --speed <1-100>       Animation speed (default: keep the bulb’s current)',
      '  --brightness <0-100>   Brightness percent',
      '',
      'Examples:',
      '  wiz scene 10.0.0.5 party --speed 120',
      '  wiz scene 10.0.0.5 4',
    ],
  },
  lights: {
    summary: 'List saved lights',
    usage: 'wiz lights [--json]',
  },
  save: {
    summary: 'Save a bulb by name',
    usage: 'wiz save [<ip>] <name>',
    details: ['Resolves the bulb’s MAC and stores it for later reference.'],
  },
};

function commandList() {
  const width = Math.max(...Object.keys(COMMANDS).map((name) => name.length));
  return Object.entries(COMMANDS)
    .map(([name, { summary }]) => `  ${cyan(name.padEnd(width))}  ${summary}`)
    .join('\n');
}

/** Top-level help shown for `wiz`, `wiz --help`, or an unknown command. */
export function topLevelHelp() {
  return [
    bold('wiz') + ' — control Philips WiZ lights from the terminal',
    '',
    bold('Usage'),
    `  ${USAGE}`,
    '',
    bold('Commands'),
    commandList(),
    '',
    bold('Options'),
    '  -h, --help       Show help (use `wiz <command> --help` for details)',
    '  -V, --version    Print the version',
    '',
    dim('An <ip> may be omitted to reuse the last bulb you talked to.'),
  ].join('\n');
}

/** Detailed help for one command, or the top-level help if it's unknown. */
export function commandHelp(name) {
  const entry = COMMANDS[name];
  if (!entry) return topLevelHelp();
  const lines = [bold(entry.summary), '', bold('Usage'), `  ${entry.usage}`];
  if (entry.aliases?.length) lines.push('', `${bold('Alias')}  ${entry.aliases.join(', ')}`);
  if (entry.details?.length) lines.push('', ...entry.details);
  return lines.join('\n');
}
