import * as THREE from 'three';
import type { Actor } from '../../entities/Actor';
import type { World } from '../../core/World';
import type { DamageResult, DamageSpec } from '../../combat/CombatSystem';
import type { PoseSpec } from '../../characters/AnimationClip';
import { distXZ } from '../../core/math';

/** Shared building blocks for character kits (poses and damage helpers). */

export const LYING_BACK: PoseSpec = {
  root: [-1.47, 0, 0],
  pos: [0, 0.2, 0],
  armL: [-2.5, 0, 0.7],
  armR: [-2.7, 0, -0.5],
  foreL: [-0.4, 0, 0],
  foreR: [-0.2, 0, 0],
  legL: [-0.25, 0, 0.12],
  legR: [-0.05, 0, -0.1],
  shinL: [0.5, 0, 0],
  shinR: [0.15, 0, 0],
  head: [0.25, 0.3, 0],
};

export const LYING_FACE: PoseSpec = {
  root: [1.5, 0, 0],
  pos: [0, 0.18, 0],
  armL: [-2.9, 0, 0.5],
  armR: [-0.3, 0, -0.4],
  foreL: [-0.6, 0, 0],
  foreR: [-0.3, 0, 0],
  legL: [0.1, 0, 0.1],
  legR: [0, 0, -0.1],
  shinL: [0.4, 0, 0],
  shinR: [0.1, 0, 0],
  head: [-0.4, 0.6, 0],
};

export interface AreaOpts {
  /** 0 = no falloff, 1 = zero damage at the edge. */
  falloff?: number;
  height?: number;
  exclude?: Set<Actor>;
  onHit?: (t: Actor, r: DamageResult) => void;
  /** Damage dealt to destructible props (defaults to 2× amount). */
  propDamage?: number;
}

/** Damage every hostile inside a vertical cylinder. */
export function areaDamage(world: World, attacker: Actor, center: THREE.Vector3, radius: number, spec: DamageSpec, opts: AreaOpts = {}): Actor[] {
  const targets = world.combat.queryRadius(attacker.faction, center, radius, opts.height ?? 4);
  const hit: Actor[] = [];
  for (const t of targets) {
    if (opts.exclude?.has(t)) continue;
    const d = distXZ(t.position, center);
    const k = opts.falloff ? 1 - Math.min(1, d / radius) * opts.falloff : 1;
    const r = world.combat.dealDamage(attacker, t, { ...spec, amount: spec.amount * Math.max(0.15, k), origin: spec.origin ?? center });
    opts.exclude?.add(t);
    if (r) {
      hit.push(t);
      opts.onHit?.(t, r);
    }
  }
  world.arena.damageInSphere(center, radius, opts.propDamage ?? spec.amount * 2, undefined);
  return hit;
}

/** Hostiles sorted by distance within range (optionally in a cone). */
export function enemiesByDistance(world: World, caster: Actor, range: number, dir?: THREE.Vector3, coneDeg = 180): Actor[] {
  const cosLim = Math.cos((coneDeg * Math.PI) / 180);
  return world.combat
    .hostilesOf(caster.faction)
    .filter((t) => {
      const dx = t.position.x - caster.position.x;
      const dz = t.position.z - caster.position.z;
      const d = Math.hypot(dx, dz);
      if (d > range) return false;
      if (dir && d > 0.5 && (dx * dir.x + dz * dir.z) / d < cosLim) return false;
      return true;
    })
    .sort((a, b) => a.position.distanceToSquared(caster.position) - b.position.distanceToSquared(caster.position));
}

/** Drives an actor along a scripted path using velocity (keeps collisions intact). */
export function steerTo(actor: Actor, target: THREE.Vector3, dt: number): void {
  if (dt <= 0) return;
  actor.velocity.set((target.x - actor.position.x) / dt, (target.y - actor.position.y) / dt, (target.z - actor.position.z) / dt);
}

export const V = (x = 0, y = 0, z = 0) => new THREE.Vector3(x, y, z);
