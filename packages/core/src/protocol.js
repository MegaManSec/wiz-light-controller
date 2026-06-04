// WiZ wire transport over UDP. The bulb listens on :38899 and speaks line-free
// JSON: `setPilot` mutates state (no reply needed), `getPilot` returns the
// current state. The socket factory is injectable so the protocol can be tested
// without touching the network.

import dgram from 'node:dgram';
import { isValidIp } from './validate.js';
import { buildSetPilotParams } from './model.js';

export const DEFAULT_PORT = 38899;
export const DEFAULT_TIMEOUT_MS = 1000;
export const DEFAULT_RETRIES = 3;
export const DEFAULT_RETRY_INTERVAL_MS = 120;
export const DEFAULT_DEBOUNCE_MS = 250;

const defaultCreateSocket = () => dgram.createSocket('udp4');
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function assertHost(host) {
  if (!isValidIp(host)) throw new TypeError(`Invalid WiZ host address: ${String(host)}`);
}

function encode(method, params) {
  return Buffer.from(JSON.stringify({ method, params }), 'utf8');
}

/**
 * Send a single `setPilot` datagram (fire-and-forget) and resolve once it has
 * left the socket. The socket is always closed.
 */
export function sendPilot(
  host,
  params,
  { port = DEFAULT_PORT, createSocket = defaultCreateSocket } = {},
) {
  assertHost(host);
  return new Promise((resolve, reject) => {
    const socket = createSocket();
    let settled = false;
    const done = (err) => {
      if (settled) return; // a send-callback error + a later 'error' event must not double-close
      settled = true;
      socket.close();
      err ? reject(err) : resolve();
    };
    socket.on('error', done);
    socket.send(encode('setPilot', params), port, host, (err) => done(err ?? null));
  });
}

/**
 * Send a no-param request (`getPilot`, `getModelConfig`, `getSystemConfig`, …)
 * and resolve with the bulb's `result` object, or `null` on timeout or any
 * error. Never rejects — callers treat `null` as "unreachable / unsupported".
 */
export function query(
  host,
  method,
  { port = DEFAULT_PORT, timeoutMs = DEFAULT_TIMEOUT_MS, createSocket = defaultCreateSocket } = {},
) {
  assertHost(host);
  return new Promise((resolve) => {
    const socket = createSocket();
    let settled = false;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.close();
      resolve(value);
    };

    const timer = setTimeout(() => finish(null), timeoutMs);
    socket.on('error', () => finish(null));
    socket.on('message', (msg) => {
      try {
        finish(JSON.parse(msg.toString('utf8')).result ?? null);
      } catch {
        finish(null);
      }
    });
    socket.send(encode(method, {}), port, host, (err) => {
      if (err) finish(null);
    });
  });
}

/** Query the bulb's live state (`getPilot`). */
export function queryPilot(host, options) {
  return query(host, 'getPilot', options);
}

/** Query the bulb's capabilities (`getModelConfig`): `cctRange`, `minDimLevel`, … */
export function getModelConfig(host, options) {
  return query(host, 'getModelConfig', options);
}

/** Query the bulb's identity (`getSystemConfig`): `mac`, `moduleName`, `fwVersion`. */
export function getSystemConfig(host, options) {
  return query(host, 'getSystemConfig', options);
}

/**
 * Stateful controller for one bulb. Coalesces rapid updates (slider drags) into
 * a single debounced send, then transmits it a few times to ride out the UDP
 * packet loss and firmware "micro-sleeps" the bulbs are prone to.
 */
export class WizLight {
  #timer = null;
  #pending = null;
  #sendGen = 0;
  // One shared deferred per debounce window, so every send() call coalesced into
  // that window settles together (see send/close) instead of a superseded call
  // hanging forever on its cleared timer.
  #deferred = null;

  constructor(host, options = {}) {
    assertHost(host);
    this.host = host;
    this.port = options.port ?? DEFAULT_PORT;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.retries = options.retries ?? DEFAULT_RETRIES;
    this.retryIntervalMs = options.retryIntervalMs ?? DEFAULT_RETRY_INTERVAL_MS;
    this.debounceMs = options.debounceMs ?? DEFAULT_DEBOUNCE_MS;
    this.createSocket = options.createSocket ?? defaultCreateSocket;
  }

  #opts() {
    return { port: this.port, createSocket: this.createSocket };
  }

  /** Query and return the live `getPilot` result (or `null` if unreachable). */
  getPilot() {
    return queryPilot(this.host, { ...this.#opts(), timeoutMs: this.timeoutMs });
  }

  /** Send `params` immediately, repeated `retries` times to survive packet loss. */
  async sendNow(params) {
    // Tag this send; if a newer send starts while this retry loop is mid-flight,
    // abandon the remaining retries so a stale payload can't land after the new one.
    const gen = (this.#sendGen += 1);
    for (let i = 0; i < this.retries; i += 1) {
      if (gen !== this.#sendGen) return;
      await sendPilot(this.host, params, this.#opts());
      if (i < this.retries - 1) await delay(this.retryIntervalMs);
    }
  }

  /**
   * Schedule `params` to be sent after the debounce window. Repeated calls
   * within the window replace the previous payload — only the latest is sent.
   * Every call coalesced into one window shares a single promise that settles
   * when that window's send completes (or resolves early if {@link close}
   * cancels it), so an awaited call never hangs just because a later call
   * superseded it.
   */
  send(params) {
    this.#pending = params;
    if (this.#timer) clearTimeout(this.#timer);
    if (!this.#deferred) {
      let resolve;
      let reject;
      const promise = new Promise((res, rej) => {
        resolve = res;
        reject = rej;
      });
      this.#deferred = { promise, resolve, reject };
    }
    const deferred = this.#deferred;
    this.#timer = setTimeout(() => {
      this.#timer = null;
      this.#deferred = null;
      const next = this.#pending;
      this.#pending = null;
      this.sendNow(next).then(deferred.resolve, deferred.reject);
    }, this.debounceMs);
    return deferred.promise;
  }

  /** Convenience: build and send the wire params for a desired {@link LightState}. */
  apply(state) {
    return this.send(buildSetPilotParams(state));
  }

  /** Power the bulb on or off without altering colour. */
  power(on) {
    return this.send({ state: Boolean(on) });
  }

  /**
   * Cancel any pending debounced send. A still-pending {@link send} promise is
   * resolved (the send was cancelled, not failed), so awaiters don't hang.
   */
  close() {
    if (this.#timer) clearTimeout(this.#timer);
    this.#timer = null;
    this.#pending = null;
    if (this.#deferred) {
      this.#deferred.resolve();
      this.#deferred = null;
    }
  }
}
