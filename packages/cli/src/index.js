#!/usr/bin/env node
// wiz — command-line controller for Philips WiZ lights.
//
// Thin entry point: parse argv, dispatch to a command handler, and render any
// error centrally. A best-effort update check runs in the background and can
// never delay or break the command.

import { parseArgs } from 'node:util';
import { createStores, appDataDir } from 'wiz-light-core';

import { handlers, resolveCommand, CliError } from './commands.js';
import { topLevelHelp, commandHelp } from './help.js';
import { checkForUpdate } from './update-check.js';
import { red, dim, printErr, print } from './output.js';

import pkg from '../package.json' with { type: 'json' };

// Union of every command's options. Unknown flags are tolerated (strict: false)
// so a stray flag yields a friendly error path rather than a parser stack trace.
const OPTIONS = {
  help: { type: 'boolean', short: 'h' },
  version: { type: 'boolean', short: 'V' },
  json: { type: 'boolean' },
  brightness: { type: 'string' },
  timeout: { type: 'string' },
  attempts: { type: 'string' },
};

function parse(argv) {
  return parseArgs({ args: argv, options: OPTIONS, allowPositionals: true, strict: false });
}

async function main(argv) {
  const { values, positionals } = parse(argv);
  const [command, ...rest] = positionals;

  if (values.version) {
    print(pkg.version);
    return;
  }

  // `wiz`, `wiz --help`, or `wiz <cmd> --help`.
  if (!command || (values.help && !resolveCommand(command))) {
    print(topLevelHelp());
    return;
  }

  const canonical = resolveCommand(command);
  if (!canonical) {
    printErr(red(`Unknown command: ${command}`));
    printErr(dim('Run `wiz --help` to see available commands.'));
    process.exitCode = 1;
    return;
  }
  if (values.help) {
    print(commandHelp(canonical));
    return;
  }

  // Fire-and-forget update check. It prints its own one-line notice if needed;
  // we never await the network, so the command's latency is unaffected.
  const updatePromise = checkForUpdate({ version: pkg.version, dir: appDataDir() }).catch(() => {});

  const stores = createStores();
  await handlers[canonical]({ positionals: rest, values, stores });

  // Give an already-settled check one tick to flush its notice; never wait on the
  // network. flushAndExit() then tears the process down so the still-pending fetch
  // (whose abort timer would otherwise hold the loop ~2s) can't delay exit.
  await Promise.race([updatePromise, new Promise((r) => setImmediate(r))]);
}

/** Drain a writable stream's buffer, resolving once it's safe to exit. */
function drain(stream) {
  return stream.writableLength === 0
    ? Promise.resolve()
    : new Promise((resolve) => stream.once('drain', resolve));
}

/** Flush stdout/stderr, then exit — so a backgrounded fetch can't stall shutdown. */
async function flushAndExit() {
  await Promise.all([drain(process.stdout), drain(process.stderr)]);
  process.exit(process.exitCode ?? 0);
}

main(process.argv.slice(2))
  .catch((err) => {
    // CliError carries a user-facing message; anything else is unexpected.
    const message = err instanceof CliError ? err.message : (err?.message ?? String(err));
    printErr(red(`Error: ${message}`));
    process.exitCode = 1;
  })
  .finally(flushAndExit);
