import type { Actor } from '../entities/Actor';
import type { World } from '../core/World';

/** Multiplicative modifiers (critChance / poise are additive). */
export interface Modifiers {
  moveSpeed: number;
  attackSpeed: number;
  damage: number;
  damageTaken: number;
  knockbackTaken: number;
  scale: number;
  range: number;
  cooldownRate: number;
  critChance: number;
  poise: number;
  gravity: number;
}

export interface Flags {
  stunned: boolean;
  rooted: boolean;
  stealthed: boolean;
  invulnerable: boolean;
  superArmor: boolean;
  untargetable: boolean;
  frozen: boolean;
}

export type StatusIcon = 'burn' | 'stun' | 'slow' | 'static' | 'mark' | 'armor' | 'haste' | 'stealth' | 'blind' | 'giant' | 'storm' | 'realm';

export interface EffectSpec {
  id: string;
  duration: number;
  stacks?: number;
  maxStacks?: number;
  tickInterval?: number;
  mods?: Partial<Modifiers>;
  flags?: Partial<Flags>;
  icon?: StatusIcon;
  source?: Actor | null;
  /** Mods are multiplied per stack when true. */
  stackMods?: boolean;
  /** Refresh (default) or keep the remaining duration when re-applied. */
  refresh?: boolean;
  data?: Record<string, any>;
  onApply?(target: Actor, e: ActiveEffect, world: World): void;
  onTick?(target: Actor, e: ActiveEffect, world: World): void;
  onUpdate?(target: Actor, e: ActiveEffect, dt: number, world: World): void;
  onExpire?(target: Actor, e: ActiveEffect, world: World): void;
  onStack?(target: Actor, e: ActiveEffect, world: World): void;
}

export interface ActiveEffect {
  spec: EffectSpec;
  remaining: number;
  stacks: number;
  tickTimer: number;
  data: Record<string, any>;
}

export const baseModifiers = (): Modifiers => ({
  moveSpeed: 1,
  attackSpeed: 1,
  damage: 1,
  damageTaken: 1,
  knockbackTaken: 1,
  scale: 1,
  range: 1,
  cooldownRate: 1,
  critChance: 0,
  poise: 0,
  gravity: 1,
});

export const baseFlags = (): Flags => ({
  stunned: false,
  rooted: false,
  stealthed: false,
  invulnerable: false,
  superArmor: false,
  untargetable: false,
  frozen: false,
});

const ADDITIVE: (keyof Modifiers)[] = ['critChance', 'poise'];

/** Buffs and debuffs on an actor; recomputes aggregated modifiers every frame. */
export class EffectManager {
  readonly list: ActiveEffect[] = [];
  mods: Modifiers = baseModifiers();
  flags: Flags = baseFlags();
  /** Temporary flags set by running attacks/abilities (reset each frame by their owners). */
  transient: Partial<Flags> = {};

  constructor(private owner: Actor) {}

  has(id: string): boolean {
    return this.list.some((e) => e.spec.id === id);
  }

  get(id: string): ActiveEffect | undefined {
    return this.list.find((e) => e.spec.id === id);
  }

  stacks(id: string): number {
    return this.get(id)?.stacks ?? 0;
  }

  apply(spec: EffectSpec, world: World): ActiveEffect {
    const existing = this.get(spec.id);
    if (existing) {
      const max = spec.maxStacks ?? 1;
      existing.stacks = Math.min(max, existing.stacks + (spec.stacks ?? 1));
      if (spec.refresh !== false) existing.remaining = Math.max(existing.remaining, spec.duration);
      existing.spec = spec;
      spec.onStack?.(this.owner, existing, world);
      this.recompute();
      return existing;
    }
    const e: ActiveEffect = {
      spec,
      remaining: spec.duration,
      stacks: Math.min(spec.maxStacks ?? 1, spec.stacks ?? 1),
      tickTimer: spec.tickInterval ?? 0,
      data: { ...(spec.data ?? {}) },
    };
    this.list.push(e);
    spec.onApply?.(this.owner, e, world);
    this.recompute();
    return e;
  }

  remove(id: string, world: World, silent = false): void {
    const i = this.list.findIndex((e) => e.spec.id === id);
    if (i < 0) return;
    const [e] = this.list.splice(i, 1);
    if (!silent) e.spec.onExpire?.(this.owner, e, world);
    this.recompute();
  }

  clear(world: World, silent = true): void {
    const all = [...this.list];
    this.list.length = 0;
    if (!silent) for (const e of all) e.spec.onExpire?.(this.owner, e, world);
    this.recompute();
  }

  update(dt: number, world: World): void {
    for (let i = this.list.length - 1; i >= 0; i--) {
      const e = this.list[i];
      e.remaining -= dt;
      e.spec.onUpdate?.(this.owner, e, dt, world);
      if (e.spec.tickInterval && e.spec.onTick) {
        e.tickTimer -= dt;
        while (e.tickTimer <= 0 && e.remaining > -dt) {
          e.tickTimer += e.spec.tickInterval;
          e.spec.onTick(this.owner, e, world);
          if (!this.list.includes(e)) break;
        }
      }
      if (e.remaining <= 0 && this.list.includes(e)) {
        this.list.splice(this.list.indexOf(e), 1);
        e.spec.onExpire?.(this.owner, e, world);
      }
    }
    this.recompute();
  }

  recompute(): void {
    const m = baseModifiers();
    const f = baseFlags();
    for (const e of this.list) {
      const mods = e.spec.mods;
      if (mods) {
        const n = e.spec.stackMods ? e.stacks : 1;
        for (const k in mods) {
          const key = k as keyof Modifiers;
          const v = mods[key]!;
          if (ADDITIVE.includes(key)) m[key] += v * n;
          else m[key] *= Math.pow(v, n);
        }
      }
      if (e.spec.flags) {
        for (const k in e.spec.flags) if ((e.spec.flags as any)[k]) (f as any)[k] = true;
      }
    }
    for (const k in this.transient) if ((this.transient as any)[k]) (f as any)[k] = true;
    this.mods = m;
    this.flags = f;
  }
}
