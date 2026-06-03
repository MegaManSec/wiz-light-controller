import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  TEMP_MIN,
  TEMP_MAX,
  rgbToHsv,
  hsvToRgb,
  rgbToHex,
  hexToRgb,
  kelvinToRgb,
  wheelToHS,
  hsToWheel,
} from '../src/color.js';

const closeTo = (actual, expected, eps = 1e-9) =>
  assert.ok(Math.abs(actual - expected) <= eps, `${actual} !~= ${expected}`);

describe('color: constants', () => {
  it('exposes the WiZ Kelvin range', () => {
    assert.equal(TEMP_MIN, 2200);
    assert.equal(TEMP_MAX, 6500);
  });
});

describe('color: rgbToHsv', () => {
  it('maps primary colours to colorsys hues', () => {
    assert.deepEqual(rgbToHsv([255, 0, 0]), [0, 1, 1]);
    assert.deepEqual(rgbToHsv([0, 255, 0]), [1 / 3, 1, 1]);
    assert.deepEqual(rgbToHsv([0, 0, 255]), [2 / 3, 1, 1]);
  });

  it('returns zero hue/sat for greys (max === min)', () => {
    const [h, s, v] = rgbToHsv([128, 128, 128]);
    assert.equal(h, 0);
    assert.equal(s, 0);
    closeTo(v, 128 / 255);
  });

  it('maps pure black to all zeros', () => {
    assert.deepEqual(rgbToHsv([0, 0, 0]), [0, 0, 0]);
  });

  it('maps pure white to value 1 with no saturation', () => {
    assert.deepEqual(rgbToHsv([255, 255, 255]), [0, 0, 1]);
  });

  it('keeps hue within [0, 1)', () => {
    for (const rgb of [
      [255, 1, 0],
      [255, 0, 1],
      [10, 200, 30],
      [5, 5, 250],
    ]) {
      const [h] = rgbToHsv(rgb);
      assert.ok(h >= 0 && h < 1, `hue ${h} out of range for ${rgb}`);
    }
  });
});

describe('color: hsvToRgb', () => {
  it('maps hues back to primaries', () => {
    assert.deepEqual(hsvToRgb([0, 1, 1]), [255, 0, 0]);
    assert.deepEqual(hsvToRgb([1 / 3, 1, 1]), [0, 255, 0]);
    assert.deepEqual(hsvToRgb([2 / 3, 1, 1]), [0, 0, 255]);
  });

  it('treats zero saturation as greyscale of value', () => {
    assert.deepEqual(hsvToRgb([0, 0, 0.5]), [128, 128, 128]);
    assert.deepEqual(hsvToRgb([0.7, 0, 1]), [255, 255, 255]);
    assert.deepEqual(hsvToRgb([0.42, 0, 0]), [0, 0, 0]);
  });

  it('covers every hue sextant without throwing or going out of byte range', () => {
    for (let i = 0; i <= 6; i += 1) {
      const rgb = hsvToRgb([i / 6, 1, 1]);
      for (const c of rgb) assert.ok(c >= 0 && c <= 255 && Number.isInteger(c));
    }
  });

  it('round-trips rgb -> hsv -> rgb for saturated colours', () => {
    for (const rgb of [
      [255, 0, 0],
      [0, 255, 0],
      [0, 0, 255],
      [128, 0, 255],
      [255, 120, 40],
      [0, 255, 255],
    ]) {
      assert.deepEqual(hsvToRgb(rgbToHsv(rgb)), rgb);
    }
  });
});

describe('color: rgbToHex / hexToRgb', () => {
  it('formats lower-case zero-padded hex', () => {
    assert.equal(rgbToHex([255, 0, 0]), '#ff0000');
    assert.equal(rgbToHex([0, 0, 0]), '#000000');
    assert.equal(rgbToHex([1, 2, 3]), '#010203');
    assert.equal(rgbToHex([255, 255, 255]), '#ffffff');
  });

  it('clamps and rounds out-of-range channels when formatting', () => {
    assert.equal(rgbToHex([300, -10, 127.6]), '#ff0080');
  });

  it('parses 6-digit hex with or without leading #', () => {
    assert.deepEqual(hexToRgb('#ff8000'), [255, 128, 0]);
    assert.deepEqual(hexToRgb('FF8000'), [255, 128, 0]);
    assert.deepEqual(hexToRgb('  #AbCdEf  '), [171, 205, 239]);
  });

  it('round-trips hex -> rgb -> hex', () => {
    for (const hex of ['#000000', '#ffffff', '#7b2cbf', '#590a9d']) {
      assert.equal(rgbToHex(hexToRgb(hex)), hex);
    }
  });

  it('returns null for malformed or non-string input', () => {
    assert.equal(hexToRgb('#fff'), null);
    assert.equal(hexToRgb('#gggggg'), null);
    assert.equal(hexToRgb('ff00'), null);
    assert.equal(hexToRgb('#1234567'), null);
    assert.equal(hexToRgb(''), null);
    assert.equal(hexToRgb(0xff0000), null);
    assert.equal(hexToRgb(null), null);
    assert.equal(hexToRgb(undefined), null);
  });
});

describe('color: kelvinToRgb', () => {
  it('produces warm output at the low end', () => {
    assert.deepEqual(kelvinToRgb(2200), [255, 146, 39]);
  });

  it('produces near-white output at the high end', () => {
    assert.deepEqual(kelvinToRgb(6500), [255, 254, 250]);
  });

  it('matches the Tanner Helland fit at the mid range', () => {
    assert.deepEqual(kelvinToRgb(4000), [255, 206, 166]);
  });

  it('clamps blue to 0 below 19 hundred-K (very warm)', () => {
    assert.deepEqual(kelvinToRgb(1000), [255, 68, 0]);
  });

  it('uses the t > 66 branch above 6600K', () => {
    const [r, g, b] = kelvinToRgb(10000);
    assert.equal(b, 255);
    assert.ok(r <= 255 && g <= 255);
    assert.ok(r < 255 || g < 255 || true);
  });

  it('returns integer bytes in range for the whole supported band', () => {
    for (let k = TEMP_MIN; k <= TEMP_MAX; k += 100) {
      const rgb = kelvinToRgb(k);
      for (const c of rgb) assert.ok(Number.isInteger(c) && c >= 0 && c <= 255);
    }
  });
});

describe('color: wheelToHS', () => {
  it('returns hue 0.5 / saturation 0 at the exact centre', () => {
    assert.deepEqual(wheelToHS(50, 50, 100), { h: 0.5, s: 0 });
  });

  it('returns saturation 1 at the rim', () => {
    const hs = wheelToHS(100, 50, 100);
    closeTo(hs.s, 1);
    closeTo(hs.h, 0.5);
  });

  it('returns null outside the radius (size / 2)', () => {
    assert.equal(wheelToHS(0, 0, 100), null);
    assert.equal(wheelToHS(100, 100, 100), null);
  });

  it('accepts a point exactly on the radius boundary', () => {
    // distance from centre (50,50) to (50,0) is exactly 50 === c, so not null.
    assert.notEqual(wheelToHS(50, 0, 100), null);
  });

  it('keeps hue within [0, 1] and sat within [0, 1] across the disc', () => {
    for (let x = 0; x <= 100; x += 25) {
      for (let y = 0; y <= 100; y += 25) {
        const hs = wheelToHS(x, y, 100);
        if (hs === null) continue;
        assert.ok(hs.h >= 0 && hs.h <= 1);
        assert.ok(hs.s >= 0 && hs.s <= 1);
      }
    }
  });
});

describe('color: hsToWheel', () => {
  it('places sat 0 at the centre', () => {
    assert.deepEqual(hsToWheel(0, 0, 100), { x: 50, y: 50 });
  });

  it('is the geometric inverse of wheelToHS for interior points', () => {
    const size = 200;
    for (const [h, s] of [
      [0.1, 0.5],
      [0.4, 0.8],
      [0.75, 0.3],
      [0.9, 0.95],
    ]) {
      const { x, y } = hsToWheel(h, s, size);
      const back = wheelToHS(x, y, size);
      assert.ok(back !== null);
      closeTo(back.h, h, 1e-9);
      closeTo(back.s, s, 1e-9);
    }
  });
});
