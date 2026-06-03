// Shared test doubles for the UDP transport. The engine only ever touches a
// handful of dgram.Socket methods, so a tiny EventEmitter-backed fake is enough
// to drive every protocol and discovery path deterministically.

import { EventEmitter } from 'node:events';

/**
 * A `dgram.Socket`-like fake. Captures every datagram sent (decoded from JSON)
 * and lets a test emit `'message'` / `'error'` to simulate the bulb or the OS.
 *
 * @param {Object} [options]
 * @param {boolean} [options.autoBind=true]  Invoke the `bind` callback synchronously-ish.
 * @param {boolean} [options.sendError]       If set, the send callback reports this error.
 */
export function makeFakeSocket({ autoBind = true, sendError = null } = {}) {
  const socket = new EventEmitter();
  socket.sent = [];
  socket.closed = 0;
  socket.broadcast = null;
  socket.bound = false;

  socket.bind = (cb) => {
    socket.bound = true;
    // dgram binds asynchronously; mirror that with setImmediate so callers must
    // flush before the post-bind work (setBroadcast + first send) is observable.
    if (autoBind && typeof cb === 'function') setImmediate(cb);
  };

  socket.setBroadcast = (value) => {
    socket.broadcast = value;
  };

  socket.send = (buf, port, addr, cb) => {
    socket.sent.push({ port, addr, message: JSON.parse(buf.toString('utf8')) });
    if (typeof cb === 'function') cb(sendError);
  };

  socket.close = () => {
    socket.closed += 1;
  };

  /** Convenience: the params object of the most recent datagram. */
  socket.lastParams = () => socket.sent.at(-1)?.message.params;
  /** Convenience: emit a getPilot/getSystemConfig style reply. */
  socket.reply = (result, rinfo = { address: '10.0.0.50', port: 38899 }) =>
    socket.emit('message', Buffer.from(JSON.stringify({ result }), 'utf8'), rinfo);
  /** Convenience: emit a raw (possibly malformed) buffer. */
  socket.replyRaw = (text, rinfo = { address: '10.0.0.50', port: 38899 }) =>
    socket.emit('message', Buffer.from(text, 'utf8'), rinfo);

  return socket;
}

/**
 * Drain pending macrotasks/microtasks so that `await`-chained continuations and
 * promises settle between `mock.timers.tick()` calls. `setImmediate` is a real
 * (un-mocked) macrotask, so each turn fully flushes the microtask queue.
 */
export const flush = async (turns = 6) => {
  for (let i = 0; i < turns; i += 1) await new Promise((resolve) => setImmediate(resolve));
};
