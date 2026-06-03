// Tiny, corruption-tolerant JSON persistence for CLI-local state (currently just
// the update-check throttle). Reads never throw; writes create the directory.
// Core owns the real stores — this is deliberately minimal and dependency-free.

import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

export async function readJson(file, fallback) {
  try {
    return JSON.parse(await readFile(file, 'utf8'));
  } catch {
    return fallback;
  }
}

export async function writeJson(file, data) {
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, `${JSON.stringify(data, null, 2)}\n`, 'utf8');
}
