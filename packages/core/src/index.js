// Public surface of wiz-light-core. Pure engine: no UI, no globals, no runtime deps.

export * from './color.js';
export * from './validate.js';
export * from './model.js';
export * from './protocol.js';
export * from './discovery.js';
export { appDataDir } from './paths.js';

export { createSettingsStore, DEFAULT_SETTINGS } from './stores/settings.js';
export { createPresetsStore } from './stores/presets.js';
export { createSavedLightsStore } from './stores/saved-lights.js';
export { createLastStateStore } from './stores/last-state.js';

import { appDataDir } from './paths.js';
import { createSettingsStore } from './stores/settings.js';
import { createPresetsStore } from './stores/presets.js';
import { createSavedLightsStore } from './stores/saved-lights.js';
import { createLastStateStore } from './stores/last-state.js';

/** Build every persistence store rooted at one directory (defaults to {@link appDataDir}). */
export function createStores(dir = appDataDir()) {
  return {
    dir,
    settings: createSettingsStore(dir),
    presets: createPresetsStore(dir),
    savedLights: createSavedLightsStore(dir),
    lastState: createLastStateStore(dir),
  };
}
