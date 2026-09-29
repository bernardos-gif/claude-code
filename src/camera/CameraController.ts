import * as THREE from 'three';
import type { Actor } from '../entities/Actor';
import type { Arena } from '../world/Arena';
import type { InputManager } from '../core/InputManager';
import type { CameraProfile } from '../data/types';
import { clamp, damp, dampAngle, yawFromDir } from '../core/math';

export interface CinematicShot {
  /** Returns camera position and look target for time t (seconds since start). */
  sample(t: number, outPos: THREE.Vector3, outLook: THREE.Vector3): void;
  duration: number;
}

/**
 * Smooth third-person orbit camera with collision, trauma-based shake,
 * FOV kicks, soft lock-on and scripted cinematic shots.
 */
export class CameraController {
  readonly camera: THREE.PerspectiveCamera;
  yaw = Math.PI;
  pitch = -0.28;
  private distance = 6;
  private curDist = 6;
  private profile: CameraProfile = { distance: 6, height: 1.6, shoulder: 0.6, fov: 62 };
  private pivot = new THREE.Vector3();
  private trauma = 0;
  private fovKick = 0;
  private zoom = 1;
  private shakeTime = 0;
  private cine: CinematicShot | null = null;
  private cineT = 0;
  private cineBlend = 0;
  private cinePos = new THREE.Vector3();
  private cineLook = new THREE.Vector3();
  private tmp = new THREE.Vector3();
  /** Extra distance multiplier (Colossus zooms out). */
  distanceScale = 1;
  lockTarget: Actor | null = null;
  private idleTime = 0;
  private alignYaw: number | null = null;
  private alignTime = 0;

  constructor(aspect: number) {
    this.camera = new THREE.PerspectiveCamera(62, aspect, 0.1, 2000);
    this.camera.position.set(0, 5, -10);
  }

  setProfile(p: CameraProfile): void {
    this.profile = p;
    this.distance = p.distance;
    this.curDist = p.distance;
    this.camera.fov = p.fov;
    this.camera.updateProjectionMatrix();
  }

  /** Flattened camera forward (aim direction for abilities). */
  forward(out = new THREE.Vector3()): THREE.Vector3 {
    return out.set(Math.sin(this.yaw), 0, Math.cos(this.yaw));
  }

  right(out = new THREE.Vector3()): THREE.Vector3 {
    return out.set(-Math.cos(this.yaw), 0, Math.sin(this.yaw));
  }

  addShake(amount: number, at?: THREE.Vector3): void {
    let a = amount;
    if (at) {
      const d = at.distanceTo(this.pivot);
      a *= clamp(1.4 - d / 40, 0.1, 1);
    }
    this.trauma = Math.min(1, this.trauma + a);
  }

  kickFov(amount: number): void {
    this.fovKick = Math.max(this.fovKick, amount);
  }

  /** Smoothly swing the camera behind a new facing (after teleports). */
  alignTo(yaw: number, duration = 0.35): void {
    this.alignYaw = yaw;
    this.alignTime = duration;
  }

  playCinematic(shot: CinematicShot): void {
    this.cine = shot;
    this.cineT = 0;
  }

  stopCinematic(): void {
    this.cine = null;
  }

  get inCinematic(): boolean {
    return !!this.cine;
  }

  snapBehind(target: Actor): void {
    this.yaw = target.facing;
    this.pitch = -0.28;
    this.pivot.copy(target.position).setY(target.position.y + this.profile.height * target.scale);
    this.curDist = this.distance;
    this.apply(target, 0, null);
  }

  update(dt: number, target: Actor | null, input: InputManager | null, arena: Arena | null, gameplay: boolean): void {
    if (input && gameplay) {
      const sens = 0.0024 * input.settings.mouseSensitivity;
      const moved = Math.abs(input.mouseDX) + Math.abs(input.mouseDY);
      this.yaw -= input.mouseDX * sens;
      this.pitch -= input.mouseDY * sens * (input.settings.invertY ? -1 : 1);
      this.pitch = clamp(this.pitch, -1.2, 0.55);
      if (input.wheel) this.zoom = clamp(this.zoom + input.wheel * 0.1, 0.6, 1.6);
      this.idleTime = moved > 0 ? 0 : this.idleTime + dt;
      if (this.alignYaw !== null) {
        this.alignTime -= dt;
        this.yaw = dampAngle(this.yaw, this.alignYaw, 10, dt);
        if (this.alignTime <= 0 || moved > 4) this.alignYaw = null;
      }
      // Soft lock-on: drift toward the locked target when the mouse is idle.
      if (this.lockTarget && target && this.lockTarget.targetable && this.idleTime > 0.15) {
        const dx = this.lockTarget.position.x - target.position.x;
        const dz = this.lockTarget.position.z - target.position.z;
        if (dx * dx + dz * dz > 4) this.yaw = dampAngle(this.yaw, yawFromDir(dx, dz), 3.5, dt);
      }
    }
    this.apply(target, dt, arena);
  }

  private apply(target: Actor | null, dt: number, arena: Arena | null): void {
    const cam = this.camera;
    if (target) {
      const s = target.scale;
      const want = this.tmp.copy(target.position);
      want.y += this.profile.height * s;
      if (dt > 0) {
        this.pivot.x = damp(this.pivot.x, want.x, 14, dt);
        this.pivot.z = damp(this.pivot.z, want.z, 14, dt);
        this.pivot.y = damp(this.pivot.y, want.y, 7, dt);
      } else this.pivot.copy(want);
    }
    const scaleK = target ? Math.max(1, target.scale / target.stats.scale) : 1;
    this.distance = this.profile.distance * this.zoom * this.distanceScale * (0.7 + 0.3 * scaleK);
    const dir = new THREE.Vector3(Math.sin(this.yaw) * Math.cos(this.pitch), Math.sin(this.pitch), Math.cos(this.yaw) * Math.cos(this.pitch));
    const right = this.right();
    const shoulder = this.profile.shoulder * (target ? target.scale : 1);
    const origin = this.pivot.clone().addScaledVector(right, shoulder);

    let want = this.distance;
    if (arena) {
      const back = dir.clone().multiplyScalar(-1);
      const free = arena.raycast(origin, back, this.distance, 0.3);
      want = Math.min(want, free);
    }
    if (dt > 0) this.curDist = want < this.curDist ? damp(this.curDist, want, 25, dt) : damp(this.curDist, want, 3, dt);
    else this.curDist = want;
    const pos = origin.clone().addScaledVector(dir, -this.curDist);
    if (arena) {
      const g = arena.terrainHeight(pos.x, pos.z) + 0.4;
      if (pos.y < g) pos.y = g;
    }
    const look = origin.clone().addScaledVector(dir, 10);

    // Cinematic override.
    if (this.cine) {
      this.cineT += dt;
      this.cine.sample(this.cineT, this.cinePos, this.cineLook);
      this.cineBlend = Math.min(1, this.cineBlend + dt * 4);
      if (this.cineT >= this.cine.duration) this.cine = null;
    } else {
      this.cineBlend = Math.max(0, this.cineBlend - dt * 2.5);
    }
    if (this.cineBlend > 0) {
      const k = this.cineBlend * this.cineBlend * (3 - 2 * this.cineBlend);
      pos.lerp(this.cinePos, k);
      look.lerp(this.cineLook, k);
    }

    // Trauma shake.
    this.shakeTime += dt;
    this.trauma = Math.max(0, this.trauma - dt * 1.3);
    const sh = this.trauma * this.trauma;
    const t = this.shakeTime * 28;
    const off = new THREE.Vector3(Math.sin(t * 1.1) + Math.sin(t * 2.3) * 0.5, Math.sin(t * 1.7 + 1) + Math.sin(t * 3.1) * 0.4, Math.sin(t * 1.3 + 2)).multiplyScalar(sh * 0.55);
    cam.position.copy(pos).add(off);
    cam.lookAt(look);
    cam.rotateZ(Math.sin(t * 0.9 + 3) * sh * 0.05);

    this.fovKick = damp(this.fovKick, 0, 5, dt || 0.016);
    const fov = this.profile.fov + this.fovKick;
    if (Math.abs(cam.fov - fov) > 0.01) {
      cam.fov = fov;
      cam.updateProjectionMatrix();
    }
  }

  resize(aspect: number): void {
    this.camera.aspect = aspect;
    this.camera.updateProjectionMatrix();
  }
}
