import * as THREE from 'three';
import type { Actor, ActorController } from './Actor';
import type { World } from '../core/World';
import type { AIProfile, CharacterDefinition, EnemyAttack, EnemyDefinition } from '../data/types';
import type { DamageResult } from '../combat/CombatSystem';
import { Textures } from '../vfx/Textures';
import { clamp, moveAngleTowards, rand, yawFromDir } from '../core/math';

type Mode = 'spawn' | 'engage' | 'flee' | 'search' | 'wander';

/**
 * Enemy brain. Tactics come from the enemy's AIProfile, adapted to the
 * player's ThreatProfile (works for any future character), then overridden
 * by explicit per-character tactics (vsCharacter). Examples:
 *  - Hexcasters kite slow Titan from far away but panic against Volt.
 *  - Ravagers bait Titan's slow swings and guard their backs against Shadow.
 *  - Everyone steers around Blaze's burning ground and Volt's static field.
 */
export class EnemyAI implements ActorController {
  /** Melee attack tokens: limits how many enemies swing at once. */
  static readonly attackers = new Set<Actor>();
  static maxAttackers = 3;

  readonly profile: AIProfile;
  mode: Mode = 'spawn';
  private target: Actor | null = null;
  private lastSeen = new THREE.Vector3();
  private lastSeenTime = -99;
  private decision = 0;
  private attackCd = 1 + Math.random();
  private strafeDir = Math.random() < 0.5 ? 1 : -1;
  private strafeTimer = 0;
  private pending: { attack: EnemyAttack; fired: boolean } | null = null;
  private panicTimer = 0;
  private dodgedProjectiles = new WeakSet<object>();
  private wanderTarget = new THREE.Vector3();
  private retargetTimer = 0;
  private telegraphs: THREE.Mesh[] = [];
  private tokenHeld = false;

  constructor(public readonly def: EnemyDefinition, playerDef: CharacterDefinition | null) {
    this.profile = EnemyAI.resolveProfile(def, playerDef);
  }

  /** Base tactics → adapt to the fighter's threat profile → explicit overrides. */
  static resolveProfile(def: EnemyDefinition, playerDef: CharacterDefinition | null): AIProfile {
    const p: AIProfile = { ...def.ai };
    if (playerDef) {
      const t = playerDef.threat;
      const ranged = def.ai.retreatRange > 0;
      // Fast fighters: ranged units back off earlier and panic more.
      if (ranged) {
        p.retreatRange *= 1 + t.mobility * 0.5;
        p.panic = clamp(p.panic + (t.mobility - 0.5) * 0.4, 0, 1);
      }
      // Stealthy fighters: turn faster, forget sooner.
      p.turnRate *= 1 + t.stealth * 0.6;
      p.memory *= 1 - t.stealth * 0.4;
      // Tanky, slow fighters: melee units bait instead of trading.
      if (!ranged && t.durability > 0.7) p.aggression *= 0.8;
      // Area-heavy fighters: spread out and avoid zones.
      if (t.area > 0.6) p.strafe = Math.max(p.strafe, 0.5);
      Object.assign(p, def.vsCharacter[playerDef.id] ?? {});
    }
    return p;
  }

  private get isRanged(): boolean {
    return this.profile.retreatRange > 0;
  }

  update(a: Actor, dt: number, w: World): void {
    a.moveDir.set(0, 0, 0);
    a.userData.strafe = false;
    if (!a.alive) {
      this.releaseToken();
      this.clearTelegraph(w);
      return;
    }
    this.decision -= dt;
    this.attackCd -= dt;
    this.strafeTimer -= dt;
    this.panicTimer -= dt;
    this.retargetTimer -= dt;

    if (a.state === 'spawn') {
      if (a.stateTime > (a.anim.clipDuration('spawn') || 1)) {
        a.returnToLocomotion();
        this.mode = 'engage';
      }
      return;
    }

    this.perceive(a, w);

    if (a.state === 'attack') {
      this.updateAttack(a, dt, w);
      return;
    }
    this.releaseToken();
    this.clearTelegraph(w);
    if (!a.canAct) return;

    const t = this.target;
    if (!t) {
      this.searchOrWander(a, w);
      return;
    }

    const toT = t.position.clone().sub(a.position).setY(0);
    const dist = toT.length();
    const dir = dist > 0.001 ? toT.clone().divideScalar(dist) : a.forward();
    const visible = w.time - this.lastSeenTime < 0.1;

    this.tryEvade(a, t, dist, w);
    if (a.state === 'dodge') return;

    const desired = new THREE.Vector3();
    let run = true;
    const p = this.profile;

    if (this.isRanged) {
      const tSpeed = Math.hypot(t.velocity.x, t.velocity.z);
      if (visible && dist < p.retreatRange && tSpeed > 9 && Math.random() < p.panic * dt * 3) this.panicTimer = 1.4;
      if (dist < 2.8 && this.canUse('Repel', dist) && this.attackCd < 0.8) {
        this.startAttack(a, t, this.findAttack('Repel')!, w);
        return;
      }
      if (this.panicTimer > 0 || dist < p.retreatRange) {
        // Flee away from the target, sliding sideways.
        desired.copy(dir).negate().addScaledVector(new THREE.Vector3(-dir.z, 0, dir.x), this.strafeDir * 0.5);
        this.mode = 'flee';
        a.effects.apply({ id: 'fleeing', duration: 0.25, mods: { moveSpeed: p.fleeSpeed } }, w);
      } else if (dist > p.attackRange - 2 || !visible) {
        desired.copy(dir);
        this.mode = 'engage';
      } else {
        // In range: strafe and shoot.
        this.mode = 'engage';
        if (visible && this.attackCd <= 0 && Math.random() < p.aggression) {
          const atk = this.chooseAttack(dist, t);
          if (atk) {
            this.startAttack(a, t, atk, w);
            return;
          }
        }
        if (this.strafeTimer <= 0) {
          this.strafeTimer = rand(1, 2.5);
          if (Math.random() < 0.4) this.strafeDir *= -1;
        }
        desired.set(-dir.z, 0, dir.x).multiplyScalar(this.strafeDir * p.strafe);
        if (dist < p.preferredRange) desired.addScaledVector(dir, -0.5);
        else desired.addScaledVector(dir, 0.3);
        run = false;
        a.userData.strafe = true;
      }
    } else {
      // Melee.
      const inRange = dist <= p.attackRange + t.radius;
      const punish = (t.state === 'attack' || t.state === 'ability' || t.state === 'getup' || t.state === 'knockdown') && dist < p.attackRange + 1.5;
      const tokenFree = this.def.id === 'heavy' || EnemyAI.attackers.size < EnemyAI.maxAttackers || this.tokenHeld;
      if (visible && this.attackCd <= 0 && tokenFree) {
        const want = inRange ? Math.random() < p.aggression || punish : false;
        const atk = want ? this.chooseAttack(dist, t) : this.chooseAttack(dist, t, true);
        if (atk && (want || (atk.minRange > 2 && Math.random() < p.aggression * 0.5))) {
          this.startAttack(a, t, atk, w);
          return;
        }
      }
      const hold = tokenFree ? p.preferredRange : Math.max(p.preferredRange, 4.5);
      if (dist > hold + 0.8) {
        desired.copy(dir);
        run = dist > hold + 3;
      } else if (dist < hold - 1) {
        desired.copy(dir).negate();
        run = false;
      } else {
        if (this.strafeTimer <= 0) {
          this.strafeTimer = rand(0.8, 2);
          if (Math.random() < 0.5) this.strafeDir *= -1;
        }
        desired.set(-dir.z, 0, dir.x).multiplyScalar(this.strafeDir * p.strafe);
        run = false;
      }
      a.userData.strafe = dist < hold + 2;
    }

    this.applySteering(a, desired, w);
    a.moveScale = run || this.mode === 'flee' ? 1 : 0.45;
    // Keep facing the target while strafing (turn rate matters vs. Shadow).
    if (a.userData.strafe || this.mode === 'engage') {
      const yaw = yawFromDir(dir.x, dir.z);
      a.facing = moveAngleTowards(a.facing, yaw, a.stats.turnSpeed * p.turnRate * dt);
    }
  }

  private perceive(a: Actor, w: World): void {
    if (this.retargetTimer <= 0 || !this.target || !this.target.targetable) {
      this.retargetTimer = 0.5;
      let best: Actor | null = null;
      let bestScore = Infinity;
      const blind = a.effects.has('blind');
      for (const c of w.combat.hostilesOf(a.faction)) {
        const d = c.position.distanceTo(a.position);
        if (c.stealthed && d > 2.2) continue;
        if (blind && d > 3) continue;
        // Clones act as decoys: attractive when close.
        const score = d * (c.kind === 'clone' ? 0.75 : 1) + (c === this.target ? -2 : 0);
        if (score < bestScore) {
          bestScore = score;
          best = c;
        }
      }
      this.target = best;
    }
    const t = this.target;
    if (t && t.targetable && !(t.stealthed && t.position.distanceTo(a.position) > 2.2)) {
      this.lastSeen.copy(t.position);
      this.lastSeenTime = w.time;
    } else if (t && (t.stealthed || !t.targetable)) {
      this.target = null;
    }
  }

  private searchOrWander(a: Actor, w: World): void {
    const p = this.profile;
    const since = w.time - this.lastSeenTime;
    let goal: THREE.Vector3;
    if (since < p.memory) {
      this.mode = 'search';
      goal = this.lastSeen;
      if (goal.distanceTo(a.position) < 1.5) {
        a.facing += 1.8 * (1 / 60); // look around
        return;
      }
    } else {
      this.mode = 'wander';
      if (this.wanderTarget.lengthSq() === 0 || this.wanderTarget.distanceTo(a.position) < 2 || this.decision <= 0) {
        this.decision = rand(2, 4);
        const player = w.player;
        const base = player ? player.position : new THREE.Vector3();
        this.wanderTarget.set(base.x + rand(-12, 12), 0, base.z + rand(-12, 12));
      }
      goal = this.wanderTarget;
    }
    const d = goal.clone().sub(a.position).setY(0);
    if (d.lengthSq() > 0.01) this.applySteering(a, d.normalize(), w);
    a.moveScale = this.mode === 'search' ? 0.8 : 0.45;
  }

  private applySteering(a: Actor, desired: THREE.Vector3, w: World): void {
    const p = this.profile;
    // Separation from allies.
    const sep = new THREE.Vector3();
    const spread = w.playerDef && w.playerDef.threat.area > 0.6 ? 3.2 : 2.2;
    for (const o of w.actors) {
      if (o === a || o.faction !== a.faction || !o.alive) continue;
      const dx = a.position.x - o.position.x;
      const dz = a.position.z - o.position.z;
      const d2 = dx * dx + dz * dz;
      const r = spread * Math.max(1, (a.scale + o.scale) * 0.5);
      if (d2 < r * r && d2 > 1e-4) {
        const d = Math.sqrt(d2);
        sep.x += (dx / d) * (1 - d / r);
        sep.z += (dz / d) * (1 - d / r);
      }
    }
    desired.addScaledVector(sep, 0.9);
    // Hazard avoidance (burning ground, static fields, tornadoes, smoke).
    if (p.avoidHazards) {
      const probe = a.position.clone().addScaledVector(desired.lengthSq() > 0 ? desired.clone().normalize() : a.forward(), 1.8);
      const z = w.zones.dangerAt(a.position, a.faction, 0.8) ?? w.zones.dangerAt(probe, a.faction, 0.5);
      if (z) {
        const away = a.position.clone().sub(z.position).setY(0);
        if (away.lengthSq() < 0.01) away.set(Math.random() - 0.5, 0, Math.random() - 0.5);
        desired.addScaledVector(away.normalize(), 2.2);
      }
    }
    if (desired.lengthSq() > 0.0001) a.moveDir.copy(desired.setY(0).normalize());
  }

  private tryEvade(a: Actor, t: Actor, dist: number, w: World): void {
    const p = this.profile;
    if (p.evasion <= 0 || !a.canDodge()) return;
    // Dodge incoming player projectiles.
    for (const proj of w.projectiles.list) {
      if (proj.owner.faction === a.faction || this.dodgedProjectiles.has(proj)) continue;
      const rel = a.position.clone().sub(proj.position);
      const d = rel.length();
      if (d > 7) continue;
      const v = proj.velocity.clone().normalize();
      if (rel.normalize().dot(v) < 0.9) continue;
      this.dodgedProjectiles.add(proj);
      if (Math.random() < p.evasion) {
        const side = new THREE.Vector3(-v.z, 0, v.x).multiplyScalar(Math.random() < 0.5 ? 1 : -1);
        a.tryDodge(w, side);
        return;
      }
    }
    // React to a wind-up in melee range.
    if (dist < 4 && (t.state === 'attack' || t.state === 'ability') && t.stateTime < 0.1 && Math.random() < p.evasion * 0.6) {
      const away = a.position.clone().sub(t.position).setY(0).normalize();
      const side = new THREE.Vector3(-away.z, 0, away.x).multiplyScalar(this.strafeDir);
      a.tryDodge(w, away.add(side).normalize());
    }
  }

  private findAttack(name: string): EnemyAttack | undefined {
    return this.def.attacks.find((x) => x.name === name);
  }

  private canUse(name: string, dist: number): boolean {
    const atk = this.findAttack(name);
    return !!atk && dist >= atk.minRange && dist <= atk.maxRange;
  }

  private chooseAttack(dist: number, t: Actor, gapOnly = false): EnemyAttack | null {
    const opts = this.def.attacks.filter((x) => dist >= x.minRange && dist <= x.maxRange + t.radius && (!gapOnly || x.minRange > 2));
    if (!opts.length) return null;
    // Heavies favour area slams against fast or evasive fighters.
    const fast = t.def.stats.moveSpeed > 11;
    const weights = opts.map((o) => o.weight * (o.telegraph && fast ? 2.5 : 1));
    let r = Math.random() * weights.reduce((s, x) => s + x, 0);
    for (let i = 0; i < opts.length; i++) {
      r -= weights[i];
      if (r <= 0) return opts[i];
    }
    return opts[0];
  }

  private startAttack(a: Actor, t: Actor, atk: EnemyAttack, w: World): void {
    a.faceTowards(t.position);
    a.startAttack(atk, w);
    this.attackCd = this.profile.attackCooldown * rand(0.8, 1.3);
    this.pending = atk.projectile ? { attack: atk, fired: false } : null;
    if (!atk.projectile && this.def.id !== 'heavy') {
      EnemyAI.attackers.add(a);
      this.tokenHeld = true;
    }
    if (atk.telegraph) {
      const first = atk.hits[0]?.time ?? 1;
      const life = first / Math.max(0.3, a.stats.attackSpeed) + 0.1;
      this.telegraphs = [
        w.vfx.decal(a.position, atk.telegraph, Textures.ring(), 0xff2020, life, { additive: true, opacity: 0.9, fadeIn: 0.2 }),
        w.vfx.decal(a.position, atk.telegraph * 0.95, Textures.soft(), 0xff1010, life, { additive: true, opacity: 0.25, fadeIn: 0.3 }),
      ];
    }
  }

  private updateAttack(a: Actor, dt: number, w: World): void {
    const t = this.target;
    const run = a.attack;
    if (!run) return;
    const ut = run.t * run.speed;
    // Track the target during wind-up (limited by turn rate).
    const firstHit = run.step.hits[0]?.time ?? this.pending?.attack.projectile?.time ?? 0.5;
    if (t && ut < firstHit * 0.85) {
      const yaw = yawFromDir(t.position.x - a.position.x, t.position.z - a.position.z);
      a.facing = moveAngleTowards(a.facing, yaw, a.stats.turnSpeed * this.profile.turnRate * dt * 0.8);
    }
    const pend = this.pending;
    if (pend && !pend.fired && pend.attack.projectile && ut >= pend.attack.projectile.time) {
      pend.fired = true;
      this.fireProjectiles(a, pend.attack, w);
    }
  }

  private fireProjectiles(a: Actor, atk: EnemyAttack, w: World): void {
    const spec = atk.projectile!;
    const from = a.socketPos('weapon');
    const t = this.target;
    let aim: THREE.Vector3;
    if (t) {
      const dist = from.distanceTo(t.center());
      // Lead the target a little (fast fighters still outrun it).
      const lead = t.center().addScaledVector(t.velocity.clone().setY(0), (dist / spec.speed) * 0.5);
      aim = lead.sub(from).normalize();
    } else aim = a.forward();
    const count = spec.count ?? 1;
    w.audio.play('enemy_bolt', from);
    w.vfx.emit('glow', from, 6, { speed: [1, 3], life: 0.25, size: 0.6, color: spec.color });
    for (let i = 0; i < count; i++) {
      const ang = count > 1 ? (i - (count - 1) / 2) * (spec.spread ?? 0.2) : 0;
      const dir = aim.clone().applyAxisAngle(new THREE.Vector3(0, 1, 0), ang);
      const mesh = new THREE.Group();
      const core = new THREE.Mesh(new THREE.SphereGeometry(spec.radius * 0.55, 10, 8), new THREE.MeshBasicMaterial({ color: 0xffd0d8 }));
      const halo = new THREE.Sprite(new THREE.SpriteMaterial({ map: Textures.soft(), color: spec.color, blending: THREE.AdditiveBlending, depthWrite: false, transparent: true }));
      halo.scale.setScalar(spec.radius * 4);
      mesh.add(core, halo);
      w.projectiles.spawn({
        owner: a,
        position: from,
        velocity: dir.multiplyScalar(spec.speed),
        radius: spec.radius,
        lifetime: 2.5,
        mesh,
        homing: 0.25,
        target: t,
        onUpdate(p) {
          w.vfx.emit('glow', p.position, 1, { speed: 0.2, life: 0.25, size: spec.radius * 2, sizeEnd: 0.2, color: spec.color });
        },
        onHit(p, target) {
          const r = w.combat.dealDamage(a, target, { amount: a.stats.attackDamage * spec.damage, element: 'void', knockback: 4, hitstun: 0.3, stagger: 35, dir: p.velocity.clone().setY(0).normalize() });
          return r ? true : false;
        },
        onImpact(p, pos) {
          w.vfx.emit('glow', pos, 8, { speed: [2, 5], life: 0.3, size: 0.5, color: spec.color });
          w.vfx.emit('spark', pos, 6, { speed: [3, 7], life: 0.3, size: 0.2, color: spec.color });
        },
      });
    }
  }

  onDamaged(a: Actor, result: DamageResult, attacker: Actor | null, w: World): void {
    if (attacker && attacker.faction !== a.faction && attacker.targetable && !attacker.stealthed) {
      // Aggro onto whoever hit us (clones included).
      if (!this.target || Math.random() < 0.6) this.target = attacker;
      this.lastSeen.copy(attacker.position);
      this.lastSeenTime = w.time;
    }
    if (a.state !== 'attack') {
      this.releaseToken();
      this.clearTelegraph(w);
    }
    // Ranged units scatter when struck.
    if (this.isRanged && Math.random() < 0.3) this.panicTimer = Math.max(this.panicTimer, 0.8);
  }

  private releaseToken(): void {
    if (this.tokenHeld) {
      this.tokenHeld = false;
    }
    for (const x of EnemyAI.attackers) if (!x.alive || x.state !== 'attack' || x.removed) EnemyAI.attackers.delete(x);
  }

  /** Hides wind-up markers when an attack is interrupted. */
  private clearTelegraph(w: World): void {
    for (const m of this.telegraphs) m.visible = false;
    this.telegraphs = [];
    void w;
  }
}
