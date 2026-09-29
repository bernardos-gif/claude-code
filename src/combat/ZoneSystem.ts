import * as THREE from 'three';
import type { Actor } from '../entities/Actor';
import type { World } from '../core/World';

export interface ZoneOptions {
  owner: Actor;
  position: THREE.Vector3;
  radius: number;
  duration: number;
  height?: number;
  /** Zone moves with this actor. */
  follow?: Actor;
  tickInterval?: number;
  /** Called every tick with the hostile actors currently inside. */
  onTick?(zone: Zone, targets: Actor[]): void;
  onUpdate?(zone: Zone, dt: number): void;
  onEnd?(zone: Zone): void;
  /** Enemy AI steers around harmful zones. */
  harmful?: boolean;
  visual?: THREE.Object3D;
  /** Seconds to fade the visual out at the end. */
  fadeOut?: number;
}

/** Persistent area effects: burning ground, tornadoes, static fields, smoke. */
export class Zone {
  readonly position: THREE.Vector3;
  radius: number;
  age = 0;
  alive = true;
  tickTimer = 0;
  readonly data: Record<string, any> = {};

  constructor(public readonly opts: ZoneOptions) {
    this.position = opts.position.clone();
    this.radius = opts.radius;
  }

  get remaining(): number {
    return this.opts.duration - this.age;
  }

  /** 0..1 fade factor for visuals near the end of life. */
  get fade(): number {
    const f = this.opts.fadeOut ?? 0.5;
    return Math.min(1, this.age / 0.15, Math.max(0, this.remaining) / f);
  }

  contains(p: THREE.Vector3, pad = 0): boolean {
    const dx = p.x - this.position.x;
    const dz = p.z - this.position.z;
    const h = this.opts.height ?? 3;
    return dx * dx + dz * dz <= (this.radius + pad) * (this.radius + pad) && p.y >= this.position.y - 1.5 && p.y <= this.position.y + h;
  }

  end(): void {
    this.age = Math.max(this.age, this.opts.duration);
  }
}

export class ZoneSystem {
  readonly list: Zone[] = [];

  constructor(private world: World) {}

  spawn(opts: ZoneOptions): Zone {
    const z = new Zone(opts);
    z.tickTimer = 0;
    if (opts.visual) {
      opts.visual.position.copy(z.position);
      this.world.scene.add(opts.visual);
    }
    this.list.push(z);
    return z;
  }

  /** Hostile actors inside a zone. */
  targetsIn(z: Zone): Actor[] {
    const out: Actor[] = [];
    for (const a of this.world.combat.hostilesOf(z.opts.owner.faction)) {
      if (z.contains(a.position, a.radius)) out.push(a);
    }
    return out;
  }

  /** Harmful zones affecting a given faction that contain p (used by AI). */
  dangerAt(p: THREE.Vector3, faction: string, pad = 1): Zone | null {
    for (const z of this.list) {
      if (!z.alive || z.opts.harmful === false || z.opts.owner.faction === faction) continue;
      if (z.contains(p, pad)) return z;
    }
    return null;
  }

  update(dt: number): void {
    for (let i = this.list.length - 1; i >= 0; i--) {
      const z = this.list[i];
      const o = z.opts;
      z.age += dt;
      if (o.follow) {
        if (o.follow.alive) z.position.copy(o.follow.position);
        else z.end();
      }
      o.onUpdate?.(z, dt);
      if (o.tickInterval && o.onTick) {
        z.tickTimer -= dt;
        if (z.tickTimer <= 0) {
          z.tickTimer += o.tickInterval;
          o.onTick(z, this.targetsIn(z));
        }
      }
      if (o.visual) o.visual.position.copy(z.position);
      if (z.age >= o.duration) {
        z.alive = false;
        o.onEnd?.(z);
        if (o.visual) this.world.scene.remove(o.visual);
        this.list.splice(i, 1);
      }
    }
  }

  clear(): void {
    for (const z of this.list) {
      z.alive = false;
      if (z.opts.visual) this.world.scene.remove(z.opts.visual);
    }
    this.list.length = 0;
  }
}
