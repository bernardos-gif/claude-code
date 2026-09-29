import * as THREE from 'three';
import type { AbilityDef } from '../data/types';
import type { Actor } from '../entities/Actor';
import type { World } from '../core/World';
import type { PlayOptions } from '../characters/AnimationController';
import { clamp01, yawFromDir } from '../core/math';

type SpanFn = (dt: number, local: number, t01: number) => void;

/**
 * Timeline for a single ability cast. Ability definitions describe their
 * behaviour declaratively with at()/during()/every() instead of hand-written
 * state machines, which keeps each of the 24 abilities short and readable.
 */
export class AbilityCast {
  t = 0;
  endTime = Infinity;
  finished = false;
  interrupted = false;
  uninterruptible = false;
  readonly locks: boolean;
  readonly data: Record<string, any> = {};
  private events: { time: number; fn: () => void; done: boolean }[] = [];
  private spans: { start: number; end: number; fn: SpanFn }[] = [];
  private endHandlers: ((interrupted: boolean) => void)[] = [];

  constructor(
    public readonly caster: Actor,
    public readonly world: World,
    public readonly def: AbilityDef,
    public readonly slot: number,
  ) {
    this.locks = !def.freeMovement;
  }

  at(time: number, fn: () => void): this {
    this.events.push({ time, fn, done: false });
    return this;
  }

  during(start: number, end: number, fn: SpanFn): this {
    this.spans.push({ start, end, fn });
    return this;
  }

  every(interval: number, start: number, end: number, fn: (i: number) => void): this {
    let i = 0;
    for (let t = start; t <= end + 1e-6; t += interval) {
      const idx = i++;
      this.at(t, () => fn(idx));
    }
    return this;
  }

  end(time: number): this {
    this.endTime = time;
    return this;
  }

  onEnd(fn: (interrupted: boolean) => void): this {
    this.endHandlers.push(fn);
    return this;
  }

  finish(): void {
    if (this.finished) return;
    this.finished = true;
    for (const fn of this.endHandlers) fn(this.interrupted);
  }

  interrupt(): void {
    if (this.finished || this.uninterruptible) return;
    this.interrupted = true;
    this.finish();
  }

  // ------------------------------------------------------------ helpers --
  anim(name: string, opts: PlayOptions = {}): void {
    this.caster.anim.play(name, { fade: 0.06, restart: true, ...opts });
  }

  superArmor(start: number, end: number): this {
    return this.during(start, end, () => (this.caster.effects.transient.superArmor = true));
  }

  invulnerable(start: number, end: number): this {
    return this.during(start, end, () => (this.caster.effects.transient.invulnerable = true));
  }

  /** Ability damage scaled by the caster's ability power. */
  dmg(base = this.def.damage): number {
    return base * this.caster.stats.abilityPower;
  }

  /** Locked target, or the best enemy in the aim cone. */
  findTarget(range: number, coneDeg = 75): Actor | null {
    const c = this.caster;
    const lock = c.target;
    if (lock && lock.targetable && lock.position.distanceTo(c.position) <= range) return lock;
    const dir = this.aimDir(false);
    return this.world.combat.nearestHostile(c.faction, c.position, range, dir, coneDeg) ?? null;
  }

  /** Aim direction: input direction, else camera forward (player) or facing. */
  aimDir(useTarget = true, range = 30): THREE.Vector3 {
    const c = this.caster;
    if (useTarget) {
      const t = this.findTarget(range);
      if (t) return t.position.clone().sub(c.position).setY(0).normalize();
    }
    const input = c.userData.inputDir as THREE.Vector3 | undefined;
    if (input && input.lengthSq() > 0.01) return input.clone().setY(0).normalize();
    const aim = c.userData.aimDir as THREE.Vector3 | undefined;
    if (aim && aim.lengthSq() > 0.01) return aim.clone().setY(0).normalize();
    return c.forward();
  }

  faceAim(range = 30): THREE.Vector3 {
    const d = this.aimDir(true, range);
    this.caster.facing = yawFromDir(d.x, d.z);
    return d;
  }

  stop(): void {
    this.caster.velocity.x = 0;
    this.caster.velocity.z = 0;
  }

  update(dt: number): void {
    if (this.finished) return;
    const prev = this.t;
    this.t += dt;
    for (const e of this.events) {
      if (!e.done && this.t >= e.time) {
        e.done = true;
        e.fn();
        if (this.finished) return;
      }
    }
    for (const s of this.spans) {
      if (this.t >= s.start && prev < s.end) {
        const local = Math.min(this.t, s.end) - s.start;
        s.fn(dt, local, clamp01(local / Math.max(1e-4, s.end - s.start)));
        if (this.finished) return;
      }
    }
    if (this.t >= this.endTime) this.finish();
  }
}

/** Per-actor ability slots, cooldowns, charges and ultimate meter. */
export class AbilitySystem {
  readonly cooldowns: number[];
  readonly charges: number[];
  readonly maxCharges: number[];
  ult = 0;
  readonly ultMax = 100;
  active: AbilityCast | null = null;
  readonly background: AbilityCast[] = [];
  lastFailReason = '';
  /** Debug: disables cooldowns & meter cost. */
  freeCasting = false;

  constructor(public readonly owner: Actor, public readonly defs: AbilityDef[]) {
    this.cooldowns = defs.map(() => 0);
    this.maxCharges = defs.map((d) => d.charges ?? 1);
    this.charges = [...this.maxCharges];
  }

  cooldownOf(slot: number): number {
    return this.defs[slot].cooldown * this.owner.stats.cooldownMultiplier;
  }

  get ultReady(): boolean {
    return this.ult >= this.ultMax;
  }

  addUltCharge(n: number): void {
    const was = this.ultReady;
    this.ult = Math.min(this.ultMax, this.ult + n);
    if (!was && this.ultReady) this.owner.userData.ultJustReady = true;
  }

  isReady(slot: number): boolean {
    const d = this.defs[slot];
    if (this.freeCasting) return true;
    if (d.ultimate) return this.ultReady;
    return this.charges[slot] > 0;
  }

  /** Remaining cooldown fraction (0 = ready) for the HUD. */
  cooldownFraction(slot: number): number {
    const d = this.defs[slot];
    if (d.ultimate) return 1 - this.ult / this.ultMax;
    if (this.charges[slot] > 0) return 0;
    return this.cooldowns[slot] / this.cooldownOf(slot);
  }

  get busy(): boolean {
    return !!this.active && !this.active.finished;
  }

  tryCast(slot: number, world: World): boolean {
    const a = this.owner;
    const def = this.defs[slot];
    if (!def) return false;
    this.lastFailReason = '';
    if (this.busy) return this.fail('busy');
    const canCancelAttack = a.state === 'attack' && a.attack?.canCancel();
    const canCancelDodge = a.state === 'dodge' && a.stateTime > a.stats.dodgeDuration * 0.5;
    if (!a.canAct && !canCancelAttack && !canCancelDodge) return this.fail('busy');
    if (!a.grounded && !def.castInAir) return this.fail('grounded');
    if (!this.isReady(slot)) return this.fail(def.ultimate ? 'meter' : 'cooldown');
    if (def.canCast && !def.canCast(a, world)) return this.fail('target');

    if (!this.freeCasting) {
      if (def.ultimate) this.ult = 0;
      else {
        if (this.charges[slot] === this.maxCharges[slot]) this.cooldowns[slot] = this.cooldownOf(slot);
        this.charges[slot]--;
      }
    }
    if (a.attack) {
      a.attack.cancel();
      a.attack = null;
    }
    const cast = new AbilityCast(a, world, def, slot);
    if (cast.locks) {
      this.active = cast;
      a.setState('ability');
      a.scripted = true;
      if (a.grounded) {
        a.velocity.x *= 0.2;
        a.velocity.z *= 0.2;
      }
    } else {
      this.background.push(cast);
    }
    def.cast(cast);
    world.events.emit('abilityCast', a, def, slot);
    return true;
  }

  private fail(reason: string): boolean {
    this.lastFailReason = reason;
    return false;
  }

  update(dt: number, world: World): void {
    const rate = this.owner.effects.mods.cooldownRate;
    for (let i = 0; i < this.defs.length; i++) {
      if (this.defs[i].ultimate) continue;
      if (this.charges[i] < this.maxCharges[i]) {
        this.cooldowns[i] -= dt * rate;
        if (this.cooldowns[i] <= 0) {
          this.charges[i]++;
          this.cooldowns[i] = this.charges[i] < this.maxCharges[i] ? this.cooldownOf(i) : 0;
        }
      }
    }
    if (this.active) {
      this.active.update(dt);
      if (this.active.finished) {
        this.active = null;
        if (this.owner.state === 'ability') this.owner.returnToLocomotion();
      }
    }
    for (let i = this.background.length - 1; i >= 0; i--) {
      this.background[i].update(dt);
      if (this.background[i].finished) this.background.splice(i, 1);
    }
  }

  interrupt(world: World): void {
    if (this.active && !this.active.uninterruptible) {
      this.active.interrupt();
      this.active = null;
    }
  }

  /** Called when the actor must be reset (death, restart). */
  cancelAll(): void {
    if (this.active) {
      this.active.uninterruptible = false;
      this.active.interrupt();
    }
    this.active = null;
    for (const b of this.background) {
      b.uninterruptible = false;
      b.interrupt();
    }
    this.background.length = 0;
  }

  resetCooldowns(): void {
    for (let i = 0; i < this.defs.length; i++) {
      this.cooldowns[i] = 0;
      this.charges[i] = this.maxCharges[i];
    }
  }
}
