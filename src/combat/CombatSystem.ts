import * as THREE from 'three';
import type { Actor } from '../entities/Actor';
import type { ElementType, Faction } from '../data/types';
import type { World } from '../core/World';
import { pointSegmentDistance, segmentSegmentDistance } from '../core/math';

export interface DamageSpec {
  /** Raw amount before attacker multipliers, crits and mitigation. */
  amount: number;
  element: ElementType;
  knockback?: number;
  launch?: number;
  hitstun?: number;
  stagger?: number;
  /** Explicit knockback direction (XZ). */
  dir?: THREE.Vector3;
  /** Radial knockback away from this point. */
  origin?: THREE.Vector3;
  canCrit?: boolean;
  critBonus?: number;
  forceCrit?: boolean;
  isAbility?: boolean;
  isDot?: boolean;
  noReaction?: boolean;
  hitstop?: number;
  shake?: number;
  /** Override hit sound (null = silent). */
  sound?: string | null;
  vfx?: boolean;
  heavy?: boolean;
  ignoreIFrames?: boolean;
  /** Multiplier on ultimate meter gain. */
  ultGain?: number;
  tag?: string;
}

export interface DamageResult {
  target: Actor;
  attacker: Actor | null;
  amount: number;
  crit: boolean;
  killed: boolean;
  position: THREE.Vector3;
  dir: THREE.Vector3;
}

/** Pure damage formula (exported for unit tests). */
export function computeDamage(raw: number, attackerMul: number, crit: boolean, critMul: number, defense: number, takenMul: number): number {
  let amount = raw * attackerMul;
  if (crit) amount *= critMul;
  amount *= 100 / (100 + Math.max(0, defense));
  amount *= takenMul;
  return Math.max(1, Math.round(amount));
}

const _tmpA = new THREE.Vector3();
const _tmpB = new THREE.Vector3();

export class CombatSystem {
  comboCount = 0;
  comboTimer = 0;
  maxCombo = 0;
  totalDamageDealt = 0;
  kills = 0;
  readonly comboWindow = 2.6;

  constructor(private world: World) {}

  reset(): void {
    this.comboCount = 0;
    this.comboTimer = 0;
    this.maxCombo = 0;
    this.totalDamageDealt = 0;
    this.kills = 0;
  }

  update(dt: number): void {
    if (this.comboTimer > 0) {
      this.comboTimer -= dt;
      if (this.comboTimer <= 0) this.comboCount = 0;
    }
  }

  /** Actors hostile to the given faction that can currently be hit. */
  hostilesOf(faction: Faction): Actor[] {
    return this.world.actors.filter((a) => a.faction !== faction && a.targetable);
  }

  dealDamage(attacker: Actor | null, target: Actor, spec: DamageSpec): DamageResult | null {
    const w = this.world;
    if (!target.alive || target.removed || target.hidden) return null;
    if (attacker && attacker.faction === target.faction) return null;
    if (target.invulnerable && !spec.ignoreIFrames) {
      if (target.iframes > 0 && target.kind === 'player' && !spec.isDot) w.events.emit('perfectDodge', target);
      return null;
    }

    const owner = attacker?.owner ?? attacker;
    attacker?.def.hooks?.modifyOutgoing?.(attacker, target, spec, w);

    let crit = false;
    if (attacker && !spec.isDot && spec.canCrit !== false) {
      const chance = attacker.stats.critChance + attacker.effects.mods.critChance + (spec.critBonus ?? 0);
      crit = !!spec.forceCrit || Math.random() < chance;
    }
    const amount = computeDamage(
      spec.amount,
      attacker ? attacker.effects.mods.damage : 1,
      crit,
      attacker ? attacker.stats.critMultiplier : 1,
      target.stats.defense,
      target.effects.mods.damageTaken,
    );
    const applied = target.health.damage(amount, w.time);
    const killed = target.health.dead;

    // Knock direction.
    const dir = new THREE.Vector3();
    if (spec.dir) dir.copy(spec.dir);
    else if (spec.origin) dir.copy(target.position).sub(spec.origin);
    else if (attacker) dir.copy(target.position).sub(attacker.position);
    dir.y = 0;
    if (dir.lengthSq() < 1e-4) {
      if (attacker) attacker.forward(dir);
      else dir.set(0, 0, 1);
    }
    dir.normalize();

    const position = target.center();
    position.addScaledVector(dir, -target.radius * 0.8);
    const result: DamageResult = { target, attacker, amount: applied, crit, killed, position, dir };

    target.receiveHit(result, spec, attacker, w, dir);

    if (!spec.isDot) {
      const heavy = spec.heavy || (spec.stagger ?? 0) >= 60 || (spec.knockback ?? 0) >= 12;
      const strength = Math.min(1.5, 0.35 + applied / 120);
      if (spec.vfx !== false && attacker) attacker.def.vfx.hit(w, position, dir, strength, crit);
      if (spec.sound !== null && attacker) {
        const snd = spec.sound ?? (heavy ? attacker.def.sounds.heavyHit : attacker.def.sounds.hit);
        w.audio.play(snd, position, { pitch: crit ? 1.15 : 0.9 + Math.random() * 0.2 });
      }
      if (crit) w.audio.play('crit', position, { volume: 0.6 });
      const playerInvolved = attacker?.faction === 'player' || target.kind === 'player';
      if (playerInvolved) {
        const stop = spec.hitstop ?? (heavy ? 0.08 : 0.035);
        if (stop > 0) w.hitStop(crit ? stop * 1.3 : stop);
        const shake = spec.shake ?? (heavy ? 0.3 : 0.1);
        if (shake > 0) w.camera.addShake(target.kind === 'player' ? shake * 1.2 : shake, position);
      }
    }

    // Combo counter and ultimate meter.
    if (attacker && attacker.faction === 'player' && target.faction === 'enemy') {
      if (!spec.isDot) {
        this.comboCount++;
        this.comboTimer = this.comboWindow;
        this.maxCombo = Math.max(this.maxCombo, this.comboCount);
      }
      this.totalDamageDealt += applied;
      const p = w.player;
      if (p?.abilities) {
        const gain = Math.min(6, applied * 0.045) * (spec.ultGain ?? (spec.isDot ? 0.4 : 1)) * p.stats.ultChargeRate;
        p.abilities.addUltCharge(gain + (killed ? 4 : 0));
      }
    }
    if (target.kind === 'player') {
      target.abilities?.addUltCharge(applied * 0.06);
      if ((spec.stagger ?? 0) >= target.stats.poise && !target.effects.flags.superArmor && !spec.isDot) {
        this.comboCount = 0;
        this.comboTimer = 0;
      }
    }

    if (owner?.def.hooks?.onDealDamage) owner.def.hooks.onDealDamage(attacker!, target, result, spec, w);
    else attacker?.def.hooks?.onDealDamage?.(attacker, target, result, spec, w);
    target.def.hooks?.onTakeDamage?.(target, result, w);
    target.controller?.onDamaged?.(target, result, attacker, w);
    w.events.emit('damage', result);
    if (killed) {
      if (target.faction === 'enemy') this.kills++;
      w.events.emit('kill', target, attacker);
    }
    return result;
  }

  // ------------------------------------------------------------ queries --
  /** Cone in front of the attacker. */
  queryArc(attacker: Actor, range: number, arcDeg: number, hMin = -0.6, hMax = 2.4, origin?: THREE.Vector3, dir?: THREE.Vector3): Actor[] {
    const o = origin ?? attacker.position;
    const d = dir ?? attacker.forward(_tmpA);
    const cosHalf = Math.cos(((arcDeg / 2) * Math.PI) / 180);
    const out: Actor[] = [];
    for (const t of this.hostilesOf(attacker.faction)) {
      const dx = t.position.x - o.x;
      const dz = t.position.z - o.z;
      const distC = Math.sqrt(dx * dx + dz * dz);
      const dist = distC - t.radius;
      if (dist > range) continue;
      if (t.position.y + t.height < o.y + hMin || t.position.y > o.y + hMax) continue;
      if (distC > t.radius + 0.35) {
        const cos = (dx * d.x + dz * d.z) / distC;
        // Wider effective arc for large targets.
        const widen = Math.atan2(t.radius, distC);
        if (Math.acos(Math.min(1, Math.max(-1, cos))) - widen > Math.acos(cosHalf)) continue;
      }
      out.push(t);
    }
    return out;
  }

  /** Sphere overlap against vertical capsule hurtboxes. */
  querySphere(faction: Faction, center: THREE.Vector3, radius: number): Actor[] {
    const out: Actor[] = [];
    for (const t of this.hostilesOf(faction)) {
      _tmpA.set(t.position.x, t.position.y + t.radius, t.position.z);
      _tmpB.set(t.position.x, t.position.y + Math.max(t.radius, t.height - t.radius), t.position.z);
      if (pointSegmentDistance(center, _tmpA, _tmpB) <= radius + t.radius) out.push(t);
    }
    return out;
  }

  /** Capsule (segment a-b with radius) overlap. */
  querySegment(faction: Faction, a: THREE.Vector3, b: THREE.Vector3, radius: number): Actor[] {
    const out: Actor[] = [];
    const p = new THREE.Vector3();
    const q = new THREE.Vector3();
    for (const t of this.hostilesOf(faction)) {
      p.set(t.position.x, t.position.y + t.radius, t.position.z);
      q.set(t.position.x, t.position.y + Math.max(t.radius, t.height - t.radius), t.position.z);
      if (segmentSegmentDistance(a, b, p, q) <= radius + t.radius) out.push(t);
    }
    return out;
  }

  /** Horizontal ring (shockwaves): targets whose distance lies in [rMin, rMax] and are near the ground. */
  queryRing(faction: Faction, center: THREE.Vector3, rMin: number, rMax: number, maxHeight = 1.5): Actor[] {
    const out: Actor[] = [];
    for (const t of this.hostilesOf(faction)) {
      const dx = t.position.x - center.x;
      const dz = t.position.z - center.z;
      const d = Math.sqrt(dx * dx + dz * dz);
      if (d + t.radius < rMin || d - t.radius > rMax) continue;
      if (t.position.y - center.y > maxHeight || t.position.y + t.height < center.y - 1) continue;
      out.push(t);
    }
    return out;
  }

  /** Cylinder area of effect. */
  queryRadius(faction: Faction, center: THREE.Vector3, radius: number, height = 4): Actor[] {
    return this.queryRing(faction, center, 0, radius, height);
  }

  /** Best melee target: prefers the locked target, then the most frontal nearby enemy. */
  pickMeleeTarget(attacker: Actor, reach: number): Actor | null {
    const lock = attacker.target;
    if (lock && lock.targetable && lock.position.distanceTo(attacker.position) <= reach + lock.radius) return lock;
    const fwd = attacker.forward(_tmpB);
    let best: Actor | null = null;
    let bestScore = -Infinity;
    for (const t of this.hostilesOf(attacker.faction)) {
      const dx = t.position.x - attacker.position.x;
      const dz = t.position.z - attacker.position.z;
      const d = Math.sqrt(dx * dx + dz * dz) - t.radius;
      if (d > reach) continue;
      if (Math.abs(t.position.y - attacker.position.y) > 3 * attacker.scale) continue;
      const cos = d > 0.01 ? (dx * fwd.x + dz * fwd.z) / (d + t.radius) : 1;
      if (cos < -0.2) continue;
      const score = cos * 2 - d / reach;
      if (score > bestScore) {
        bestScore = score;
        best = t;
      }
    }
    return best;
  }

  /** Nearest hostile to a point within maxDist (optionally in a view cone). */
  nearestHostile(faction: Faction, from: THREE.Vector3, maxDist: number, dir?: THREE.Vector3, maxAngleDeg = 180, exclude?: Set<Actor>): Actor | null {
    let best: Actor | null = null;
    let bestD = Infinity;
    const cosLim = Math.cos((maxAngleDeg * Math.PI) / 180);
    for (const t of this.hostilesOf(faction)) {
      if (exclude?.has(t)) continue;
      const dx = t.position.x - from.x;
      const dz = t.position.z - from.z;
      const d = Math.sqrt(dx * dx + dz * dz);
      if (d > maxDist) continue;
      if (dir && d > 0.01 && (dx * dir.x + dz * dir.z) / d < cosLim) continue;
      if (d < bestD) {
        bestD = d;
        best = t;
      }
    }
    return best;
  }
}
