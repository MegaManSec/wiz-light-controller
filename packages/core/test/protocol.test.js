import { describe, it, beforeEach, afterEach, mock } from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_PORT,
  DEFAULT_TIMEOUT_MS,
  DEFAULT_RETRIES,
  DEFAULT_RETRY_INTERVAL_MS,
  DEFAULT_DEBOUNCE_MS,
  sendPilot,
  queryPilot,
  WizLight,
} from '../src/protocol.js';
import { makeFakeSocket, flush } from './helpers.js';

const HOST = '10.0.0.42';

describe('protocol: constants', () => {
  it('exposes the documented transport defaults', () => {
    assert.equal(DEFAULT_PORT, 38899);
    assert.equal(DEFAULT_TIMEOUT_MS, 1000);
    assert.equal(DEFAULT_RETRIES, 3);
    assert.equal(DEFAULT_RETRY_INTERVAL_MS, 120);
    assert.equal(DEFAULT_DEBOUNCE_MS, 250);
  });
});

describe('protocol: sendPilot', () => {
  it('sends one setPilot datagram and closes the socket', async () => {
    const socket = makeFakeSocket();
    await sendPilot(HOST, { state: true, r: 1, g: 2, b: 3 }, { createSocket: () => socket });
    assert.equal(socket.sent.length, 1);
    assert.deepEqual(socket.sent[0].message, {
      method: 'setPilot',
      params: { state: true, r: 1, g: 2, b: 3 },
    });
    assert.equal(socket.sent[0].addr, HOST);
    assert.equal(socket.sent[0].port, DEFAULT_PORT);
    assert.equal(socket.closed, 1);
  });

  it('honours a custom port', async () => {
    const socket = makeFakeSocket();
    await sendPilot(HOST, { state: false }, { port: 41234, createSocket: () => socket });
    assert.equal(socket.sent[0].port, 41234);
  });

  it('rejects and still closes the socket when send reports an error', async () => {
    const socket = makeFakeSocket({ sendError: new Error('ENETUNREACH') });
    await assert.rejects(
      () => sendPilot(HOST, { state: true }, { createSocket: () => socket }),
      /ENETUNREACH/,
    );
    assert.equal(socket.closed, 1);
  });

  it('rejects and closes when the socket emits an error event', async () => {
    const socket = makeFakeSocket();
    // A socket that errors instead of invoking the send callback.
    socket.send = () => socket.emit('error', new Error('boom'));
    await assert.rejects(
      () => sendPilot(HOST, { state: true }, { createSocket: () => socket }),
      /boom/,
    );
    assert.equal(socket.closed, 1);
  });

  it('closes only once when a successful send is followed by a late error event', async () => {
    const socket = makeFakeSocket();
    await sendPilot(HOST, { state: true }, { createSocket: () => socket });
    assert.equal(socket.closed, 1);
    // A late async socket error (e.g. ICMP port-unreachable after the datagram
    // left) must not double-close the already-closed socket.
    socket.emit('error', new Error('late'));
    assert.equal(socket.closed, 1, 'the settled guard prevents a second close');
  });

  it('throws TypeError synchronously for an invalid host', async () => {
    assert.throws(() => sendPilot('not-an-ip', {}, { createSocket: makeFakeSocket }), TypeError);
  });
});

describe('protocol: queryPilot', () => {
  beforeEach(() => mock.timers.enable({ apis: ['setTimeout'] }));
  afterEach(() => mock.timers.reset());

  it('sends getPilot and resolves the parsed result on a message', async () => {
    const socket = makeFakeSocket();
    const promise = queryPilot(HOST, { createSocket: () => socket });
    await flush();
    assert.deepEqual(socket.sent[0].message, { method: 'getPilot', params: {} });
    socket.reply({ state: true, dimming: 80 });
    assert.deepEqual(await promise, { state: true, dimming: 80 });
    assert.equal(socket.closed, 1);
  });

  it('resolves null when the result field is absent', async () => {
    const socket = makeFakeSocket();
    const promise = queryPilot(HOST, { createSocket: () => socket });
    await flush();
    socket.emit('message', Buffer.from(JSON.stringify({ env: 'pro' }), 'utf8'), {});
    assert.equal(await promise, null);
  });

  it('resolves null on malformed JSON', async () => {
    const socket = makeFakeSocket();
    const promise = queryPilot(HOST, { createSocket: () => socket });
    await flush();
    socket.replyRaw('}{ not json');
    assert.equal(await promise, null);
  });

  it('resolves null on timeout', async () => {
    const socket = makeFakeSocket();
    const promise = queryPilot(HOST, { timeoutMs: 1000, createSocket: () => socket });
    await flush();
    mock.timers.tick(1000);
    assert.equal(await promise, null);
    assert.equal(socket.closed, 1);
  });

  it('resolves null on a socket error and never rejects', async () => {
    const socket = makeFakeSocket();
    const promise = queryPilot(HOST, { createSocket: () => socket });
    await flush();
    socket.emit('error', new Error('eaddrinuse'));
    assert.equal(await promise, null);
  });

  it('resolves null when the send callback reports an error', async () => {
    const socket = makeFakeSocket({ sendError: new Error('send fail') });
    assert.equal(await queryPilot(HOST, { createSocket: () => socket }), null);
  });

  it('ignores a late message after it has already settled', async () => {
    const socket = makeFakeSocket();
    const promise = queryPilot(HOST, { createSocket: () => socket });
    await flush();
    socket.reply({ first: true });
    socket.reply({ second: true });
    assert.deepEqual(await promise, { first: true });
    assert.equal(socket.closed, 1, 'closes exactly once despite the second message');
  });

  it('throws TypeError synchronously for an invalid host', () => {
    assert.throws(() => queryPilot('999.1.1.1', { createSocket: makeFakeSocket }), TypeError);
  });
});

describe('protocol: WizLight construction', () => {
  it('throws TypeError for an invalid host', () => {
    assert.throws(() => new WizLight('nope'), TypeError);
  });

  it('applies defaults and overrides', () => {
    const dflt = new WizLight(HOST);
    assert.equal(dflt.port, DEFAULT_PORT);
    assert.equal(dflt.timeoutMs, DEFAULT_TIMEOUT_MS);
    assert.equal(dflt.retries, DEFAULT_RETRIES);
    assert.equal(dflt.retryIntervalMs, DEFAULT_RETRY_INTERVAL_MS);
    assert.equal(dflt.debounceMs, DEFAULT_DEBOUNCE_MS);

    const custom = new WizLight(HOST, {
      port: 1,
      timeoutMs: 2,
      retries: 4,
      retryIntervalMs: 5,
      debounceMs: 6,
    });
    assert.equal(custom.port, 1);
    assert.equal(custom.timeoutMs, 2);
    assert.equal(custom.retries, 4);
    assert.equal(custom.retryIntervalMs, 5);
    assert.equal(custom.debounceMs, 6);
  });
});

describe('protocol: WizLight.getPilot', () => {
  beforeEach(() => mock.timers.enable({ apis: ['setTimeout'] }));
  afterEach(() => mock.timers.reset());

  it('delegates to queryPilot using the instance options', async () => {
    const socket = makeFakeSocket();
    const light = new WizLight(HOST, { port: 5000, createSocket: () => socket });
    const promise = light.getPilot();
    await flush();
    assert.deepEqual(socket.sent[0].message, { method: 'getPilot', params: {} });
    assert.equal(socket.sent[0].port, 5000);
    socket.reply({ ok: 1 });
    assert.deepEqual(await promise, { ok: 1 });
  });
});

describe('protocol: WizLight.sendNow', () => {
  beforeEach(() => mock.timers.enable({ apis: ['setTimeout'] }));
  afterEach(() => mock.timers.reset());

  it('sends exactly `retries` datagrams spaced by retryIntervalMs', async () => {
    const sockets = [];
    const createSocket = () => {
      const s = makeFakeSocket();
      sockets.push(s);
      return s;
    };
    const light = new WizLight(HOST, { createSocket, retries: 3, retryIntervalMs: 120 });

    const promise = light.sendNow({ state: true, r: 9 });

    await flush(); // i=0 send done, first delay registered
    assert.equal(sockets.length, 1);

    mock.timers.tick(120);
    await flush(); // i=1
    assert.equal(sockets.length, 2);

    mock.timers.tick(120);
    await flush(); // i=2 -> loop ends -> resolves
    assert.equal(sockets.length, 3);
    await promise; // resolves only after all retries are sent

    // Every datagram carried the same payload and each socket was closed once.
    for (const s of sockets) {
      assert.deepEqual(s.sent[0].message, { method: 'setPilot', params: { state: true, r: 9 } });
      assert.equal(s.closed, 1);
    }
  });

  it('sends a single datagram with no delay when retries is 1', async () => {
    const sockets = [];
    const light = new WizLight(HOST, {
      retries: 1,
      createSocket: () => {
        const s = makeFakeSocket();
        sockets.push(s);
        return s;
      },
    });
    await light.sendNow({ state: false });
    assert.equal(sockets.length, 1);
  });
});

describe('protocol: WizLight.send (debounced)', () => {
  beforeEach(() => mock.timers.enable({ apis: ['setTimeout'] }));
  afterEach(() => mock.timers.reset());

  const makeLight = (overrides = {}) => {
    const sockets = [];
    const light = new WizLight(HOST, {
      debounceMs: 250,
      retries: 2,
      retryIntervalMs: 120,
      createSocket: () => {
        const s = makeFakeSocket();
        sockets.push(s);
        return s;
      },
      ...overrides,
    });
    return { light, sockets };
  };

  it('sends nothing until the debounce window elapses', async () => {
    const { light, sockets } = makeLight();
    light.send({ state: true, r: 1 });
    await flush();
    assert.equal(sockets.length, 0);
    mock.timers.tick(249);
    await flush();
    assert.equal(sockets.length, 0);
    mock.timers.tick(1); // now at 250
    await flush();
    assert.equal(sockets.length, 1);
  });

  it('coalesces rapid calls and sends only the latest payload', async () => {
    const { light, sockets } = makeLight();
    // Each superseded call returns a promise whose debounce timer is cleared, so
    // it never settles — void those; only the final call's promise resolves.
    void light.send({ state: true, r: 1 }).catch(() => {});
    void light.send({ state: true, r: 2 }).catch(() => {});
    const promise = light.send({ state: true, r: 3 });

    await flush();
    assert.equal(sockets.length, 0, 'still debouncing');

    mock.timers.tick(250);
    await flush(); // debounce fires -> sendNow i=0
    assert.equal(sockets.length, 1);

    mock.timers.tick(120);
    await flush(); // sendNow i=1 -> resolves (retries=2)
    assert.equal(sockets.length, 2);
    await promise; // resolves only after the latest payload has been sent

    for (const s of sockets) {
      assert.deepEqual(s.sent[0].message.params, { state: true, r: 3 });
    }
  });

  it('apply() builds and debounces the wire params for a state', async () => {
    const { light, sockets } = makeLight();
    const promise = light.apply({ on: true, mode: 'rgb', rgb: [10, 20, 30], brightness: 5 });
    mock.timers.tick(250);
    await flush();
    mock.timers.tick(120);
    await flush();
    await promise;
    assert.equal(sockets.length, 2);
    assert.deepEqual(sockets[0].sent[0].message.params, {
      state: true,
      dimming: 10,
      r: 10,
      g: 20,
      b: 30,
    });
  });

  it('power() debounces a bare on/off state', async () => {
    const { light, sockets } = makeLight();
    void light.power(true).catch(() => {}); // superseded within the window
    const promise = light.power(false);
    mock.timers.tick(250);
    await flush();
    mock.timers.tick(120);
    await flush();
    await promise;
    assert.equal(sockets.length, 2);
    for (const s of sockets) assert.deepEqual(s.sent[0].message.params, { state: false });
  });

  it('close() cancels a pending debounced send', async () => {
    const { light, sockets } = makeLight();
    // The returned promise never settles once close() clears the timer; void it.
    void light.send({ state: true }).catch(() => {});
    light.close();
    mock.timers.tick(1000);
    await flush();
    assert.equal(sockets.length, 0, 'nothing should be transmitted after close');
  });
});
