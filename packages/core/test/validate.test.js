import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  DIMMING_MIN,
  DIMMING_MAX,
  isValidIp,
  isValidHex,
  normalizeHex,
  formatMac,
  clampInt,
  clampBrightness,
  clampTemp,
  toDimming,
  clampRgb,
} from '../src/validate.js';
import { TEMP_MIN, TEMP_MAX } from '../src/color.js';

describe('validate: constants', () => {
  it('exposes the firmware dimming band', () => {
    assert.equal(DIMMING_MIN, 10);
    assert.equal(DIMMING_MAX, 100);
  });
});

describe('validate: isValidIp', () => {
  it('accepts dotted-quad IPv4 literals', () => {
    for (const ip of ['0.0.0.0', '10.0.0.1', '192.168.1.255', '255.255.255.255', '1.2.3.4']) {
      assert.equal(isValidIp(ip), true, ip);
    }
  });

  it('trims surrounding whitespace', () => {
    assert.equal(isValidIp('  10.0.0.1  '), true);
  });

  it('rejects out-of-range octets and leading zeros', () => {
    assert.equal(isValidIp('256.1.1.1'), false);
    assert.equal(isValidIp('1.2.3.300'), false);
    assert.equal(isValidIp('01.1.1.1'), false);
  });

  it('rejects wrong shapes and non-strings', () => {
    for (const bad of [
      '1.2.3',
      '1.2.3.4.5',
      '1.2.3.',
      'abc',
      '',
      'fe80::1',
      1234,
      null,
      undefined,
      {},
    ]) {
      assert.equal(isValidIp(bad), false, String(bad));
    }
  });
});

describe('validate: isValidHex', () => {
  it('accepts 6 hex digits with or without #', () => {
    assert.equal(isValidHex('#abcdef'), true);
    assert.equal(isValidHex('ABCDEF'), true);
    assert.equal(isValidHex('  #001122  '), true);
  });

  it('rejects bad lengths, bad chars, and non-strings', () => {
    for (const bad of ['#fff', '#gggggg', 'ff00', '#1234567', '', 42, null, undefined]) {
      assert.equal(isValidHex(bad), false, String(bad));
    }
  });
});

describe('validate: normalizeHex', () => {
  it('lower-cases and prefixes a valid colour', () => {
    assert.equal(normalizeHex('#ABCDEF', '#000000'), '#abcdef');
    assert.equal(normalizeHex('ABCDEF', '#000000'), '#abcdef');
    assert.equal(normalizeHex('  #AaBbCc ', '#000000'), '#aabbcc');
  });

  it('returns the fallback verbatim on invalid input', () => {
    assert.equal(normalizeHex('nope', '#7b2cbf'), '#7b2cbf');
    assert.equal(normalizeHex('', '#7b2cbf'), '#7b2cbf');
    assert.equal(normalizeHex(undefined, '#123456'), '#123456');
  });
});

describe('validate: formatMac', () => {
  it('colon-joins and upper-cases a bare 12-hex MAC', () => {
    assert.equal(formatMac('a1b2c3d4e5f6'), 'A1:B2:C3:D4:E5:F6');
    assert.equal(formatMac('AABBCCDDEEFF'), 'AA:BB:CC:DD:EE:FF');
  });

  it('passes through anything that is not exactly 12 hex chars', () => {
    assert.equal(formatMac('abc'), 'abc');
    assert.equal(formatMac('AA:BB:CC:DD:EE:FF'), 'AA:BB:CC:DD:EE:FF');
    assert.equal(formatMac('zzzzzzzzzzzz'), 'zzzzzzzzzzzz');
    const obj = {};
    assert.equal(formatMac(obj), obj);
    assert.equal(formatMac(undefined), undefined);
  });
});

describe('validate: clampInt', () => {
  it('rounds to the nearest integer', () => {
    assert.equal(clampInt(7.6, 0, 100), 8);
    assert.equal(clampInt(7.4, 0, 100), 7);
  });

  it('clamps to the inclusive bounds', () => {
    assert.equal(clampInt(-5, 0, 100), 0);
    assert.equal(clampInt(150, 0, 100), 100);
    assert.equal(clampInt(50, 0, 100), 50);
  });

  it('coerces numeric strings', () => {
    assert.equal(clampInt('42', 0, 100), 42);
  });

  it('falls back to lo when the value is not a number', () => {
    assert.equal(clampInt('xx', 5, 10), 5);
    assert.equal(clampInt(NaN, 3, 9), 3);
    assert.equal(clampInt(undefined, 1, 9), 1);
  });
});

describe('validate: clampBrightness', () => {
  it('constrains to [0, 100]', () => {
    assert.equal(clampBrightness(-3), 0);
    assert.equal(clampBrightness(0), 0);
    assert.equal(clampBrightness(55.5), 56);
    assert.equal(clampBrightness(101), 100);
  });
});

describe('validate: clampTemp', () => {
  it('constrains to the WiZ Kelvin range', () => {
    assert.equal(clampTemp(1000), TEMP_MIN);
    assert.equal(clampTemp(TEMP_MIN), TEMP_MIN);
    assert.equal(clampTemp(4000), 4000);
    assert.equal(clampTemp(99999), TEMP_MAX);
  });
});

describe('validate: toDimming', () => {
  it('clamps the wire dimming to [10, 100] so low brightness is not dropped', () => {
    assert.equal(toDimming(0), DIMMING_MIN);
    assert.equal(toDimming(5), DIMMING_MIN);
    assert.equal(toDimming(10), 10);
    assert.equal(toDimming(73), 73);
    assert.equal(toDimming(200), DIMMING_MAX);
  });
});

describe('validate: clampRgb', () => {
  it('clamps and rounds each channel to [0, 255]', () => {
    assert.deepEqual(clampRgb([300, -1, 12.6]), [255, 0, 13]);
    assert.deepEqual(clampRgb([0, 128, 255]), [0, 128, 255]);
  });

  it('does not mutate the input array', () => {
    const input = [10, 20, 30];
    const out = clampRgb(input);
    assert.deepEqual(input, [10, 20, 30]);
    assert.notEqual(out, input);
  });
});
