import type { Actor } from './Actor';
import type { World } from '../core/World';
import { moveAngleTowards, yawFromDir, angleDiff } from '../core/math';

/**
 * Kinematic character physics shared by every actor: acceleration toward the
 * controller's desired velocity, gravity, step-up, ground snapping, wall
 * collision against the arena and soft actor-vs-actor separation.
 */
export class CharacterController {
  readonly gravity = 30;
  readonly stepHeight = 0.6;

  constructor(private world: World) {}

  step(actors: Actor[], dt: number): void {
    for (const a of actors) {
      if (a.removed || a.hidden || a.effects.flags.frozen) continue;
      this.move(a, dt);
    }
    this.separate(actors);
  }

  private move(a: Actor, dt: number): void {
    const arena = this.world.arena;
    const mods = a.effects.mods;
    const flags = a.effects.flags;
    const v = a.velocity;
    const prevFacing = a.facing;

    switch (a.state) {
      case 'idle':
      case 'move':
      case 'air': {
        const speed = flags.rooted ? 0 : a.stats.moveSpeed * mods.moveSpeed * (a.moveScale < 1 ? a.stats.walkSpeed / a.stats.moveSpeed : 1);
        const tx = a.moveDir.x * speed;
        const tz = a.moveDir.z * speed;
        const accel = a.grounded ? a.stats.acceleration : a.stats.acceleration * 0.35;
        const k = Math.min(1, accel * dt);
        // Preserve extra momentum in the air (after dashes / knockbacks).
        if (!a.grounded && Math.hypot(v.x, v.z) > speed && a.moveDir.lengthSq() < 0.01) {
          v.x *= 1 - dt * 0.8;
          v.z *= 1 - dt * 0.8;
        } else {
          v.x += (tx - v.x) * k;
          v.z += (tz - v.z) * k;
        }
        if (a.moveDir.lengthSq() > 0.01 && !a.userData.strafe) {
          const yaw = yawFromDir(a.moveDir.x, a.moveDir.z);
          a.facing = moveAngleTowards(a.facing, yaw, a.stats.turnSpeed * dt * (a.grounded ? 1 : 0.6));
        }
        break;
      }
      case 'attack':
      case 'ability':
      case 'dodge':
        // Scripted: velocity is authoritative (set by runners / abilities).
        if (!a.scripted && a.grounded) {
          v.x *= Math.max(0, 1 - dt * 10);
          v.z *= Math.max(0, 1 - dt * 10);
        }
        break;
      case 'knockback':
        v.x *= Math.max(0, 1 - dt * 0.6);
        v.z *= Math.max(0, 1 - dt * 0.6);
        break;
      default:
        if (a.grounded) {
          v.x *= Math.max(0, 1 - dt * 9);
          v.z *= Math.max(0, 1 - dt * 9);
        }
        break;
    }
    a.userData.turnRate = dt > 0 ? angleDiff(prevFacing, a.facing) / dt : 0;

    if (a.noGravity <= 0 || a.state === 'dead') v.y -= this.gravity * a.stats.gravityScale * mods.gravity * dt;
    if (v.y < -60) v.y = -60;

    // Integrate in sub-steps so fast dashes do not tunnel through walls.
    const p = a.position;
    const horiz = Math.hypot(v.x, v.z) * dt;
    const steps = Math.min(10, Math.max(1, Math.ceil(horiz / Math.max(0.15, a.radius * 0.7))));
    const sdt = dt / steps;
    a.hitWall = false;
    const height = a.height * 0.9;
    for (let i = 0; i < steps; i++) {
      p.x += v.x * sdt;
      p.z += v.z * sdt;
      p.y += v.y * sdt;
      if (arena.resolveCircle(p, a.radius, height, this.stepHeight)) a.hitWall = true;
    }

    // Ceiling check (floating platforms).
    if (v.y > 0 && arena.solidAt(p.clone().setY(p.y + height), 0)) v.y = 0;

    const ground = arena.groundHeight(p.x, p.z, p.y + this.stepHeight);
    const wasGrounded = a.grounded;
    if (v.y <= 0 && p.y <= ground + 0.02) {
      const fall = -v.y;
      p.y = ground;
      v.y = 0;
      a.grounded = true;
      if (!wasGrounded) a.onLanded(this.world, fall);
    } else if (wasGrounded && v.y <= 0 && p.y - ground < 0.5 && a.state !== 'knockback') {
      p.y = ground; // walk down steps / slopes
      v.y = 0;
      a.grounded = true;
    } else {
      if (wasGrounded) a.fallPeakY = p.y;
      a.grounded = false;
      a.fallPeakY = Math.max(a.fallPeakY, p.y);
    }
    a.groundY = ground;

    if (p.y < -40) {
      // Safety net: never fall out of the world.
      p.set(0, arena.groundHeight(0, 0) + 2, 0);
      v.set(0, 0, 0);
    }
  }

  private separate(actors: Actor[]): void {
    const n = actors.length;
    for (let i = 0; i < n; i++) {
      const a = actors[i];
      if (!a.alive || a.hidden || a.passThrough || a.removed) continue;
      for (let j = i + 1; j < n; j++) {
        const b = actors[j];
        if (!b.alive || b.hidden || b.passThrough || b.removed) continue;
        if (a.state === 'dodge' || b.state === 'dodge') continue;
        const dx = b.position.x - a.position.x;
        const dz = b.position.z - a.position.z;
        const min = a.radius + b.radius;
        const d2 = dx * dx + dz * dz;
        if (d2 >= min * min) continue;
        if (a.position.y + a.height < b.position.y || b.position.y + b.height < a.position.y) continue;
        const d = Math.sqrt(d2) || 0.001;
        const overlap = min - d;
        const ma = a.stats.mass * a.scale;
        const mb = b.stats.mass * b.scale;
        const wa = mb / (ma + mb);
        const wb = ma / (ma + mb);
        const nx = d2 > 1e-6 ? dx / d : 1;
        const nz = d2 > 1e-6 ? dz / d : 0;
        a.position.x -= nx * overlap * wa;
        a.position.z -= nz * overlap * wa;
        b.position.x += nx * overlap * wb;
        b.position.z += nz * overlap * wb;
      }
    }
  }
}
