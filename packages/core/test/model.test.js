import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_STATE,
  parsePilot,
  buildSetPilotParams,
  rgbToWhiteMixed,
  whiteMixedToRgb,
  deviceBoundsFromConfig,
  deviceCapabilities,
  describeDevice,
  dimToWarmCurveFromConfig,
  warmGlowKelvin,
  applyPreset,
  stateMatchesPreset,
  DEFAULT_PRESETS,
} from '../src/model.js';
import { TEMP_MIN, TEMP_MAX } from '../src/color.js';

describe('model: DEFAULT_STATE', () => {
  it('is the documented off / rgb / white default', () => {
    assert.deepEqual(DEFAULT_STATE, {
      on: false,
      mode: 'rgb',
      rgb: [255, 255, 255],
      temp: 4000,
      brightness: 100,
    });
  });

  it('is frozen', () => {
    assert.equal(Object.isFrozen(DEFAULT_STATE), true);
  });
});

describe('model: parsePilot — unusable input', () => {
  it('returns null for null, undefined, and non-objects', () => {
    assert.equal(parsePilot(null), null);
    assert.equal(parsePilot(undefined), null);
    assert.equal(parsePilot('x'), null);
    assert.equal(parsePilot(42), null);
  });
});

describe('model: parsePilot — power and brightness', () => {
  it('treats a missing state field as on', () => {
    assert.equal(parsePilot({ r: 1, g: 2, b: 3 }).on, true);
  });

  it('coerces a present state field to Boolean', () => {
    assert.equal(parsePilot({ state: 0 }).on, false);
    assert.equal(parsePilot({ state: false }).on, false);
    assert.equal(parsePilot({ state: 1 }).on, true);
    assert.equal(parsePilot({ state: true }).on, true);
  });

  it('defaults brightness to 100 when dimming is absent', () => {
    assert.equal(parsePilot({ state: true }).brightness, 100);
  });

  it('clamps a present dimming value', () => {
    assert.equal(parsePilot({ state: true, dimming: 150 }).brightness, 100);
    assert.equal(parsePilot({ state: true, dimming: -5 }).brightness, 0);
    assert.equal(parsePilot({ state: true, dimming: 42 }).brightness, 42);
  });
});

describe('model: parsePilot — mode inference', () => {
  it('chooses rgb mode when r/g/b are present and not all zero', () => {
    const s = parsePilot({ state: 1, r: 255, g: 0, b: 0, dimming: 50 });
    assert.equal(s.mode, 'rgb');
    assert.deepEqual(s.rgb, [255, 0, 0]);
    assert.equal(s.temp, DEFAULT_STATE.temp);
    assert.equal(s.brightness, 50);
  });

  it('clamps the rgb channels it reads', () => {
    const s = parsePilot({ r: 999, g: -1, b: 40 });
    assert.deepEqual(s.rgb, [255, 0, 40]);
  });

  it('falls through to white when rgb is all zero but temp is present', () => {
    const s = parsePilot({ r: 0, g: 0, b: 0, temp: 3000 });
    assert.equal(s.mode, 'white');
    assert.equal(s.temp, 3000);
    assert.deepEqual(s.rgb, DEFAULT_STATE.rgb);
  });

  it('treats a partial rgb (a channel missing) as not-rgb', () => {
    const s = parsePilot({ r: 255, temp: 3000 });
    assert.equal(s.mode, 'white');
    assert.equal(s.temp, 3000);
  });

  it('clamps the white temperature it reads', () => {
    assert.equal(parsePilot({ state: true, temp: 99999 }).temp, TEMP_MAX);
    assert.equal(parsePilot({ state: true, temp: 100 }).temp, TEMP_MIN);
  });

  it('falls back to rgb defaults when neither colour nor temp is reported', () => {
    const s = parsePilot({ state: true });
    assert.equal(s.mode, 'rgb');
    assert.deepEqual(s.rgb, DEFAULT_STATE.rgb);
    assert.equal(s.temp, DEFAULT_STATE.temp);
  });

  it('also falls back to rgb defaults when rgb is all zero and temp is absent', () => {
    const s = parsePilot({ r: 0, g: 0, b: 0 });
    assert.equal(s.mode, 'rgb');
    assert.deepEqual(s.rgb, DEFAULT_STATE.rgb);
  });

  it('parses an empty object as an on bulb at default rgb/brightness', () => {
    assert.deepEqual(parsePilot({}), {
      on: true,
      mode: 'rgb',
      rgb: [255, 255, 255],
      temp: 4000,
      brightness: 100,
    });
  });
});

describe('model: buildSetPilotParams', () => {
  it('sends only { state: false } when off', () => {
    assert.deepEqual(buildSetPilotParams({ on: false }), { state: false });
    // Off short-circuits regardless of other fields.
    assert.deepEqual(
      buildSetPilotParams({ on: false, mode: 'rgb', rgb: [1, 2, 3], brightness: 50 }),
      {
        state: false,
      },
    );
  });

  it('sends rgb params with clamped dimming and channels', () => {
    assert.deepEqual(
      buildSetPilotParams({ on: true, mode: 'rgb', rgb: [300, -5, 128], brightness: 5 }),
      {
        state: true,
        dimming: 10,
        r: 255,
        g: 0,
        b: 128,
      },
    );
  });

  it('sends white params with clamped dimming and temp', () => {
    assert.deepEqual(
      buildSetPilotParams({ on: true, mode: 'white', temp: 99999, brightness: 50 }),
      {
        state: true,
        dimming: 50,
        temp: TEMP_MAX,
      },
    );
  });

  it('omits rgb keys in white mode and temp in rgb mode', () => {
    const white = buildSetPilotParams({ on: true, mode: 'white', temp: 4000, brightness: 80 });
    assert.deepEqual(Object.keys(white).sort(), ['dimming', 'state', 'temp']);
    const rgb = buildSetPilotParams({ on: true, mode: 'rgb', rgb: [1, 2, 3], brightness: 80 });
    assert.deepEqual(Object.keys(rgb).sort(), ['b', 'dimming', 'g', 'r', 'state']);
  });

  it('honours per-device bounds when provided', () => {
    const dim = { on: true, mode: 'white', temp: 2200, brightness: 5 };
    // No bounds → WiZ-standard defaults (dimming floored to 10, temp to TEMP_MIN).
    assert.equal(buildSetPilotParams(dim).dimming, 10);
    assert.equal(buildSetPilotParams(dim).temp, TEMP_MIN);
    // A bulb reporting minDimLevel 20 and a 2700 K floor clamps tighter.
    const p = buildSetPilotParams(dim, { dimMin: 20, tempMin: 2700, tempMax: 6500 });
    assert.equal(p.dimming, 20);
    assert.equal(p.temp, 2700);
  });

  it('with whiteMix, routes an RGB colour through the white channels', () => {
    const p = buildSetPilotParams(
      { on: true, mode: 'rgb', rgb: [255, 180, 180], brightness: 100 },
      {},
      { whiteMix: true },
    );
    assert.deepEqual(p, { state: true, dimming: 100, r: 75, g: 0, b: 0, c: 180, w: 180 });
  });

  it('whiteMix leaves a fully-saturated colour on the RGB LEDs (no white)', () => {
    const p = buildSetPilotParams(
      { on: true, mode: 'rgb', rgb: [255, 0, 0], brightness: 100 },
      {},
      { whiteMix: true },
    );
    assert.deepEqual(p, { state: true, dimming: 100, r: 255, g: 0, b: 0, c: 0, w: 0 });
  });

  it('defaults to pure RGB when whiteMix is unset', () => {
    const p = buildSetPilotParams({ on: true, mode: 'rgb', rgb: [255, 180, 180], brightness: 100 });
    assert.deepEqual(Object.keys(p).sort(), ['b', 'dimming', 'g', 'r', 'state']);
  });
});

describe('model: rgbToWhiteMixed', () => {
  it('splits the achromatic part to white channels, chromatic remainder on RGB', () => {
    assert.deepEqual(rgbToWhiteMixed([255, 180, 180]), { r: 75, g: 0, b: 0, c: 180, w: 180 });
  });

  it('leaves a fully-saturated colour unchanged (no white)', () => {
    assert.deepEqual(rgbToWhiteMixed([255, 0, 0]), { r: 255, g: 0, b: 0, c: 0, w: 0 });
  });

  it('sends a neutral/near-white colour almost entirely as white', () => {
    assert.deepEqual(rgbToWhiteMixed([255, 255, 255]), { r: 0, g: 0, b: 0, c: 255, w: 255 });
  });
});

describe('model: whiteMixedToRgb', () => {
  it('exactly inverts rgbToWhiteMixed, so read-backs are stable (no drift)', () => {
    for (const rgb of [
      [255, 200, 200],
      [255, 180, 180],
      [255, 0, 0],
      [255, 255, 255],
      [10, 128, 90],
    ]) {
      const { r, g, b, c, w } = rgbToWhiteMixed(rgb);
      assert.deepEqual(whiteMixedToRgb([r, g, b], c, w), rgb, `round-trips ${rgb}`);
    }
  });

  it('is the identity when no white is lit (or the channels are omitted)', () => {
    assert.deepEqual(whiteMixedToRgb([10, 20, 30], 0, 0), [10, 20, 30]);
    assert.deepEqual(whiteMixedToRgb([10, 20, 30]), [10, 20, 30]);
  });

  it('returns null for an uneven split (a foreign sender weights c/w separately)', () => {
    assert.equal(whiteMixedToRgb([255, 0, 65], 0, 111), null);
    assert.equal(whiteMixedToRgb([255, 0, 65], 60, 40), null);
  });

  it('clamps channels that would overflow on a foreign equal split', () => {
    assert.deepEqual(whiteMixedToRgb([200, 200, 200], 100, 100), [255, 255, 255]);
  });
});

describe('model: applyPreset', () => {
  const base = { on: false, mode: 'rgb', rgb: [1, 2, 3], temp: 4000, brightness: 33 };

  it('applies an rgb preset, turning the light on', () => {
    const out = applyPreset(base, { mode: 'rgb', r: 10, g: 20, b: 30, brightness: 60 });
    assert.equal(out.on, true);
    assert.equal(out.mode, 'rgb');
    assert.deepEqual(out.rgb, [10, 20, 30]);
    assert.equal(out.brightness, 60);
  });

  it('applies a white preset, turning the light on and clamping temp', () => {
    const out = applyPreset(base, { mode: 'white', temp: 99999, brightness: 70 });
    assert.equal(out.on, true);
    assert.equal(out.mode, 'white');
    assert.equal(out.temp, TEMP_MAX);
    assert.equal(out.brightness, 70);
  });

  it('keeps the current brightness when the preset omits it', () => {
    const out = applyPreset(base, { mode: 'white', temp: 3000 });
    assert.equal(out.brightness, 33);
  });

  it('clamps preset rgb channels', () => {
    const out = applyPreset(base, { mode: 'rgb', r: 999, g: -1, b: 50, brightness: 100 });
    assert.deepEqual(out.rgb, [255, 0, 50]);
  });

  it('does not mutate the input state', () => {
    const snapshot = structuredClone(base);
    applyPreset(base, { mode: 'rgb', r: 9, g: 9, b: 9, brightness: 9 });
    assert.deepEqual(base, snapshot);
  });
});

describe('model: stateMatchesPreset', () => {
  const red = DEFAULT_PRESETS.rgb.Red;

  it('matches an rgb state that mirrors the preset', () => {
    assert.equal(
      stateMatchesPreset(
        { mode: 'rgb', rgb: [255, 0, 0], brightness: 100, temp: 4000, on: true },
        red,
      ),
      true,
    );
  });

  it('rejects on a different mode', () => {
    assert.equal(
      stateMatchesPreset({ on: true, mode: 'white', rgb: [255, 0, 0], brightness: 100 }, red),
      false,
    );
  });

  it('rejects on a brightness mismatch', () => {
    assert.equal(
      stateMatchesPreset({ on: true, mode: 'rgb', rgb: [255, 0, 0], brightness: 40 }, red),
      false,
    );
  });

  it('rejects on any rgb channel mismatch', () => {
    assert.equal(
      stateMatchesPreset({ on: true, mode: 'rgb', rgb: [254, 0, 0], brightness: 100 }, red),
      false,
    );
    assert.equal(
      stateMatchesPreset({ on: true, mode: 'rgb', rgb: [255, 1, 0], brightness: 100 }, red),
      false,
    );
  });

  it('never matches while the light is off (the bulb is not showing the preset)', () => {
    assert.equal(
      stateMatchesPreset({ on: false, mode: 'rgb', rgb: [255, 0, 0], brightness: 100 }, red),
      false,
    );
  });

  it('never matches while a dynamic scene is running', () => {
    assert.equal(
      stateMatchesPreset(
        { on: true, mode: 'rgb', rgb: [255, 0, 0], brightness: 100, scene: { id: 4 } },
        red,
      ),
      false,
    );
  });

  it('defaults a preset without brightness to 100 when comparing', () => {
    assert.equal(
      stateMatchesPreset(
        { on: true, mode: 'white', temp: 3000, brightness: 100 },
        { mode: 'white', temp: 3000 },
      ),
      true,
    );
    assert.equal(
      stateMatchesPreset(
        { on: true, mode: 'white', temp: 3000, brightness: 40 },
        { mode: 'white', temp: 3000 },
      ),
      false,
    );
  });

  it('compares temperature for white presets', () => {
    const relax = DEFAULT_PRESETS.white.Relax;
    assert.equal(
      stateMatchesPreset({ on: true, mode: 'white', temp: 3000, brightness: 100 }, relax),
      true,
    );
    assert.equal(
      stateMatchesPreset({ on: true, mode: 'white', temp: 3001, brightness: 100 }, relax),
      false,
    );
  });

  it('matches the corresponding default-preset round trip via applyPreset', () => {
    for (const [, preset] of Object.entries({ ...DEFAULT_PRESETS.rgb, ...DEFAULT_PRESETS.white })) {
      const state = applyPreset(DEFAULT_STATE, preset);
      assert.equal(stateMatchesPreset(state, preset), true);
    }
  });
});

describe('model: DEFAULT_PRESETS', () => {
  it('is frozen and has the documented groups', () => {
    assert.equal(Object.isFrozen(DEFAULT_PRESETS), true);
    assert.deepEqual(Object.keys(DEFAULT_PRESETS.rgb), [
      'Red',
      'Green',
      'Blue',
      'Purple',
      'Sunset',
      'Aqua',
    ]);
    assert.deepEqual(Object.keys(DEFAULT_PRESETS.white), [
      'Full White',
      'Warmish',
      'Relax',
      'Full Warm',
      'Dim Relax',
      'Dim White',
    ]);
  });

  it('uses TEMP_MIN for the Full Warm preset', () => {
    assert.equal(DEFAULT_PRESETS.white['Full Warm'].temp, TEMP_MIN);
  });

  it('tags every rgb preset rgb and every white preset white', () => {
    for (const p of Object.values(DEFAULT_PRESETS.rgb)) assert.equal(p.mode, 'rgb');
    for (const p of Object.values(DEFAULT_PRESETS.white)) assert.equal(p.mode, 'white');
  });
});

describe('model: deviceBoundsFromConfig', () => {
  it('reads cctRange and minDimLevel from a getModelConfig result', () => {
    const bounds = deviceBoundsFromConfig({ cctRange: [2700, 2700, 6500, 6500], minDimLevel: 10 });
    assert.deepEqual(bounds, { tempMin: 2700, tempMax: 6500, dimMin: 10 });
  });

  it('omits fields the bulb does not report, so engine defaults apply', () => {
    assert.deepEqual(deviceBoundsFromConfig({}), {});
    assert.deepEqual(deviceBoundsFromConfig(null), {});
    assert.deepEqual(deviceBoundsFromConfig({ minDimLevel: 0 }), {}); // 0 is ignored
    assert.deepEqual(deviceBoundsFromConfig({ cctRange: [2200, 6500] }), {
      tempMin: 2200,
      tempMax: 6500,
    });
  });

  it('feeds buildSetPilotParams to clamp to the device', () => {
    const bounds = deviceBoundsFromConfig({ cctRange: [2700, 6500], minDimLevel: 20 });
    const p = buildSetPilotParams({ on: true, mode: 'white', temp: 2200, brightness: 5 }, bounds);
    assert.equal(p.temp, 2700);
    assert.equal(p.dimming, 20);
  });
});

describe('model: describeDevice', () => {
  it('summarises a full RGBWW strip from its reported channels + cctRange', () => {
    // Real getModelConfig from an ESP20_SHRGB strip: 5 active PWM channels, 2
    // white channels (nowc), 2700–6500 K.
    const summary = describeDevice({
      pwmRanges: [0, 1000, 0, 1000, 0, 1000, 0, 1000, 0, 1000],
      nowc: 2,
      cctRange: [2700, 2700, 6500, 6500],
    });
    assert.equal(summary, 'RGB + tunable white 2700–6500 K');
  });

  it('reports tunable white only when there are no colour channels', () => {
    assert.equal(
      describeDevice({ pwmRanges: [0, 1000, 0, 1000], nowc: 2, cctRange: [2200, 6500] }),
      'tunable white 2200–6500 K',
    );
  });

  it('reports RGB alone when the bulb has no white channels or range', () => {
    assert.equal(describeDevice({ pwmRanges: [0, 1000, 0, 1000, 0, 1000], nowc: 0 }), 'RGB');
  });

  it('reports plain white for a single-channel dimmable bulb', () => {
    assert.equal(describeDevice({ pwmRanges: [0, 1000], nowc: 1 }), 'white');
  });

  it('ignores padding channels (pairs with no range) so they are not read as colour', () => {
    assert.equal(
      describeDevice({
        pwmRanges: [0, 1000, 0, 1000, 0, 0, 0, 0],
        nowc: 2,
        cctRange: [2700, 6500],
      }),
      'tunable white 2700–6500 K',
    );
  });

  it('returns empty when nothing is determinable', () => {
    assert.equal(describeDevice({}), '');
    assert.equal(describeDevice(null), '');
  });
});

describe('model: deviceCapabilities', () => {
  it('reads RGB + tunable white from an RGBWW strip', () => {
    const caps = deviceCapabilities({
      pwmRanges: [0, 1000, 0, 1000, 0, 1000, 0, 1000, 0, 1000],
      nowc: 2,
      cctRange: [2700, 2700, 6500, 6500],
    });
    assert.equal(caps.rgb, true);
    assert.equal(caps.tunableWhite, true);
    assert.equal(caps.white, true);
    assert.deepEqual([caps.tempMin, caps.tempMax], [2700, 6500]);
  });

  it('reports white-only (no rgb) for a tunable-white bulb', () => {
    const caps = deviceCapabilities({
      pwmRanges: [0, 1000, 0, 1000],
      nowc: 2,
      cctRange: [2200, 6500],
    });
    assert.equal(caps.rgb, false);
    assert.equal(caps.white, true);
  });

  it('is all-false when nothing is determinable', () => {
    assert.deepEqual(deviceCapabilities({}), { rgb: false, tunableWhite: false, white: false });
    assert.deepEqual(deviceCapabilities(null), { rgb: false, tunableWhite: false, white: false });
  });
});

describe('model: dynamic scenes', () => {
  it('parsePilot surfaces a running scene (id + speed)', () => {
    const s = parsePilot({ state: true, sceneId: 4, speed: 60, dimming: 80 });
    assert.deepEqual(s.scene, { id: 4, speed: 60 });
    assert.equal(s.brightness, 80);
    assert.equal(s.on, true);
  });

  it('parsePilot omits scene when sceneId is 0 / absent', () => {
    assert.equal('scene' in parsePilot({ state: true, sceneId: 0, r: 255, g: 0, b: 0 }), false);
    assert.equal('scene' in parsePilot({ state: true, r: 1, g: 2, b: 3 }), false);
  });

  it('parsePilot keeps a scene without a reported speed', () => {
    assert.deepEqual(parsePilot({ state: true, sceneId: 7 }).scene, { id: 7 });
  });

  it('buildSetPilotParams emits sceneId + speed + dimming for a scene', () => {
    assert.deepEqual(
      buildSetPilotParams({ on: true, brightness: 80, scene: { id: 4, speed: 60 } }),
      {
        state: true,
        dimming: 80,
        sceneId: 4,
        speed: 60,
      },
    );
  });

  it('buildSetPilotParams omits speed when the scene has none', () => {
    assert.deepEqual(buildSetPilotParams({ on: true, brightness: 100, scene: { id: 4 } }), {
      state: true,
      dimming: 100,
      sceneId: 4,
    });
  });

  it('buildSetPilotParams clamps an out-of-range scene speed', () => {
    const p = buildSetPilotParams({ on: true, brightness: 100, scene: { id: 4, speed: 999 } });
    assert.equal(p.speed, 200);
    const q = buildSetPilotParams({ on: true, brightness: 100, scene: { id: 4, speed: 1 } });
    assert.equal(q.speed, 10);
  });

  it('parsePilot keeps a reported speed above 100 (the band is 10–200)', () => {
    assert.equal(parsePilot({ state: true, sceneId: 4, speed: 150 }).scene.speed, 150);
  });

  it('a scene still yields { state: false } when off', () => {
    assert.deepEqual(buildSetPilotParams({ on: false, scene: { id: 4 } }), { state: false });
  });

  it('applyPreset clears an active scene (a preset is a static colour/white)', () => {
    const next = applyPreset({ ...DEFAULT_STATE, scene: { id: 4 } }, DEFAULT_PRESETS.rgb.Red);
    assert.equal('scene' in next, false);
    assert.equal(next.mode, 'rgb');
    assert.deepEqual(next.rgb, [255, 0, 0]);
  });
});

describe('model: dimToWarmCurveFromConfig', () => {
  it('parses and sorts dim2WarmPoints by brightness', () => {
    const curve = dimToWarmCurveFromConfig({
      dim2WarmPoints: [
        [4200, 100],
        [1800, 1],
        [2700, 50],
      ],
    });
    assert.deepEqual(curve, [
      { kelvin: 1800, brightness: 1 },
      { kelvin: 2700, brightness: 50 },
      { kelvin: 4200, brightness: 100 },
    ]);
  });

  it('returns an empty curve when unreported', () => {
    assert.deepEqual(dimToWarmCurveFromConfig({}), []);
    assert.deepEqual(dimToWarmCurveFromConfig(null), []);
  });
});

describe('model: warmGlowKelvin', () => {
  const curve = [
    { kelvin: 1800, brightness: 1 },
    { kelvin: 2700, brightness: 50 },
    { kelvin: 4200, brightness: 100 },
  ];

  it('stretches the clamped range across the whole brightness span (no flat zone)', () => {
    const range = { min: 2700, max: 6500 }; // device floor clamps the 1800 warm end to 2700
    assert.equal(warmGlowKelvin(0, curve, range), 2700); // dimmest = warmest
    assert.equal(warmGlowKelvin(50, curve, range), 3450); // midpoint shifts, not flat
    assert.equal(warmGlowKelvin(100, curve, range), 4200); // brightest = curve cool end
  });

  it('falls back to the engine range without a curve/range', () => {
    assert.equal(warmGlowKelvin(0, [], {}), TEMP_MIN);
    assert.equal(warmGlowKelvin(100, [], {}), TEMP_MAX);
  });
});
