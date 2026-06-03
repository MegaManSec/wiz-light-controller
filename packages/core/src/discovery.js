// LAN discovery. WiZ bulbs answer a broadcast `getSystemConfig` with their MAC
// and module name, so a few broadcasts spaced over a couple of seconds reliably
// enumerate every bulb on the subnet. Deduplicated by MAC — the stable identity
// the app keys saved lights on.

import dgram from 'node:dgram';
import { DEFAULT_PORT } from './protocol.js';

const defaultCreateSocket = () => dgram.createSocket({ type: 'udp4', reuseAddr: true });

/**
 * @typedef {Object} DiscoveredLight
 * @property {string} name  Module name, falling back to the MAC.
 * @property {string} ip
 * @property {string} mac
 */

/**
 * Broadcast for bulbs and resolve with the unique set found.
 *
 * @param {Object} [options]
 * @param {number} [options.timeoutMs=2000]   Listen window per broadcast attempt.
 * @param {number} [options.attempts=3]       Number of broadcasts.
 * @param {number} [options.port=38899]
 * @param {string} [options.broadcastAddr='255.255.255.255']
 * @param {(light: DiscoveredLight) => void} [options.onFound]  Called once per new bulb.
 * @param {AbortSignal} [options.signal]       Cancels discovery early.
 * @param {() => import('node:dgram').Socket} [options.createSocket]
 * @returns {Promise<DiscoveredLight[]>}
 */
export function discover({
  timeoutMs = 2000,
  attempts = 3,
  port = DEFAULT_PORT,
  broadcastAddr = '255.255.255.255',
  onFound,
  signal,
  createSocket = defaultCreateSocket,
} = {}) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return resolve([]);

    const socket = createSocket();
    const found = new Map();
    const payload = Buffer.from(JSON.stringify({ method: 'getSystemConfig', params: {} }), 'utf8');
    let attemptTimer = null;
    let remaining = attempts;

    const cleanup = () => {
      clearTimeout(attemptTimer);
      signal?.removeEventListener('abort', onAbort);
      try {
        socket.close();
      } catch {
        /* already closed */
      }
    };
    const finish = () => {
      cleanup();
      resolve([...found.values()]);
    };
    const onAbort = () => finish();

    socket.on('error', (err) => {
      cleanup();
      reject(err);
    });

    socket.on('message', (msg, rinfo) => {
      let result;
      try {
        result = JSON.parse(msg.toString('utf8')).result;
      } catch {
        return;
      }
      if (!result) return;
      const mac = result.mac;
      const key = mac || rinfo.address;
      if (found.has(key)) return;
      const light = { name: result.moduleName || mac || rinfo.address, ip: rinfo.address, mac };
      found.set(key, light);
      onFound?.(light);
    });

    const broadcastOnce = () => {
      if (signal?.aborted) return finish();
      socket.send(payload, port, broadcastAddr, () => {});
      remaining -= 1;
      if (remaining <= 0) {
        attemptTimer = setTimeout(finish, timeoutMs);
      } else {
        attemptTimer = setTimeout(broadcastOnce, timeoutMs);
      }
    };

    signal?.addEventListener('abort', onAbort, { once: true });
    socket.bind(() => {
      socket.setBroadcast(true);
      broadcastOnce();
    });
  });
}
