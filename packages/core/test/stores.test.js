import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createSettingsStore, DEFAULT_SETTINGS } from '../src/stores/settings.js';
import { createPresetsStore } from '../src/stores/presets.js';
import { createSavedLightsStore } from '../src/stores/saved-lights.js';
import { createLastStateStore } from '../src/stores/last-state.js';
import { DEFAULT_PRESETS } from '../src/model.js';

let dir;
beforeEach(async () => {
  dir = await mkdtemp(path.join(os.tmpdir(), 'wiz-test-'));
});
afterEach(async () => {
  await rm(dir, { recursive: true, force: true });
});

const readRaw = (file) => readFile(file, 'utf8');

describe('stores: settings', () => {
  it('returns documented defaults when the file is missing', async () => {
    const store = createSettingsStore(dir);
    assert.deepEqual(await store.load(), DEFAULT_SETTINGS);
    assert.equal(store.file, path.join(dir, 'settings.json'));
  });

  it('round-trips a saved settings object, normalising hex', async () => {
    const store = createSettingsStore(dir);
    await store.save({ accent: '#AABBCC', highlight: 'DDEEFF', autoSync: false });
    assert.deepEqual(await store.load(), {
      accent: '#aabbcc',
      highlight: '#ddeeff',
      autoSync: false,
    });
  });

  it('falls back to default colours for invalid hex on load', async () => {
    const store = createSettingsStore(dir);
    await writeFile(
      store.file,
      JSON.stringify({ accent: 'nope', highlight: 12, autoSync: 1 }),
      'utf8',
    );
    const loaded = await store.load();
    assert.equal(loaded.accent, DEFAULT_SETTINGS.accent);
    assert.equal(loaded.highlight, DEFAULT_SETTINGS.highlight);
    assert.equal(loaded.autoSync, true, 'truthy autoSync coerces to true');
  });

  it('treats a missing autoSync as the default (true)', async () => {
    const store = createSettingsStore(dir);
    await writeFile(
      store.file,
      JSON.stringify({ accent: '#111111', highlight: '#222222' }),
      'utf8',
    );
    assert.equal((await store.load()).autoSync, true);
  });

  it('returns defaults on a corrupt file', async () => {
    const store = createSettingsStore(dir);
    await writeFile(store.file, '{ not valid json', 'utf8');
    assert.deepEqual(await store.load(), DEFAULT_SETTINGS);
  });

  it('coerces autoSync to a real boolean on save', async () => {
    const store = createSettingsStore(dir);
    await store.save({ accent: '#7b2cbf', highlight: '#590a9d', autoSync: 0 });
    const onDisk = JSON.parse(await readRaw(store.file));
    assert.equal(onDisk.autoSync, false);
  });
});

describe('stores: presets', () => {
  it('returns a clone of DEFAULT_PRESETS when the file is missing', async () => {
    const store = createPresetsStore(dir);
    const loaded = await store.load();
    assert.deepEqual(loaded, DEFAULT_PRESETS);
    assert.notEqual(loaded, DEFAULT_PRESETS);
    assert.equal(Object.isFrozen(loaded), false, 'a mutable clone, not the frozen original');
    loaded.rgb.Red.r = 0; // proves the original is untouched
    assert.equal(DEFAULT_PRESETS.rgb.Red.r, 255);
  });

  it('returns defaults on a corrupt file', async () => {
    const store = createPresetsStore(dir);
    await writeFile(store.file, 'totally not json', 'utf8');
    assert.deepEqual(await store.load(), DEFAULT_PRESETS);
  });

  it('round-trips saved presets and backfills a missing group', async () => {
    const store = createPresetsStore(dir);
    await store.save({ rgb: { X: { mode: 'rgb', r: 1, g: 2, b: 3, brightness: 50 } } });
    assert.deepEqual(await store.load(), {
      rgb: { X: { mode: 'rgb', r: 1, g: 2, b: 3, brightness: 50 } },
      white: {},
    });
  });

  it('treats a non-object payload as missing', async () => {
    const store = createPresetsStore(dir);
    await writeFile(store.file, JSON.stringify('a string'), 'utf8');
    assert.deepEqual(await store.load(), DEFAULT_PRESETS);
  });

  it('loads both groups verbatim when the file has them', async () => {
    const store = createPresetsStore(dir);
    const custom = {
      rgb: { Hot: { mode: 'rgb', r: 255, g: 64, b: 0, brightness: 90 } },
      white: { Cool: { mode: 'white', temp: 6000, brightness: 75 } },
    };
    await store.save(custom);
    assert.deepEqual(await store.load(), custom);
  });

  it('backfills a missing rgb group with an empty object', async () => {
    const store = createPresetsStore(dir);
    await writeFile(
      store.file,
      JSON.stringify({ white: { Cool: { mode: 'white', temp: 6000, brightness: 75 } } }),
      'utf8',
    );
    assert.deepEqual(await store.load(), {
      rgb: {},
      white: { Cool: { mode: 'white', temp: 6000, brightness: 75 } },
    });
  });
});

describe('stores: savedLights', () => {
  it('returns an empty map when the file is missing', async () => {
    const store = createSavedLightsStore(dir);
    assert.deepEqual(await store.load(), {});
    assert.equal(store.file, path.join(dir, 'saved_lights.json'));
  });

  it('set() creates or replaces a light keyed by MAC', async () => {
    const store = createSavedLightsStore(dir);
    await store.set('aa', 'Lamp', '10.0.0.1');
    assert.deepEqual(await store.load(), { aa: { name: 'Lamp', ip: '10.0.0.1' } });
    await store.set('aa', 'Lamp 2', '10.0.0.9');
    assert.deepEqual(await store.load(), { aa: { name: 'Lamp 2', ip: '10.0.0.9' } });
  });

  it('updateIp() writes only when the MAC exists and the IP changed', async () => {
    const store = createSavedLightsStore(dir);
    await store.set('aa', 'Lamp', '10.0.0.1');

    // Unknown MAC: no change.
    assert.deepEqual(await store.updateIp('zz', '10.0.0.2'), {
      aa: { name: 'Lamp', ip: '10.0.0.1' },
    });
    // Same IP: no change.
    assert.deepEqual(await store.updateIp('aa', '10.0.0.1'), {
      aa: { name: 'Lamp', ip: '10.0.0.1' },
    });
    // Changed IP: persisted.
    const updated = await store.updateIp('aa', '10.0.0.2');
    assert.equal(updated.aa.ip, '10.0.0.2');
    assert.equal((await store.load()).aa.ip, '10.0.0.2');
  });

  it('updateIp() does not rewrite the file when nothing changed', async () => {
    const store = createSavedLightsStore(dir);
    await store.set('aa', 'Lamp', '10.0.0.1');
    const before = await readRaw(store.file);
    await store.updateIp('aa', '10.0.0.1');
    assert.equal(await readRaw(store.file), before);
  });

  it('rename() updates the name only for a known MAC', async () => {
    const store = createSavedLightsStore(dir);
    await store.set('aa', 'Old', '10.0.0.1');
    await store.rename('aa', 'New');
    assert.equal((await store.load()).aa.name, 'New');
    // Unknown MAC: no-op, no key created.
    await store.rename('zz', 'Ghost');
    assert.deepEqual(Object.keys(await store.load()), ['aa']);
  });

  it('remove() deletes a known MAC and is a no-op otherwise', async () => {
    const store = createSavedLightsStore(dir);
    await store.set('aa', 'A', '10.0.0.1');
    await store.set('bb', 'B', '10.0.0.2');
    await store.remove('aa');
    assert.deepEqual(await store.load(), { bb: { name: 'B', ip: '10.0.0.2' } });
    await store.remove('missing'); // no throw
    assert.deepEqual(await store.load(), { bb: { name: 'B', ip: '10.0.0.2' } });
  });

  it('save() persists an arbitrary map', async () => {
    const store = createSavedLightsStore(dir);
    const map = { cc: { name: 'C', ip: '10.0.0.3' } };
    await store.save(map);
    assert.deepEqual(await store.load(), map);
  });

  it('returns an empty map on a corrupt file', async () => {
    const store = createSavedLightsStore(dir);
    await writeFile(store.file, 'not json', 'utf8');
    assert.deepEqual(await store.load(), {});
  });
});

describe('stores: lastState', () => {
  it('exposes the two backing file paths', () => {
    const store = createLastStateStore(dir);
    assert.equal(store.ipFile, path.join(dir, 'last_ip.txt'));
    assert.equal(store.deviceRgbFile, path.join(dir, 'device_rgb.json'));
  });

  it('loadIp() returns empty string when there is no file', async () => {
    assert.equal(await createLastStateStore(dir).loadIp(), '');
  });

  it('saveIp() persists a valid (trimmed) IP and loadIp() reads it back', async () => {
    const store = createLastStateStore(dir);
    await store.saveIp('  10.0.0.5  ');
    assert.equal(await store.loadIp(), '10.0.0.5');
  });

  it('saveIp() is a no-op for an invalid IP', async () => {
    const store = createLastStateStore(dir);
    await store.saveIp('not-an-ip');
    assert.equal(await store.loadIp(), '');
  });

  it('loadIp() returns empty string when the stored value is invalid', async () => {
    const store = createLastStateStore(dir);
    await writeFile(store.ipFile, 'garbage', 'utf8');
    assert.equal(await store.loadIp(), '');
  });

  it('loadRgb(mac) defaults to white when the file is missing', async () => {
    assert.deepEqual(await createLastStateStore(dir).loadRgb('aabbccddeeff'), [255, 255, 255]);
  });

  it('saveRgb(mac) then loadRgb(mac) round-trips a colour per device', async () => {
    const store = createLastStateStore(dir);
    await store.saveRgb('aabbccddeeff', [10, 20, 30]);
    assert.deepEqual(await store.loadRgb('aabbccddeeff'), [10, 20, 30]);
    // A different device keeps its own colour memory.
    assert.deepEqual(await store.loadRgb('001122334455'), [255, 255, 255]);
  });

  it('loadRgb() clamps out-of-range channels read from disk', async () => {
    const store = createLastStateStore(dir);
    await store.saveRgb('aabbccddeeff', [300, -5, 128]);
    assert.deepEqual(await store.loadRgb('aabbccddeeff'), [255, 0, 128]);
  });

  it('loadRgb() backfills missing channels with 255', async () => {
    const store = createLastStateStore(dir);
    await writeFile(store.deviceRgbFile, JSON.stringify({ aabbccddeeff: { r: 10 } }), 'utf8');
    assert.deepEqual(await store.loadRgb('aabbccddeeff'), [10, 255, 255]);
  });

  it('loadRgb() defaults to white on a corrupt file', async () => {
    const store = createLastStateStore(dir);
    await writeFile(store.deviceRgbFile, 'not json', 'utf8');
    assert.deepEqual(await store.loadRgb('aabbccddeeff'), [255, 255, 255]);
  });
});
