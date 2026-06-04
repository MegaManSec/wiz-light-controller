import path from 'node:path';
import { readJson, writeJson } from '../json-file.js';

/**
 * Lights the user has saved, keyed by MAC (the stable identity that survives
 * DHCP IP changes). Shape: `{ [mac]: { name, ip } }`.
 */
export function createSavedLightsStore(dir) {
  const file = path.join(dir, 'saved_lights.json');
  const load = async () => {
    const data = await readJson(file, {});
    return data && typeof data === 'object' ? data : {};
  };

  return {
    file,
    load,
    save: (map) => writeJson(file, map),

    /** Create or replace a saved light. */
    async set(mac, name, ip) {
      const map = await load();
      map[mac] = { name, ip };
      await writeJson(file, map);
      return map;
    },

    /** Update a known light's IP only when it actually changed (discovery path). */
    async updateIp(mac, ip) {
      const map = await load();
      if (!map[mac] || map[mac].ip === ip) return map;
      map[mac].ip = ip;
      await writeJson(file, map);
      return map;
    },

    async rename(mac, name) {
      const map = await load();
      if (map[mac]) {
        map[mac].name = name;
        await writeJson(file, map);
      }
      return map;
    },

    async remove(mac) {
      const map = await load();
      if (!Object.hasOwn(map, mac)) return map; // absent → nothing to do, no needless write
      delete map[mac];
      await writeJson(file, map);
      return map;
    },
  };
}
