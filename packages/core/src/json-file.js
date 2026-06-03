// Small, corruption-tolerant persistence helpers. Reads never throw (a missing
// or malformed file yields the caller's fallback); writes are atomic (write to a
// temp file, then rename) so a crash mid-write can't truncate good data.

import { mkdir, readFile, writeFile, rename, unlink } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';

async function atomicWrite(file, contents) {
  await mkdir(path.dirname(file), { recursive: true });
  // Unique per write — `pid.timestamp` collides for two same-millisecond writes to
  // one file, so the loser's rename would hit ENOENT. Clean up a leftover temp if
  // the rename fails, so a failed write can't litter the data dir.
  const tmp = `${file}.${randomUUID()}.tmp`;
  try {
    await writeFile(tmp, contents, 'utf8');
    await rename(tmp, file);
  } catch (err) {
    await unlink(tmp).catch(() => {});
    throw err;
  }
}

export async function readJson(file, fallback) {
  try {
    return JSON.parse(await readFile(file, 'utf8'));
  } catch {
    return fallback;
  }
}

export function writeJson(file, data) {
  return atomicWrite(file, `${JSON.stringify(data, null, 2)}\n`);
}

export async function readText(file, fallback = '') {
  try {
    return (await readFile(file, 'utf8')).trim();
  } catch {
    return fallback;
  }
}

export function writeText(file, text) {
  return atomicWrite(file, String(text));
}
