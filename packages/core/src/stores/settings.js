import path from 'node:path';
import { readJson, writeJson } from '../json-file.js';
import { normalizeHex } from '../validate.js';

export const DEFAULT_SETTINGS = Object.freeze({
  accent: '#7b2cbf',
  highlight: '#590a9d',
  autoSync: true,
});

/** Persisted UI settings: accent colour, active-preset highlight, auto-sync toggle. */
export function createSettingsStore(dir) {
  const file = path.join(dir, 'settings.json');
  return {
    file,
    async load() {
      const data = await readJson(file, {});
      return {
        accent: normalizeHex(data.accent, DEFAULT_SETTINGS.accent),
        highlight: normalizeHex(data.highlight, DEFAULT_SETTINGS.highlight),
        autoSync: data.autoSync === undefined ? DEFAULT_SETTINGS.autoSync : Boolean(data.autoSync),
      };
    },
    save(settings) {
      return writeJson(file, {
        accent: normalizeHex(settings.accent, DEFAULT_SETTINGS.accent),
        highlight: normalizeHex(settings.highlight, DEFAULT_SETTINGS.highlight),
        autoSync: Boolean(settings.autoSync),
      });
    },
  };
}
