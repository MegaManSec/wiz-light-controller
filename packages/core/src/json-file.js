// Small, corruption-tolerant persistence helpers. Reads never throw (a missing
// or malformed file yields the caller's fallback); writes are atomic (write to a
// temp file, then rename) so a crash mid-write can't truncate good data.

import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import path from 'node:path';

async function atomicWrite(file, contents) {
  await mkdir(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(tmp, contents, 'utf8');
  await rename(tmp, file);
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
