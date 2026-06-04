// Failure-tolerant GitHub-releases update notice. Runs at most once a day, never
// delays the command (fire-and-forget with a 2s abort), and stays completely
// silent on any error or when offline. Opt out with WIZ_NO_UPDATE_CHECK.

import path from 'node:path';
import { readJson, writeJson } from './json-file.js';
import { dim, printErr } from './output.js';

// GitHub repo the update check polls. Matches the package `repository` field and
// the git remote.
const REPO = 'MegaManSec/wiz-light-controller';
const RELEASES_URL = `https://api.github.com/repos/${REPO}/releases/latest`;

const DAY_MS = 24 * 60 * 60 * 1000;
const FETCH_TIMEOUT_MS = 2000;
const CACHE_FILE = 'update-check.json';

/**
 * Compare two dot-separated version strings numerically. Returns 1 if `a > b`,
 * -1 if `a < b`, 0 if equal. Pre-release/build suffixes on a segment are dropped
 * (so `1.2.0-rc.1` compares as `1.2.0`); missing segments count as 0.
 */
export function compareVersions(a, b) {
  // Drop a leading `v` and any pre-release/build suffix, then compare segments.
  const parts = (v) =>
    String(v)
      .replace(/^v/, '')
      .split(/[-+]/, 1)[0]
      .split('.')
      .map((s) => parseInt(s, 10) || 0);
  const pa = parts(a);
  const pb = parts(b);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i += 1) {
    const da = pa[i] ?? 0;
    const db = pb[i] ?? 0;
    if (da > db) return 1;
    if (da < db) return -1;
  }
  return 0;
}

/** True when `latest` is a strictly newer version than `current`. */
export const isNewer = (latest, current) => compareVersions(latest, current) > 0;

async function fetchLatestTag(signal) {
  // Cap the request at FETCH_TIMEOUT_MS, but also honour a caller's signal so the
  // entry point can cancel the moment the command finishes (freeing the loop).
  const timeout = AbortSignal.timeout(FETCH_TIMEOUT_MS);
  const res = await fetch(RELEASES_URL, {
    headers: { 'User-Agent': 'wiz-cli', Accept: 'application/vnd.github+json' },
    signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
  });
  // Throw (not return null) so a non-OK response counts as a failed check: the
  // caller then won't record the 24h throttle, and retries on the next run.
  if (!res.ok) throw new Error(`GitHub update check failed: HTTP ${res.status}`);
  const body = await res.json();
  return typeof body?.tag_name === 'string' ? body.tag_name : null;
}

/**
 * Kick off a background update check. Resolves to a notice string when a newer
 * release exists (and prints it to stderr by default), or `null` otherwise.
 * Swallows every error — a broken check must never affect the command.
 *
 * @param {Object} opts
 * @param {string} opts.version    The current package version.
 * @param {string} [opts.dir]      App data dir for the throttle cache.
 * @param {boolean} [opts.emit]    Print the notice to stderr (default true).
 * @param {AbortSignal} [opts.signal]  Cancels the in-flight network request.
 */
export async function checkForUpdate({ version, dir, emit = true, signal }) {
  if (process.env.WIZ_NO_UPDATE_CHECK) return null;
  try {
    const cacheFile = dir ? path.join(dir, CACHE_FILE) : null;
    const cache = cacheFile ? await readJson(cacheFile, {}) : {};
    if (cache.lastCheck && Date.now() - cache.lastCheck < DAY_MS) return null;

    const tag = await fetchLatestTag(signal);
    // Record the 24h throttle only after a check that actually reached GitHub —
    // fetchLatestTag throws on network/HTTP failure (caught below), so a
    // transient outage is retried on the next run instead of silencing the check
    // for a full day. (Mirrors the macOS app's UpdateChecker.)
    if (cacheFile) await writeJson(cacheFile, { lastCheck: Date.now() }).catch(() => {});
    if (!tag || !isNewer(tag, version)) return null;

    const latest = tag.replace(/^v/, '');
    const notice = dim(`A new version of wiz is available: ${version} → ${latest}`);
    if (emit) printErr(notice);
    return notice;
  } catch {
    return null;
  }
}
