import type { Actor } from '../entities/Actor';

/** Health pool for a single actor. */
export class Health {
  current: number;
  /** Trails behind `current` for the HUD "recent damage" bar. */
  displayed: number;
  lastDamageTime = -999;
  totalDamageTaken = 0;

  constructor(public max: number) {
    this.current = max;
    this.displayed = max;
  }

  get ratio(): number {
    return this.max > 0 ? this.current / this.max : 0;
  }

  get dead(): boolean {
    return this.current <= 0;
  }

  /** Returns the damage actually applied. */
  damage(amount: number, time: number): number {
    if (this.dead || amount <= 0) return 0;
    const applied = Math.min(this.current, amount);
    this.current -= applied;
    this.lastDamageTime = time;
    this.totalDamageTaken += applied;
    return applied;
  }

  heal(amount: number): number {
    if (this.dead) return 0;
    const before = this.current;
    this.current = Math.min(this.max, this.current + amount);
    return this.current - before;
  }

  setMax(max: number, keepRatio = true): void {
    const r = this.ratio;
    this.max = max;
    this.current = keepRatio ? max * r : Math.min(this.current, max);
  }

  reset(): void {
    this.current = this.max;
    this.displayed = this.max;
  }
}

/**
 * Per-frame health bookkeeping: smooth damage trails for UI and death detection.
 */
export class HealthSystem {
  update(actors: Actor[], dt: number): void {
    for (const a of actors) {
      const h = a.health;
      if (h.displayed > h.current) {
        // Hold briefly after damage, then drain.
        const since = a.worldTime - h.lastDamageTime;
        if (since > 0.45) h.displayed = Math.max(h.current, h.displayed - h.max * 0.6 * dt);
      } else {
        h.displayed = h.current;
      }
    }
  }
}
