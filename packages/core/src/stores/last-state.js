import path from 'node:path';
import { readJson, writeJson, readText, writeText } from '../json-file.js';
import { isValidIp, clampRgb } from '../validate.js';

/** Remembers the last-used bulb IP and a per-device last colour across restarts. */
export function createLastStateStore(dir) {
  const ipFile = path.join(dir, 'last_ip.txt');
  const deviceRgbFile = path.join(dir, 'device_rgb.json');

  return {
    ipFile,
    deviceRgbFile,

    async loadIp() {
      const ip = await readText(ipFile, '');
      return isValidIp(ip) ? ip : '';
    },
    saveIp(ip) {
      return isValidIp(ip) ? writeText(ipFile, ip.trim()) : Promise.resolve();
    },

    /** Last colour remembered for `mac`, defaulting to white when unknown. */
    async loadRgb(mac) {
      const map = (await readJson(deviceRgbFile, null)) ?? {};
      const data = mac ? map[mac] : null;
      if (!data) return [255, 255, 255];
      return clampRgb([data.r ?? 255, data.g ?? 255, data.b ?? 255]);
    },
    async saveRgb(mac, [r, g, b]) {
      if (!mac) return;
      const map = (await readJson(deviceRgbFile, null)) ?? {};
      map[mac] = { r, g, b };
      return writeJson(deviceRgbFile, map);
    },
  };
}
