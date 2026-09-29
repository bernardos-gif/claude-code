import * as THREE from 'three';
import type { Actor } from '../entities/Actor';
import type { EffectSpec } from './StatusEffects';
import { FireFX, LightningFX } from '../vfx/ElementFX';

/** Reusable status effects shared across characters and enemies. */
export const Effects = {
  /** Damage over time; stacks up to 3 times. */
  burn(source: Actor, dps: number, duration = 3): EffectSpec {
    return {
      id: 'burn',
      duration,
      maxStacks: 3,
      tickInterval: 0.5,
      icon: 'burn',
      source,
      onTick(target, e, world) {
        world.combat.dealDamage(source, target, { amount: dps * 0.5 * e.stacks, element: 'fire', isDot: true, sound: null, vfx: false, canCrit: false });
      },
      onUpdate(target, e, dt, world) {
        if (Math.random() < dt * 14) FireFX.trailPuff(world.vfx, target.center().add(new THREE.Vector3(0, (Math.random() - 0.5) * target.height * 0.6, 0)));
      },
    };
  },

  stun(duration: number, color = 0xfff2a0): EffectSpec {
    return {
      id: 'stun',
      duration,
      flags: { stunned: true },
      icon: 'stun',
      onUpdate(target, e, dt, world) {
        if (Math.random() < dt * 10) {
          const p = target.position.clone();
          p.y += target.height + 0.2;
          world.vfx.emit('spark', p, 1, { speed: [0.5, 1.5], life: 0.4, size: 0.22, color, jitter: 0.35, jitterY: 0.05 });
        }
      },
    };
  },

  slow(amount: number, duration: number, id = 'slow'): EffectSpec {
    return {
      id,
      duration,
      icon: 'slow',
      mods: { moveSpeed: 1 - amount, attackSpeed: 1 - amount * 0.4 },
    };
  },

  /** Electrified: shocked visuals + slow. */
  shocked(duration: number): EffectSpec {
    return {
      id: 'shocked',
      duration,
      icon: 'static',
      mods: { moveSpeed: 0.8 },
      onUpdate(target, e, dt, world) {
        if (Math.random() < dt * 6) LightningFX.arcBurst(world.vfx, target.center(), 0.8, 1);
      },
    };
  },
};
