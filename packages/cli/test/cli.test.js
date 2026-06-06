// Unit tests for the CLI's pure helpers — the pieces that don't touch the
// network or `wiz-light-core`, so they run standalone before the workspace install.
// Command handlers and the entry point import `wiz-light-core` and are covered by the
// lead's post-install smoke test instead.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { compareVersions, isNewer } from '../src/update-check.js';
import { swatch, bold, colorEnabled } from '../src/output.js';
import { topLevelHelp, commandHelp, COMMANDS, USAGE } from '../src/help.js';

test('compareVersions orders numerically, not lexically', () => {
  assert.equal(compareVersions('1.2.0', '1.10.0'), -1);
  assert.equal(compareVersions('2.0.0', '1.9.9'), 1);
  assert.equal(compareVersions('1.0.0', '1.0.0'), 0);
});

test('compareVersions strips a leading v and tolerates short versions', () => {
  assert.equal(compareVersions('v1.2.3', '1.2.3'), 0);
  assert.equal(compareVersions('1.2', '1.2.0'), 0);
  assert.equal(compareVersions('1.3', '1.2.9'), 1);
});

test('compareVersions ignores pre-release / build suffixes on a segment', () => {
  assert.equal(compareVersions('1.2.0-rc.1', '1.2.0'), 0);
  assert.equal(compareVersions('1.2.0+build5', '1.2.0'), 0);
});

test('isNewer is strict', () => {
  assert.equal(isNewer('1.0.1', '1.0.0'), true);
  assert.equal(isNewer('1.0.0', '1.0.0'), false);
  assert.equal(isNewer('0.9.9', '1.0.0'), false);
  assert.equal(isNewer('v0.2.0', '0.1.0'), true);
});

test('output helpers degrade to plain text when colour is disabled', () => {
  // In the test runner stdout is not a TTY, so colour is off and helpers no-op.
  assert.equal(colorEnabled, false);
  assert.equal(bold('hi'), 'hi');
  assert.equal(swatch([255, 0, 0]), '');
});

test('help text lists every command and its usage', () => {
  const top = topLevelHelp();
  assert.match(top, new RegExp(USAGE.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  for (const name of Object.keys(COMMANDS)) {
    assert.match(top, new RegExp(`\\b${name}\\b`), `top-level help mentions ${name}`);
  }
});

test('commandHelp renders a command’s usage, and falls back for unknown names', () => {
  assert.match(commandHelp('color'), /wiz color/);
  // status advertises its `sync` alias
  assert.match(commandHelp('status'), /sync/);
  // scene(s) document their usage + the speed flag
  assert.match(commandHelp('scene'), /wiz scene .*<name\|id>/);
  assert.match(commandHelp('scene'), /--speed/);
  assert.match(commandHelp('scenes'), /wiz scenes/);
  // unknown → top-level help
  assert.equal(commandHelp('nope'), topLevelHelp());
});
