import { describe, expect, it } from 'vitest';
import { computeDamage } from '../src/combat/CombatSystem';
import { CompiledClip, POS_OFFSET, keyOffset, mirrorSpec, newPose } from '../src/characters/AnimationClip';
import { AbilitySystem } from '../src/combat/AbilitySystem';
import { EffectManager } from '../src/combat/StatusEffects';
import { Health } from '../src/combat/HealthSystem';
import { DEFAULT_BINDINGS, keyLabel } from '../src/config/controls';
import { EnemyAI } from '../src/entities/EnemyAI';
import { ENEMIES } from '../src/data/enemies';
import { CHARACTERS } from '../src/data/characters';
import type { AbilityDef } from '../src/data/types';

describe('damage formula', () => {
  it('applies defense mitigation', () => {
    expect(computeDamage(100, 1, false, 2, 0, 1)).toBe(100);
    expect(computeDamage(100, 1, false, 2, 100, 1)).toBe(50);
  });
  it('applies crits, attacker and taken multipliers', () => {
    expect(computeDamage(100, 1.5, true, 2, 0, 0.5)).toBe(150);
  });
  it('never deals less than 1', () => {
    expect(computeDamage(0.1, 1, false, 1, 1000, 0.01)).toBe(1);
  });
});

describe('health', () => {
  it('clamps damage and healing', () => {
    const h = new Health(100);
    expect(h.damage(30, 0)).toBe(30);
    expect(h.damage(500, 0)).toBe(70);
    expect(h.dead).toBe(true);
    expect(h.heal(50)).toBe(0);
  });
});

describe('animation sampling', () => {
  const clip = new CompiledClip('t', {
    duration: 1,
    keys: [
      { t: 0, p: { armL: [0, 0, 0], pos: [0, 0, 0] } },
      { t: 1, p: { armL: [1, 0, 0], pos: [0, 2, 0] }, e: 'linear' },
    ],
  });
  it('interpolates between keys', () => {
    const out = newPose();
    clip.sample(0.5, out);
    expect(out[keyOffset('armL')]).toBeCloseTo(0.5);
    expect(out[POS_OFFSET + 1]).toBeCloseTo(1);
  });
  it('clamps non-looping clips', () => {
    const out = newPose();
    clip.sample(5, out);
    expect(out[keyOffset('armL')]).toBeCloseTo(1);
  });
  it('mirrors left/right', () => {
    const m = mirrorSpec({ armL: [1, 0.5, 0.3] });
    expect(m.armR).toEqual([1, -0.5, -0.3]);
  });
});

function fakeOwner() {
  const owner: any = {
    stats: { ...CHARACTERS[0].stats, cooldownMultiplier: 1 },
    state: 'idle',
    grounded: true,
    canAct: true,
    velocity: { x: 0, y: 0, z: 0 },
    userData: {},
    attack: null,
    setState(s: string) {
      this.state = s;
    },
    returnToLocomotion() {
      this.state = 'idle';
    },
  };
  owner.effects = new EffectManager(owner);
  return owner;
}

const fakeWorld: any = { events: { emit() {} } };

function ability(id: string, over: Partial<AbilityDef> = {}): AbilityDef {
  return { id, name: id, description: '', cooldown: 4, damage: 0, anim: 'idle', tags: [], icon: { glyph: 'star', bg: ['#000', '#000'], fg: '#fff' }, cast: (c) => c.end(0.2), ...over };
}

describe('ability system', () => {
  it('starts cooldowns and recovers', () => {
    const owner = fakeOwner();
    const sys = new AbilitySystem(owner, [ability('a'), ability('b', { ultimate: true })]);
    expect(sys.tryCast(0, fakeWorld)).toBe(true);
    sys.update(0.3, fakeWorld); // cast finishes
    expect(sys.tryCast(0, fakeWorld)).toBe(false);
    expect(sys.lastFailReason).toBe('cooldown');
    for (let i = 0; i < 40; i++) sys.update(0.1, fakeWorld);
    expect(sys.isReady(0)).toBe(true);
  });

  it('supports charges', () => {
    const owner = fakeOwner();
    const sys = new AbilitySystem(owner, [ability('blink', { charges: 2, cooldown: 2 })]);
    expect(sys.tryCast(0, fakeWorld)).toBe(true);
    sys.update(0.3, fakeWorld);
    expect(sys.tryCast(0, fakeWorld)).toBe(true);
    sys.update(0.3, fakeWorld);
    expect(sys.charges[0]).toBe(0);
    expect(sys.tryCast(0, fakeWorld)).toBe(false);
    for (let i = 0; i < 20; i++) sys.update(0.1, fakeWorld);
    expect(sys.charges[0]).toBeGreaterThanOrEqual(1);
  });

  it('gates the ultimate on the meter', () => {
    const owner = fakeOwner();
    const sys = new AbilitySystem(owner, [ability('ult', { ultimate: true })]);
    expect(sys.tryCast(0, fakeWorld)).toBe(false);
    expect(sys.lastFailReason).toBe('meter');
    sys.addUltCharge(100);
    expect(sys.tryCast(0, fakeWorld)).toBe(true);
    expect(sys.ult).toBe(0);
  });

  it('respects the cooldown multiplier stat', () => {
    const owner = fakeOwner();
    owner.stats.cooldownMultiplier = 0.5;
    const sys = new AbilitySystem(owner, [ability('a', { cooldown: 10 })]);
    expect(sys.cooldownOf(0)).toBe(5);
  });
});

describe('status effects', () => {
  it('stacks multiplicative modifiers and expires', () => {
    const owner: any = {};
    const m = new EffectManager(owner);
    m.apply({ id: 'slow', duration: 1, mods: { moveSpeed: 0.5 } }, fakeWorld);
    m.apply({ id: 'haste', duration: 2, mods: { moveSpeed: 1.5 }, flags: { superArmor: true } }, fakeWorld);
    expect(m.mods.moveSpeed).toBeCloseTo(0.75);
    expect(m.flags.superArmor).toBe(true);
    m.update(1.5, fakeWorld);
    expect(m.mods.moveSpeed).toBeCloseTo(1.5);
    m.update(1, fakeWorld);
    expect(m.list).toHaveLength(0);
  });
});

describe('enemy AI adapts to the chosen fighter', () => {
  const byId = Object.fromEntries(CHARACTERS.map((c) => [c.id, c]));
  it('ranged enemies kite Titan from further away than Blaze', () => {
    const vsTitan = EnemyAI.resolveProfile(ENEMIES.ranged, byId.titan);
    const vsBlaze = EnemyAI.resolveProfile(ENEMIES.ranged, byId.blaze);
    expect(vsTitan.preferredRange).toBeGreaterThan(vsBlaze.preferredRange);
  });
  it('ranged enemies panic against Volt', () => {
    expect(EnemyAI.resolveProfile(ENEMIES.ranged, byId.volt).panic).toBeGreaterThan(EnemyAI.resolveProfile(ENEMIES.ranged, byId.titan).panic);
  });
  it('fighters guard their backs against Shadow', () => {
    expect(EnemyAI.resolveProfile(ENEMIES.fighter, byId.shadow).turnRate).toBeGreaterThan(EnemyAI.resolveProfile(ENEMIES.fighter, byId.blaze).turnRate);
  });
});

describe('controls', () => {
  it('binds the requested default keys', () => {
    expect(DEFAULT_BINDINGS.ability1).toContain('KeyQ');
    expect(DEFAULT_BINDINGS.ability2).toContain('KeyE');
    expect(DEFAULT_BINDINGS.ability3).toContain('KeyR');
    expect(DEFAULT_BINDINGS.ability4).toContain('KeyF');
    expect(DEFAULT_BINDINGS.ability5).toContain('KeyZ');
    expect(DEFAULT_BINDINGS.ultimate).toContain('KeyX');
    expect(DEFAULT_BINDINGS.dodge).toContain('ShiftLeft');
    expect(DEFAULT_BINDINGS.jump).toContain('Space');
    expect(DEFAULT_BINDINGS.attack).toContain('Mouse0');
  });
  it('labels keys for the HUD', () => {
    expect(keyLabel('KeyQ')).toBe('Q');
    expect(keyLabel('Mouse0')).toBe('LMB');
    expect(keyLabel('ShiftLeft')).toBe('Shift');
  });
});
