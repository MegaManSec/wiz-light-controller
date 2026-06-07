import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import {
  SCENES,
  SCENE_HINTS,
  sceneName,
  sceneHint,
  findScene,
  scenesForDevice,
} from '../src/scenes.js';

describe('scenes: SCENES table', () => {
  it('is the 36 well-known named scenes', () => {
    assert.equal(Object.keys(SCENES).length, 36);
    assert.equal(SCENES[1], 'Ocean');
    assert.equal(SCENES[4], 'Party');
    assert.equal(SCENES[26], 'Club');
    assert.equal(SCENES[31], 'Pulse');
    assert.equal(SCENES[32], 'Steampunk');
    assert.equal(SCENES[33], 'Diwali');
    assert.equal(SCENES[34], 'White');
    assert.equal(SCENES[35], 'Alarm');
    assert.equal(SCENES[36], 'Snowy Sky');
  });

  it('is frozen', () => {
    assert.equal(Object.isFrozen(SCENES), true);
  });
});

describe('scenes: sceneName', () => {
  it('maps an id to its name, null for unknown / "no scene" (0)', () => {
    assert.equal(sceneName(4), 'Party');
    assert.equal(sceneName(35), 'Alarm');
    assert.equal(sceneName(0), null);
    assert.equal(sceneName(99), null);
  });
});

describe('scenes: findScene', () => {
  it('resolves a numeric id (number, string, padded)', () => {
    assert.deepEqual(findScene(4), { id: 4, name: 'Party' });
    assert.deepEqual(findScene('4'), { id: 4, name: 'Party' });
    assert.deepEqual(findScene(' 4 '), { id: 4, name: 'Party' });
  });

  it('resolves a name case-insensitively, including multi-word', () => {
    assert.deepEqual(findScene('party'), { id: 4, name: 'Party' });
    assert.deepEqual(findScene('PASTEL COLORS'), { id: 8, name: 'Pastel Colors' });
    assert.deepEqual(findScene('deep-dive'), { id: 23, name: 'Deep-dive' }); // hyphen + case
  });

  it('returns null for unknown ids/names and unusable input', () => {
    assert.equal(findScene(99), null);
    assert.equal(findScene(0), null);
    assert.equal(findScene('disco'), null);
    assert.equal(findScene(''), null);
    assert.equal(findScene(null), null);
    assert.equal(findScene(undefined), null);
  });
});

describe('scenes: scenesForDevice', () => {
  // An RGB strip (≥3 active PWM channels) and a tunable-white-only bulb (2 channels).
  const rgb = { pwmRanges: [0, 1000, 0, 1000, 0, 1000, 0, 1000, 0, 1000], nowc: 2 };
  const whiteOnly = { pwmRanges: [0, 1000, 0, 1000], nowc: 2, cctRange: [2700, 2700, 6500, 6500] };

  it('returns all 36 for an RGB bulb', () => {
    assert.equal(scenesForDevice(rgb).length, 36);
  });

  it('returns only the white-capable subset for a white-only bulb', () => {
    const ids = scenesForDevice(whiteOnly).map((s) => s.id);
    assert.ok(ids.includes(11), 'keeps Warm White'); // white scene
    assert.ok(ids.includes(34), 'keeps White'); // white scene
    assert.ok(!ids.includes(4), 'drops Party'); // colour scene
    assert.ok(!ids.includes(35), 'drops Alarm'); // colour scene
    assert.ok(ids.length > 0 && ids.length < 36);
  });

  it('stays permissive (all 36) when capabilities are unknown', () => {
    assert.equal(scenesForDevice({}).length, 36);
    assert.equal(scenesForDevice(null).length, 36);
  });
});

describe('scenes: hints', () => {
  it('has a non-empty description for every scene', () => {
    for (const id of Object.keys(SCENES)) {
      assert.equal(typeof SCENE_HINTS[id], 'string');
      assert.ok(SCENE_HINTS[id].length > 0, `scene ${id} should have a hint`);
    }
  });

  it('sceneHint maps id → description, empty for unknown', () => {
    assert.equal(sceneHint(4), 'Fast multicolour cycle');
    assert.equal(sceneHint(999), '');
  });

  it('scenesForDevice carries the hint', () => {
    const party = scenesForDevice(null).find((s) => s.id === 4);
    assert.equal(party.hint, 'Fast multicolour cycle');
  });
});
