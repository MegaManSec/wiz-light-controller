import { describe, it, beforeEach, afterEach, mock } from 'node:test';
import assert from 'node:assert/strict';
import { discover } from '../src/discovery.js';
import { DEFAULT_PORT } from '../src/protocol.js';
import { makeFakeSocket, flush } from './helpers.js';

const reply = (mac, moduleName, address, port = DEFAULT_PORT) => ({
  msg: Buffer.from(JSON.stringify({ result: { mac, moduleName } }), 'utf8'),
  rinfo: { address, port },
});

describe('discovery: pre-aborted signal', () => {
  it('resolves with an empty list and never touches a socket', async () => {
    const controller = new AbortController();
    controller.abort();
    let created = false;
    const result = await discover({
      signal: controller.signal,
      createSocket: () => {
        created = true;
        return makeFakeSocket();
      },
    });
    assert.deepEqual(result, []);
    assert.equal(created, false);
  });
});

describe('discovery: broadcasting', () => {
  beforeEach(() => mock.timers.enable({ apis: ['setTimeout'] }));
  afterEach(() => mock.timers.reset());

  it('binds, enables broadcast, then sends — in that order', async () => {
    const socket = makeFakeSocket();
    const order = [];
    const origBind = socket.bind;
    socket.bind = (cb) => {
      order.push('bind');
      origBind((/* nothing */) => {});
      setImmediate(cb);
    };
    const origSetBroadcast = socket.setBroadcast;
    socket.setBroadcast = (v) => {
      order.push('setBroadcast');
      origSetBroadcast(v);
    };
    const origSend = socket.send;
    socket.send = (...args) => {
      order.push('send');
      origSend(...args);
    };

    const promise = discover({ timeoutMs: 2000, attempts: 1, createSocket: () => socket });
    await flush();
    mock.timers.tick(2000); // final listen window
    await promise;
    assert.deepEqual(order.slice(0, 3), ['bind', 'setBroadcast', 'send']);
    assert.equal(socket.broadcast, true);
  });

  it('broadcasts `attempts` times spaced by timeoutMs to the broadcast address', async () => {
    const socket = makeFakeSocket();
    const promise = discover({
      timeoutMs: 2000,
      attempts: 3,
      broadcastAddr: '192.168.1.255',
      createSocket: () => socket,
    });

    await flush();
    assert.equal(socket.sent.length, 1);
    assert.deepEqual(socket.sent[0].message, { method: 'getSystemConfig', params: {} });
    assert.equal(socket.sent[0].addr, '192.168.1.255');
    assert.equal(socket.sent[0].port, DEFAULT_PORT);

    mock.timers.tick(2000);
    await flush();
    assert.equal(socket.sent.length, 2);

    mock.timers.tick(2000);
    await flush();
    assert.equal(socket.sent.length, 3);

    mock.timers.tick(2000); // final listen window resolves
    await promise;
    assert.equal(socket.sent.length, 3, 'no extra broadcast after the last attempt');
    assert.equal(socket.closed, 1);
  });

  it('honours a custom port', async () => {
    const socket = makeFakeSocket();
    const promise = discover({
      timeoutMs: 100,
      attempts: 1,
      port: 12345,
      createSocket: () => socket,
    });
    await flush();
    assert.equal(socket.sent[0].port, 12345);
    mock.timers.tick(100);
    await promise;
  });
});

describe('discovery: collecting bulbs', () => {
  beforeEach(() => mock.timers.enable({ apis: ['setTimeout'] }));
  afterEach(() => mock.timers.reset());

  it('collects unique bulbs and calls onFound once each', async () => {
    const socket = makeFakeSocket();
    const found = [];
    const promise = discover({
      timeoutMs: 2000,
      attempts: 2,
      onFound: (l) => found.push(l),
      createSocket: () => socket,
    });
    await flush();

    const a = reply('aaaaaaaaaaaa', 'Living Room', '10.0.0.2');
    const b = reply('bbbbbbbbbbbb', 'Kitchen', '10.0.0.3');
    socket.emit('message', a.msg, a.rinfo);
    socket.emit('message', b.msg, b.rinfo);
    // Duplicate of A on the next broadcast: must not fire onFound again.
    socket.emit('message', a.msg, a.rinfo);
    await flush();

    mock.timers.tick(2000);
    await flush();
    mock.timers.tick(2000);
    const result = await promise;

    assert.equal(found.length, 2);
    assert.deepEqual(result, [
      { name: 'Living Room', ip: '10.0.0.2', mac: 'aaaaaaaaaaaa' },
      { name: 'Kitchen', ip: '10.0.0.3', mac: 'bbbbbbbbbbbb' },
    ]);
  });

  it('dedupes by MAC even when the IP changes between replies', async () => {
    const socket = makeFakeSocket();
    const promise = discover({ timeoutMs: 1000, attempts: 1, createSocket: () => socket });
    await flush();
    const first = reply('aaaaaaaaaaaa', 'Bulb', '10.0.0.2');
    const moved = reply('aaaaaaaaaaaa', 'Bulb', '10.0.0.9');
    socket.emit('message', first.msg, first.rinfo);
    socket.emit('message', moved.msg, moved.rinfo);
    await flush();
    mock.timers.tick(1000);
    const result = await promise;
    assert.equal(result.length, 1);
    assert.equal(result[0].ip, '10.0.0.2', 'keeps the first-seen entry');
  });

  it('falls back to the source address as the dedupe key when MAC is missing', async () => {
    const socket = makeFakeSocket();
    const promise = discover({ timeoutMs: 1000, attempts: 1, createSocket: () => socket });
    await flush();
    const noMac = {
      msg: Buffer.from(JSON.stringify({ result: { moduleName: 'X' } }), 'utf8'),
      rinfo: { address: '10.0.0.7', port: DEFAULT_PORT },
    };
    socket.emit('message', noMac.msg, noMac.rinfo);
    socket.emit('message', noMac.msg, noMac.rinfo); // same address -> deduped
    await flush();
    mock.timers.tick(1000);
    const result = await promise;
    assert.equal(result.length, 1);
    assert.equal(result[0].ip, '10.0.0.7');
  });

  it('derives name from moduleName, then mac, then address', async () => {
    const socket = makeFakeSocket();
    const promise = discover({ timeoutMs: 1000, attempts: 1, createSocket: () => socket });
    await flush();

    const withName = reply('aaaaaaaaaaaa', 'Named', '10.0.0.2');
    const macOnly = {
      msg: Buffer.from(JSON.stringify({ result: { mac: 'bbbbbbbbbbbb' } }), 'utf8'),
      rinfo: { address: '10.0.0.3', port: DEFAULT_PORT },
    };
    const addrOnly = {
      msg: Buffer.from(JSON.stringify({ result: { foo: 1 } }), 'utf8'),
      rinfo: { address: '10.0.0.4', port: DEFAULT_PORT },
    };
    socket.emit('message', withName.msg, withName.rinfo);
    socket.emit('message', macOnly.msg, macOnly.rinfo);
    socket.emit('message', addrOnly.msg, addrOnly.rinfo);
    await flush();
    mock.timers.tick(1000);
    const result = await promise;

    assert.deepEqual(
      result.map((r) => r.name),
      ['Named', 'bbbbbbbbbbbb', '10.0.0.4'],
    );
  });

  it('ignores malformed JSON and result-less messages', async () => {
    const socket = makeFakeSocket();
    const found = [];
    const promise = discover({
      timeoutMs: 1000,
      attempts: 1,
      onFound: (l) => found.push(l),
      createSocket: () => socket,
    });
    await flush();
    socket.replyRaw('not json at all');
    socket.emit('message', Buffer.from(JSON.stringify({ result: null }), 'utf8'), {
      address: '10.0.0.8',
      port: DEFAULT_PORT,
    });
    socket.emit('message', Buffer.from(JSON.stringify({ method: 'pulse' }), 'utf8'), {
      address: '10.0.0.8',
      port: DEFAULT_PORT,
    });
    await flush();
    mock.timers.tick(1000);
    const result = await promise;
    assert.deepEqual(result, []);
    assert.equal(found.length, 0);
  });
});

describe('discovery: signal abort mid-flight', () => {
  beforeEach(() => mock.timers.enable({ apis: ['setTimeout'] }));
  afterEach(() => mock.timers.reset());

  it('resolves early with what has been found and closes the socket', async () => {
    const socket = makeFakeSocket();
    const controller = new AbortController();
    const promise = discover({
      timeoutMs: 2000,
      attempts: 5,
      signal: controller.signal,
      createSocket: () => socket,
    });
    await flush();
    const a = reply('aaaaaaaaaaaa', 'Found', '10.0.0.2');
    socket.emit('message', a.msg, a.rinfo);
    await flush();

    controller.abort();
    const result = await promise;
    assert.deepEqual(result, [{ name: 'Found', ip: '10.0.0.2', mac: 'aaaaaaaaaaaa' }]);
    assert.equal(socket.closed, 1);
    // Aborting before exhausting attempts means fewer than `attempts` broadcasts.
    assert.ok(socket.sent.length < 5);
  });
});

describe('discovery: socket error', () => {
  beforeEach(() => mock.timers.enable({ apis: ['setTimeout'] }));
  afterEach(() => mock.timers.reset());

  it('rejects and closes the socket on an error event', async () => {
    const socket = makeFakeSocket();
    const promise = discover({ timeoutMs: 2000, attempts: 3, createSocket: () => socket });
    await flush();
    socket.emit('error', new Error('EACCES'));
    await assert.rejects(() => promise, /EACCES/);
    assert.equal(socket.closed, 1);
  });
});
