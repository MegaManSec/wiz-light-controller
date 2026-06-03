#!/usr/bin/env node
// Generate Conventional-Commit release notes for the range <prevTag>..HEAD and
// print them to stdout. Pure Node, zero dependencies — the release workflow runs
// it as `node scripts/release-notes.mjs > RELEASE_NOTES.md`.
//
// This project publishes on an explicit `package.json` version bump (see
// .github/workflows/release.yml), not on commit-derived versioning. So this
// script is purely a changelog: it reads the current version from package.json,
// finds the previous `vX.Y.Z` tag reachable from HEAD, lists the commits in
// between, and groups their Conventional-Commit subjects into Markdown sections.
//
// It is deliberately tolerant: if git is missing, there is no repository, or
// there are no tags yet (the first release), it still emits sensible notes over
// whatever history is available rather than failing the release.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const ROOT_PKG = new URL('../package.json', import.meta.url);

/**
 * Run a git command and return trimmed stdout, or `null` if git is unavailable
 * or the command fails (e.g. not a repo, unknown ref). Never throws.
 */
function git(args) {
  try {
    return execFileSync('git', args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    return null;
  }
}

/** Current version from the root package.json (the release's version). */
function currentVersion() {
  try {
    return JSON.parse(readFileSync(ROOT_PKG, 'utf8')).version ?? '0.0.0';
  } catch {
    return '0.0.0';
  }
}

/**
 * Most recent `vX.Y.Z` tag reachable from HEAD. The next tag isn't created yet,
 * so this resolves to the previous release. Falls back to listing tags by
 * version when `git describe` can't find one. Returns `null` when there are no
 * tags at all (first release) or git is unavailable.
 */
function previousTag() {
  const described = git(['describe', '--tags', '--abbrev=0', '--match', 'v*']);
  if (described) return described;

  // No annotated/reachable tag found via describe — try a version-sorted list,
  // which also covers lightweight tags and detached states.
  const listed = git(['tag', '--list', 'v*', '--sort=-v:refname']);
  if (!listed) return null;
  const [first] = listed.split('\n').filter(Boolean);
  return first ?? null;
}

// Conventional-Commit types we surface, in render order. Everything else
// (chore, ci, test, build, style, revert, unknown types) is folded into
// "Other" — release notes stay focused on user-facing change.
const SECTIONS = [
  ['feat', 'Features'],
  ['fix', 'Bug Fixes'],
  ['perf', 'Performance'],
  ['docs', 'Documentation'],
  ['refactor', 'Refactoring'],
];
const KNOWN_TYPES = new Set(SECTIONS.map(([type]) => type));
const OTHER = 'Other';

// `type(optional scope)!: subject` — `!` marks a breaking change.
const HEADER = /^(?<type>[a-z]+)(?:\((?<scope>[^)]+)\))?(?<breaking>!)?:\s+(?<subject>.+)$/;

/**
 * Parse one commit's `hash` + `subject` line into a categorised entry. Anything
 * that isn't one of the surfaced Conventional-Commit types lands under "Other".
 */
function categorise(hash, subject) {
  const m = HEADER.exec(subject);
  if (!m) return { section: OTHER, scope: null, breaking: false, text: subject, hash };
  const { type, scope, breaking } = m.groups;
  const section = KNOWN_TYPES.has(type) ? type : OTHER;
  return {
    section,
    scope: scope ?? null,
    breaking: Boolean(breaking),
    text: m.groups.subject,
    hash,
  };
}

/** Render a single bullet: `- **scope:** subject (abcdef0)`, breaking marked. */
function bullet(entry) {
  const scope = entry.scope ? `**${entry.scope}:** ` : '';
  const flag = entry.breaking ? '**BREAKING** ' : '';
  const short = entry.hash ? ` (${entry.hash.slice(0, 7)})` : '';
  return `- ${flag}${scope}${entry.text}${short}`;
}

function main() {
  const version = currentVersion();
  const nextTag = `v${version}`;
  const prevTag = previousTag();
  const range = prevTag ? `${prevTag}..HEAD` : 'HEAD';

  // Field/record separators are control chars (US / RS) that can't appear in a
  // commit subject, so the split is unambiguous even with odd commit text. We
  // only need the abbreviated hash and the subject (first line) here.
  const FIELD = '\x1f';
  const RECORD = '\x1e';
  const raw = git(['log', `--format=%H${FIELD}%s${RECORD}`, range]);

  const entries =
    raw === null
      ? []
      : raw
          .split(RECORD)
          .map((record) => record.replace(/^\s+/, ''))
          .filter(Boolean)
          .map((record) => {
            const [hash, subject = ''] = record.split(FIELD);
            return categorise(hash, subject.trim());
          });

  const lines = [`## ${nextTag}`, ''];

  if (prevTag) {
    lines.push(`Changes since ${prevTag}.`, '');
  } else {
    lines.push('Initial release.', '');
  }

  if (entries.length === 0) {
    lines.push('_No commits found for this release._', '');
  } else {
    const order = [...SECTIONS, [OTHER, OTHER]];
    for (const [key, heading] of order) {
      const inSection = entries.filter((e) => e.section === key);
      if (inSection.length === 0) continue;
      lines.push(`### ${heading}`, '');
      for (const entry of inSection) lines.push(bullet(entry));
      lines.push('');
    }
  }

  process.stdout.write(`${lines.join('\n').trimEnd()}\n`);
}

main();
