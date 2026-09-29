import { describe, expect, it } from 'vitest';
import fs from 'fs';
import path from 'path';
import { CHARACTERS } from '../src/data/characters';
import { ENEMIES } from '../src/data/enemies';
import { REQUIRED_CLIPS } from '../src/characters/AnimationClip';
import { AudioManager } from '../src/audio/AudioManager';

const audio = new AudioManager();

describe('character roster', () => {
  it('has at least four unique fighters', () => {
    expect(CHARACTERS.length).toBeGreaterThanOrEqual(4);
    expect(new Set(CHARACTERS.map((c) => c.id)).size).toBe(CHARACTERS.length);
  });

  for (const def of CHARACTERS) {
    describe(def.name, () => {
      it('defines exactly six abilities with the ultimate last', () => {
        expect(def.abilities).toHaveLength(6);
        def.abilities.forEach((a, i) => expect(!!a.ultimate).toBe(i === 5));
        expect(new Set(def.abilities.map((a) => a.id)).size).toBe(6);
      });

      it('provides every required animation clip', () => {
        for (const name of REQUIRED_CLIPS) expect(def.animations, `${def.id} missing ${name}`).toHaveProperty(name);
      });

      it('references only clips that exist', () => {
        const names = new Set(Object.keys(def.animations));
        for (const step of [...def.combo.ground, def.combo.air]) expect(names.has(step.anim), `${def.id} combo clip ${step.anim}`).toBe(true);
        for (const ab of def.abilities) expect(names.has(ab.anim), `${def.id} ability clip ${ab.anim}`).toBe(true);
        // Clips played from ability code: c.anim('x') / anim.play('x').
        const src = fs.readFileSync(path.join(__dirname, `../src/data/characters/${def.id}.ts`), 'utf8');
        const used = [...src.matchAll(/(?:c\.anim|anim\.play)\('([a-zA-Z]+)'/g)].map((m) => m[1]);
        for (const u of used) expect(names.has(u), `${def.id} plays unknown clip ${u}`).toBe(true);
      });

      it('uses registered sounds', () => {
        for (const s of Object.values(def.sounds)) expect(audio.has(s), `${def.id} sound ${s}`).toBe(true);
        for (const step of [...def.combo.ground, def.combo.air]) if (step.swingSound) expect(audio.has(step.swingSound)).toBe(true);
        const src = fs.readFileSync(path.join(__dirname, `../src/data/characters/${def.id}.ts`), 'utf8');
        for (const m of src.matchAll(/audio\.play\('([a-z_]+)'/g)) expect(audio.has(m[1]), `${def.id} plays unknown sound ${m[1]}`).toBe(true);
      });

      it('has sane stats', () => {
        const s = def.stats;
        expect(s.maxHealth).toBeGreaterThan(0);
        expect(s.moveSpeed).toBeGreaterThan(s.walkSpeed);
        expect(s.critChance).toBeGreaterThanOrEqual(0);
        expect(s.critChance).toBeLessThanOrEqual(1);
        expect(s.dodgeIFrames).toBeLessThanOrEqual(s.dodgeDuration + 0.1);
      });

      it('has a combo whose hits land inside each step', () => {
        for (const step of def.combo.ground) {
          for (const h of step.hits) expect(h.time).toBeLessThan(step.duration);
          expect(step.cancelTime).toBeLessThanOrEqual(step.duration);
        }
      });
    });
  }

  it('fighters are genuinely different (stats spread)', () => {
    const speeds = CHARACTERS.map((c) => c.stats.moveSpeed);
    const hp = CHARACTERS.map((c) => c.stats.maxHealth);
    expect(Math.max(...speeds) / Math.min(...speeds)).toBeGreaterThan(1.8);
    expect(Math.max(...hp) / Math.min(...hp)).toBeGreaterThan(2);
    const abilityIds = CHARACTERS.flatMap((c) => c.abilities.map((a) => a.id));
    expect(new Set(abilityIds).size).toBe(abilityIds.length);
  });
});

describe('enemy roster', () => {
  const list = Object.values(ENEMIES);
  it('has fighter, ranged and heavy types', () => {
    expect(list.map((e) => e.id).sort()).toEqual(['fighter', 'heavy', 'ranged']);
  });
  for (const e of list) {
    it(`${e.name} animations and attacks are consistent`, () => {
      for (const name of [...REQUIRED_CLIPS, 'spawn']) expect(e.animations, `${e.id} missing ${name}`).toHaveProperty(name);
      for (const a of e.attacks) {
        expect(e.animations).toHaveProperty(a.anim);
        expect(a.maxRange).toBeGreaterThanOrEqual(a.minRange);
        expect(!!a.projectile || a.hits.length > 0).toBe(true);
      }
    });
    it(`${e.name} has per-character tactics for every fighter`, () => {
      for (const c of CHARACTERS) expect(e.vsCharacter, `${e.id} vs ${c.id}`).toHaveProperty(c.id);
    });
  }
});
