import * as THREE from 'three';
import type { Actor } from '../entities/Actor';
import type { AttackContext, AttackStep, MeleeHitSpec } from '../data/types';
import type { World } from '../core/World';
import type { TrailHandle } from '../vfx/VFXManager';

/**
 * Executes one melee attack step (basic attack, combo step or enemy swing):
 * animation, lunge, aim assist, swing trails and hit frames.
 */
export class MeleeRunner {
  t = 0;
  readonly duration: number;
  readonly speed: number;
  private nextHit = 0;
  private cancelled = false;
  private trails: (TrailHandle | null)[] = [];
  private lungeDir = new THREE.Vector3();
  private ctx: AttackContext;
  private struck = new Set<Actor>();

  constructor(public actor: Actor, public step: AttackStep, public world: World, public damageScale = 1) {
    this.speed = Math.max(0.2, actor.stats.attackSpeed * actor.effects.mods.attackSpeed);
    this.duration = step.duration / this.speed;
    this.ctx = { attacker: actor, world, step, hitIndex: 0 };

    // Aim assist: snap toward the best target in reach.
    const reach = Math.max(...step.hits.map((h) => h.range), 1) + (step.lunge ?? 0) + 2.5;
    const target = world.combat.pickMeleeTarget(actor, reach);
    if (target) actor.faceTowards(target.position);
    actor.forward(this.lungeDir);

    actor.anim.play(step.anim, { duration: this.duration, restart: true, fade: 0.05 });
    if (step.swingSound) world.audio.play(step.swingSound, actor.position, { pitch: 0.95 + Math.random() * 0.1 });
    actor.scripted = true;
    step.onStart?.(this.ctx);
    this.trails = (step.trail ?? []).map(() => null);
  }

  canCancel(): boolean {
    return this.t * this.speed >= this.step.cancelTime;
  }

  /** Returns true when the step has finished. */
  update(dt: number): boolean {
    if (this.cancelled) return true;
    this.t += dt;
    const ut = this.t * this.speed;
    const a = this.actor;
    const s = this.step;

    if (s.lunge && s.lungeStart !== undefined && s.lungeEnd !== undefined && ut >= s.lungeStart && ut <= s.lungeEnd) {
      const window = (s.lungeEnd - s.lungeStart) / this.speed;
      const v = (s.lunge * Math.max(0.6, a.effects.mods.scale)) / window;
      // Stop lunging when already touching the target.
      const target = this.world.combat.pickMeleeTarget(a, 1.2 + a.radius);
      const k = target ? 0.15 : 1;
      a.velocity.x = this.lungeDir.x * v * k;
      a.velocity.z = this.lungeDir.z * v * k;
    } else if (a.grounded) {
      a.velocity.x *= Math.max(0, 1 - dt * 14);
      a.velocity.z *= Math.max(0, 1 - dt * 14);
    }

    // Swing trails.
    if (s.trail) {
      s.trail.forEach((tr, i) => {
        if (!this.trails[i] && ut >= tr.from && ut < tr.to) {
          const sock = a.rig.sockets[tr.socket] ?? a.rig.sockets.handR;
          this.trails[i] = this.world.vfx.trail(sock, tr.color, tr.width ?? 0.35 * a.scale);
        } else if (this.trails[i] && ut >= tr.to) {
          this.trails[i]!.stop();
          this.trails[i] = null;
        }
      });
    }

    while (this.nextHit < s.hits.length && ut >= s.hits[this.nextHit].time) {
      this.ctx.hitIndex = this.nextHit;
      this.doHit(s.hits[this.nextHit]);
      this.nextHit++;
    }

    if (this.t >= this.duration) {
      this.finish();
      return true;
    }
    return false;
  }

  private doHit(h: MeleeHitSpec): void {
    const a = this.actor;
    const w = this.world;
    const scaleMul = a.effects.mods.scale * a.effects.mods.range;
    const range = h.range * scaleMul;
    const targets = w.combat.queryArc(a, range, h.arc, (h.heightMin ?? -0.6) * a.scale, (h.heightMax ?? 2.4) * a.scale);
    const fwd = a.forward();
    for (const t of targets) {
      if (this.step.hitOnce) {
        if (this.struck.has(t)) continue;
        this.struck.add(t);
      }
      const result = w.combat.dealDamage(a, t, {
        amount: a.stats.attackDamage * h.damage * this.damageScale,
        element: h.element ?? 'physical',
        knockback: h.knockback,
        launch: h.launch,
        hitstun: h.hitstun,
        stagger: h.stagger,
        hitstop: h.hitstop,
        shake: h.shake,
        critBonus: h.critBonus,
        dir: fwd.clone().lerp(t.position.clone().sub(a.position).setY(0).normalize(), 0.5).normalize(),
        heavy: (h.hitstop ?? 0) > 0.07,
      });
      if (result) this.step.onHit?.(this.ctx, t, result);
    }
    // Environmental damage.
    const center = a.position.clone().addScaledVector(fwd, range * 0.6).setY(a.position.y + 1);
    w.arena.damageInSphere(center, range * 0.6, a.stats.attackDamage * h.damage, fwd);
    this.step.onHitFrame?.(this.ctx);
  }

  private finish(): void {
    for (const tr of this.trails) tr?.stop();
    this.trails = [];
    this.actor.scripted = false;
  }

  cancel(): void {
    if (this.cancelled) return;
    this.cancelled = true;
    this.finish();
  }
}
