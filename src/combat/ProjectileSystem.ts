import * as THREE from 'three';
import type { Actor } from '../entities/Actor';
import type { World } from '../core/World';

export interface ProjectileOptions {
  owner: Actor;
  position: THREE.Vector3;
  velocity: THREE.Vector3;
  radius: number;
  lifetime: number;
  gravity?: number;
  /** Homing turn rate (radians / second) towards `target`. */
  homing?: number;
  target?: Actor | null;
  /** Number of additional targets it passes through. */
  pierce?: number;
  hitWorld?: boolean;
  mesh?: THREE.Object3D;
  /** Orient mesh along velocity. */
  faceVelocity?: boolean;
  spin?: THREE.Vector3;
  onHit?(p: Projectile, target: Actor): boolean | void;
  onImpact?(p: Projectile, pos: THREE.Vector3, target: Actor | null): void;
  onUpdate?(p: Projectile, dt: number): void;
  onExpire?(p: Projectile): void;
}

export class Projectile {
  readonly position: THREE.Vector3;
  readonly velocity: THREE.Vector3;
  readonly prev = new THREE.Vector3();
  age = 0;
  alive = true;
  pierceLeft: number;
  readonly hitSet = new Set<Actor>();
  readonly data: Record<string, any> = {};

  constructor(public readonly opts: ProjectileOptions) {
    this.position = opts.position.clone();
    this.velocity = opts.velocity.clone();
    this.pierceLeft = opts.pierce ?? 0;
  }

  get owner(): Actor {
    return this.opts.owner;
  }
}

const _dir = new THREE.Vector3();
const _to = new THREE.Vector3();
const _axis = new THREE.Vector3();

/** Moves projectiles, sweeps them against hurtboxes and the arena. */
export class ProjectileSystem {
  readonly list: Projectile[] = [];

  constructor(private world: World) {}

  spawn(opts: ProjectileOptions): Projectile {
    const p = new Projectile(opts);
    if (opts.mesh) {
      opts.mesh.position.copy(p.position);
      this.world.scene.add(opts.mesh);
    }
    this.list.push(p);
    return p;
  }

  update(dt: number): void {
    const w = this.world;
    for (let i = this.list.length - 1; i >= 0; i--) {
      const p = this.list[i];
      if (!p.alive) {
        this.remove(i);
        continue;
      }
      const o = p.opts;
      p.age += dt;
      p.prev.copy(p.position);

      if (o.homing && o.target && o.target.targetable) {
        const speed = p.velocity.length();
        _to.copy(o.target.center()).sub(p.position).normalize();
        _dir.copy(p.velocity).normalize();
        const angle = _dir.angleTo(_to);
        if (angle > 1e-3) {
          const step = Math.min(angle, o.homing * dt);
          _axis.crossVectors(_dir, _to).normalize();
          if (_axis.lengthSq() > 0.5) _dir.applyAxisAngle(_axis, step);
          p.velocity.copy(_dir).multiplyScalar(speed);
        }
      }
      if (o.gravity) p.velocity.y -= o.gravity * dt;
      p.position.addScaledVector(p.velocity, dt);

      // Actor sweep.
      const hits = w.combat.querySegment(o.owner.faction, p.prev, p.position, o.radius);
      let stopped = false;
      for (const t of hits) {
        if (p.hitSet.has(t)) continue;
        p.hitSet.add(t);
        if (t.invulnerable) continue;
        const consumed = o.onHit?.(p, t);
        if (consumed === false) continue;
        if (p.pierceLeft > 0) {
          p.pierceLeft--;
        } else {
          o.onImpact?.(p, p.position.clone(), t);
          stopped = true;
          break;
        }
      }
      if (!stopped && o.hitWorld !== false) {
        const hit = w.arena.sweep(p.prev, p.position, o.radius * 0.5);
        if (hit) {
          p.position.copy(hit);
          w.arena.damageInSphere(hit, 2.5, 60, p.velocity.clone().normalize());
          o.onImpact?.(p, hit.clone(), null);
          stopped = true;
        }
      }
      if (stopped) {
        p.alive = false;
      } else if (p.age >= o.lifetime) {
        o.onExpire?.(p);
        p.alive = false;
      } else {
        o.onUpdate?.(p, dt);
      }

      if (o.mesh) {
        o.mesh.position.copy(p.position);
        if (o.faceVelocity && p.velocity.lengthSq() > 1e-4) {
          _to.copy(p.position).add(p.velocity);
          o.mesh.lookAt(_to);
        }
        if (o.spin) {
          o.mesh.rotation.x += o.spin.x * dt;
          o.mesh.rotation.y += o.spin.y * dt;
          o.mesh.rotation.z += o.spin.z * dt;
        }
      }
      if (!p.alive) this.remove(i);
    }
  }

  private remove(i: number): void {
    const p = this.list[i];
    if (p.opts.mesh) this.world.scene.remove(p.opts.mesh);
    this.list.splice(i, 1);
  }

  clear(): void {
    for (let i = this.list.length - 1; i >= 0; i--) this.remove(i);
  }
}
