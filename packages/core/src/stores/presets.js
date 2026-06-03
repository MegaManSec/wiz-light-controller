import path from 'node:path';
import { readJson, writeJson } from '../json-file.js';
import { DEFAULT_PRESETS } from '../model.js';

const cloneDefaults = () => structuredClone(DEFAULT_PRESETS);

/** Persisted RGB and white presets, seeded with {@link DEFAULT_PRESETS}. */
export function createPresetsStore(dir) {
  const file = path.join(dir, 'presets.json');
  return {
    file,
    async load() {
      const data = await readJson(file, null);
      if (!data || typeof data !== 'object') return cloneDefaults();
      return { rgb: data.rgb ?? {}, white: data.white ?? {} };
    },
    save(presets) {
      return writeJson(file, presets);
    },
  };
}
