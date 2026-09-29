import * as THREE from 'three';
import { ParticleLayer } from './Particles';
import { Textures } from './Textures';
import type { Actor } from '../entities/Actor';
import { cloneRigVisual } from '../characters/Rig';
import { rand, TAU } from '../core/math';

export type LayerName = 'glow' | 'spark' | 'flame' | 'smoke' | 'dark' | 'dust';

export interface EmitOpts {
  speed?: number | [number, number];
  dir?: THREE.Vector3;
  /** 0 = straight along dir, 1 = full sphere. */
  spread?: number;
  life?: number | [number, number];
  size?: number | [number, number];
  /** End size as a multiple of the start size. */
  sizeEnd?: number;
  color?: number | number[];
  colorEnd?: number;
  alpha?: number;
  alphaEnd?: number;
  gravity?: number;
  drag?: number;
  jitter?: number;
  jitterY?: number;
  velocity?: THREE.Vector3;
  /** Spawn on a horizontal ring of this radius. */
  ring?: number;
  /** Spawn within a horizontal disc of this radius. */
  disc?: number;
  /** Radial outward speed for ring/disc spawns. */
  radial?: number;
}

export interface TrailHandle {
  stop(): void;
}

interface Timed {
  obj: THREE.Object3D | null;
  age: number;
  dur: number;
  update?: (t: number, dt: number) => void;
  end?: () => void;
  parent?: THREE.Object3D;
}

const tmpColor = new THREE.Color();
const tmpColor2 = new THREE.Color();
const _v = new THREE.Vector3();
const _v2 = new THREE.Vector3();
const UP = new THREE.Vector3(0, 1, 0);

function range(v: number | [number, number] | undefined, def: number): number {
  if (v === undefined) return def;
  if (typeof v === 'number') return v;
  return rand(v[0], v[1]);
}

/** Builds a two-plane crossed ribbon along a polyline (visible from any angle). */
export function ribbonGeometry(points: THREE.Vector3[], width: number, taper = true): THREE.BufferGeometry {
  const n = points.length;
  const pos = new Float32Array(n * 4 * 3);
  const idx: number[] = [];
  const dir = new THREE.Vector3();
  const a = new THREE.Vector3();
  const b = new THREE.Vector3();
  for (let i = 0; i < n; i++) {
    const p = points[i];
    const q = points[Math.min(n - 1, i + 1)];
    const o = points[Math.max(0, i - 1)];
    dir.subVectors(q, o);
    if (dir.lengthSq() < 1e-8) dir.set(0, 0, 1);
    dir.normalize();
    a.crossVectors(dir, UP);
    if (a.lengthSq() < 1e-4) a.set(1, 0, 0);
    a.normalize();
    b.crossVectors(dir, a).normalize();
    const w = (width * 0.5) * (taper ? Math.sin((i / Math.max(1, n - 1)) * Math.PI) * 0.7 + 0.3 : 1);
    const base = i * 12;
    pos[base] = p.x + a.x * w;
    pos[base + 1] = p.y + a.y * w;
    pos[base + 2] = p.z + a.z * w;
    pos[base + 3] = p.x - a.x * w;
    pos[base + 4] = p.y - a.y * w;
    pos[base + 5] = p.z - a.z * w;
    pos[base + 6] = p.x + b.x * w;
    pos[base + 7] = p.y + b.y * w;
    pos[base + 8] = p.z + b.z * w;
    pos[base + 9] = p.x - b.x * w;
    pos[base + 10] = p.y - b.y * w;
    pos[base + 11] = p.z - b.z * w;
    if (i < n - 1) {
      const v = i * 4;
      const nv = (i + 1) * 4;
      idx.push(v, v + 1, nv, v + 1, nv + 1, nv);
      idx.push(v + 2, v + 3, nv + 2, v + 3, nv + 3, nv + 2);
    }
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  g.setIndex(idx);
  return g;
}

/** Jagged lightning polyline between two points (midpoint displacement). */
export function jaggedPath(from: THREE.Vector3, to: THREE.Vector3, jag = 0.35, levels = 4): THREE.Vector3[] {
  let pts = [from.clone(), to.clone()];
  let amp = from.distanceTo(to) * jag;
  for (let l = 0; l < levels; l++) {
    const next: THREE.Vector3[] = [];
    for (let i = 0; i < pts.length - 1; i++) {
      const a = pts[i];
      const b = pts[i + 1];
      next.push(a);
      const mid = a.clone().lerp(b, 0.5);
      mid.x += (Math.random() - 0.5) * amp;
      mid.y += (Math.random() - 0.5) * amp;
      mid.z += (Math.random() - 0.5) * amp;
      next.push(mid);
    }
    next.push(pts[pts.length - 1]);
    pts = next;
    amp *= 0.5;
  }
  return pts;
}

class Trail implements TrailHandle {
  private pts: { p: THREE.Vector3; age: number }[] = [];
  private active = true;
  readonly mesh: THREE.Mesh;
  private geo = new THREE.BufferGeometry();
  private posArr: Float32Array;
  private colArr: Float32Array;
  private readonly max = 26;
  private color: THREE.Color;
  private lifetime = 0.16;

  constructor(private source: THREE.Object3D, color: number, private width: number) {
    this.color = new THREE.Color(color);
    this.posArr = new Float32Array(this.max * 2 * 3);
    this.colArr = new Float32Array(this.max * 2 * 3);
    this.geo.setAttribute('position', new THREE.BufferAttribute(this.posArr, 3).setUsage(THREE.DynamicDrawUsage));
    this.geo.setAttribute('color', new THREE.BufferAttribute(this.colArr, 3).setUsage(THREE.DynamicDrawUsage));
    const idx: number[] = [];
    for (let i = 0; i < this.max - 1; i++) {
      const a = i * 2;
      idx.push(a, a + 1, a + 2, a + 1, a + 3, a + 2);
    }
    this.geo.setIndex(idx);
    this.mesh = new THREE.Mesh(
      this.geo,
      new THREE.MeshBasicMaterial({ vertexColors: true, blending: THREE.AdditiveBlending, transparent: true, depthWrite: false, side: THREE.DoubleSide }),
    );
    this.mesh.frustumCulled = false;
    this.mesh.renderOrder = 6;
  }

  stop(): void {
    this.active = false;
  }

  /** Returns false when finished. */
  update(dt: number, cam: THREE.Vector3): boolean {
    for (const p of this.pts) p.age += dt;
    while (this.pts.length && this.pts[0].age > this.lifetime) this.pts.shift();
    if (this.active) {
      const p = this.source.getWorldPosition(new THREE.Vector3());
      const last = this.pts[this.pts.length - 1];
      if (!last || last.p.distanceToSquared(p) > 0.0004) this.pts.push({ p, age: 0 });
      if (this.pts.length > this.max) this.pts.shift();
    }
    const n = this.pts.length;
    if (n < 2) {
      this.geo.setDrawRange(0, 0);
      return this.active;
    }
    const tangent = _v;
    const toCam = _v2;
    for (let i = 0; i < n; i++) {
      const p = this.pts[i].p;
      const a = this.pts[Math.max(0, i - 1)].p;
      const b = this.pts[Math.min(n - 1, i + 1)].p;
      tangent.subVectors(b, a);
      toCam.subVectors(cam, p);
      const side = tangent.cross(toCam);
      if (side.lengthSq() < 1e-8) side.set(0, 1, 0);
      side.normalize();
      const k = i / (n - 1);
      const w = this.width * 0.5 * k;
      const o = i * 6;
      this.posArr[o] = p.x + side.x * w;
      this.posArr[o + 1] = p.y + side.y * w;
      this.posArr[o + 2] = p.z + side.z * w;
      this.posArr[o + 3] = p.x - side.x * w;
      this.posArr[o + 4] = p.y - side.y * w;
      this.posArr[o + 5] = p.z - side.z * w;
      const fade = k * (1 - this.pts[i].age / this.lifetime);
      for (let j = 0; j < 2; j++) {
        this.colArr[o + j * 3] = this.color.r * fade;
        this.colArr[o + j * 3 + 1] = this.color.g * fade;
        this.colArr[o + j * 3 + 2] = this.color.b * fade;
      }
    }
    this.geo.setDrawRange(0, (n - 1) * 6);
    (this.geo.attributes.position as THREE.BufferAttribute).needsUpdate = true;
    (this.geo.attributes.color as THREE.BufferAttribute).needsUpdate = true;
    this.geo.computeBoundingSphere();
    return true;
  }
}

interface Debris {
  mesh: THREE.Mesh;
  vel: THREE.Vector3;
  spin: THREE.Vector3;
  age: number;
  life: number;
  size: number;
  bounced: number;
}

/**
 * Central visual-effects service: pooled particles, timed mesh effects,
 * lightning, trails, afterimages, decals, debris and dynamic flash lights.
 */
export class VFXManager {
  readonly layers: Record<LayerName, ParticleLayer>;
  private timed: Timed[] = [];
  private trails: Trail[] = [];
  private debris: Debris[] = [];
  private lights: { light: THREE.PointLight; t: number; dur: number; peak: number }[] = [];
  private animated: THREE.ShaderMaterial[] = [];
  private debrisMats = new Map<number, THREE.MeshStandardMaterial>();
  private debrisGeos: THREE.BufferGeometry[] = [];
  time = 0;
  groundFn: (x: number, z: number) => number = () => 0;
  quality = 1;

  constructor(public readonly scene: THREE.Scene, private camera: THREE.PerspectiveCamera) {
    this.layers = {
      glow: new ParticleLayer(3000, Textures.soft(), THREE.AdditiveBlending),
      spark: new ParticleLayer(2000, Textures.spark(), THREE.AdditiveBlending),
      flame: new ParticleLayer(2500, Textures.flame(), THREE.AdditiveBlending),
      smoke: new ParticleLayer(1500, Textures.smoke(), THREE.NormalBlending),
      dark: new ParticleLayer(1500, Textures.smoke(), THREE.NormalBlending),
      dust: new ParticleLayer(1500, Textures.soft(), THREE.NormalBlending),
    };
    for (const l of Object.values(this.layers)) scene.add(l.points);
    for (let i = 0; i < 5; i++) {
      const light = new THREE.PointLight(0xffffff, 0, 20, 2);
      light.position.set(0, -100, 0);
      scene.add(light);
      this.lights.push({ light, t: 1, dur: 1, peak: 0 });
    }
    this.debrisGeos = [new THREE.DodecahedronGeometry(1, 0), new THREE.TetrahedronGeometry(1.2, 0), new THREE.BoxGeometry(1.3, 0.8, 1)];
  }

  // ------------------------------------------------------------ particles --
  emit(layer: LayerName, pos: THREE.Vector3, count: number, o: EmitOpts = {}): void {
    const L = this.layers[layer];
    const n = Math.max(1, Math.round(count * this.quality));
    const colors = Array.isArray(o.color) ? o.color : [o.color ?? 0xffffff];
    const endHex = o.colorEnd;
    const spread = o.spread ?? 1;
    for (let i = 0; i < n; i++) {
      let x = pos.x;
      let y = pos.y;
      let z = pos.z;
      let rx = 0;
      let rz = 0;
      if (o.ring !== undefined || o.disc !== undefined) {
        const a = Math.random() * TAU;
        const r = o.ring !== undefined ? o.ring : Math.sqrt(Math.random()) * o.disc!;
        rx = Math.cos(a);
        rz = Math.sin(a);
        x += rx * r;
        z += rz * r;
      }
      if (o.jitter) {
        x += (Math.random() - 0.5) * 2 * o.jitter;
        z += (Math.random() - 0.5) * 2 * o.jitter;
        y += (Math.random() - 0.5) * 2 * (o.jitterY ?? o.jitter);
      }
      const sp = range(o.speed, 2);
      // Direction: blend main dir with random sphere by spread.
      let dx = (Math.random() - 0.5) * 2;
      let dy = (Math.random() - 0.5) * 2;
      let dz = (Math.random() - 0.5) * 2;
      const dl = Math.sqrt(dx * dx + dy * dy + dz * dz) || 1;
      dx /= dl;
      dy /= dl;
      dz /= dl;
      if (o.dir) {
        dx = o.dir.x * (1 - spread) + dx * spread;
        dy = o.dir.y * (1 - spread) + dy * spread;
        dz = o.dir.z * (1 - spread) + dz * spread;
        const l2 = Math.sqrt(dx * dx + dy * dy + dz * dz) || 1;
        dx /= l2;
        dy /= l2;
        dz /= l2;
      }
      let vx = dx * sp;
      let vy = dy * sp;
      let vz = dz * sp;
      if (o.radial) {
        vx += rx * o.radial;
        vz += rz * o.radial;
      }
      if (o.velocity) {
        vx += o.velocity.x;
        vy += o.velocity.y;
        vz += o.velocity.z;
      }
      tmpColor.setHex(colors[Math.floor(Math.random() * colors.length)]);
      if (endHex !== undefined) tmpColor2.setHex(endHex);
      else tmpColor2.copy(tmpColor);
      const size = range(o.size, 0.5);
      L.spawn({
        x,
        y,
        z,
        vx,
        vy,
        vz,
        life: range(o.life, 0.6),
        size0: size,
        size1: size * (o.sizeEnd ?? 1),
        r0: tmpColor.r,
        g0: tmpColor.g,
        b0: tmpColor.b,
        a0: o.alpha ?? 1,
        r1: tmpColor2.r,
        g1: tmpColor2.g,
        b1: tmpColor2.b,
        a1: o.alphaEnd ?? 0,
        drag: o.drag ?? 0,
        gravity: o.gravity ?? 0,
      });
    }
  }

  // ---------------------------------------------------------- mesh fx ----
  addTimed(obj: THREE.Object3D | null, dur: number, update?: (t: number, dt: number) => void, end?: () => void, parent?: THREE.Object3D): void {
    if (obj) (parent ?? this.scene).add(obj);
    this.timed.push({ obj, age: 0, dur, update, end, parent });
  }

  /** Registers a shader material whose uTime uniform is advanced every frame. */
  animate(mat: THREE.ShaderMaterial): THREE.ShaderMaterial {
    this.animated.push(mat);
    return mat;
  }

  release(mat: THREE.Material): void {
    const i = this.animated.indexOf(mat as THREE.ShaderMaterial);
    if (i >= 0) this.animated.splice(i, 1);
    mat.dispose();
  }

  flash(pos: THREE.Vector3, color: number, intensity = 30, distance = 16, dur = 0.25): void {
    let best = this.lights[0];
    for (const l of this.lights) if (l.t / l.dur > best.t / best.dur) best = l;
    best.light.position.copy(pos);
    best.light.color.setHex(color);
    best.light.distance = distance;
    best.peak = intensity;
    best.t = 0;
    best.dur = dur;
    best.light.intensity = intensity;
  }

  /** Expanding flat ring on the ground (shockwaves). */
  ring(pos: THREE.Vector3, color: number, radius: number, dur = 0.5, opts: { start?: number; opacity?: number; y?: number; vertical?: boolean; blend?: THREE.Blending } = {}): void {
    const mat = new THREE.MeshBasicMaterial({
      map: Textures.ring(),
      color,
      transparent: true,
      opacity: opts.opacity ?? 1,
      blending: opts.blend ?? THREE.AdditiveBlending,
      depthWrite: false,
      side: THREE.DoubleSide,
    });
    const m = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), mat);
    if (!opts.vertical) m.rotation.x = -Math.PI / 2;
    m.position.copy(pos);
    m.position.y += opts.y ?? 0.15;
    m.renderOrder = 6;
    const start = opts.start ?? radius * 0.1;
    const op = opts.opacity ?? 1;
    this.addTimed(m, dur, (t) => {
      const e = 1 - Math.pow(1 - t, 3);
      const r = start + (radius - start) * e;
      m.scale.set(r, r, r);
      mat.opacity = op * (1 - t * t);
    }, () => {
      m.geometry.dispose();
      mat.dispose();
    });
  }

  /** Expanding glowing sphere (explosions, nova). */
  sphere(pos: THREE.Vector3, color: number, radius: number, dur = 0.4, opacity = 0.8): void {
    const mat = new THREE.MeshBasicMaterial({ color, transparent: true, opacity, blending: THREE.AdditiveBlending, depthWrite: false });
    const m = new THREE.Mesh(new THREE.SphereGeometry(1, 20, 14), mat);
    m.position.copy(pos);
    this.addTimed(m, dur, (t) => {
      const e = 1 - Math.pow(1 - t, 2.5);
      m.scale.setScalar(Math.max(0.01, radius * e));
      mat.opacity = opacity * (1 - t);
    }, () => {
      m.geometry.dispose();
      mat.dispose();
    });
  }

  /** Lightning bolt between two points; flickers by regenerating. */
  bolt(from: THREE.Vector3, to: THREE.Vector3, color: number, opts: { width?: number; jag?: number; dur?: number; branches?: number; core?: number } = {}): void {
    const width = opts.width ?? 0.18;
    const jag = opts.jag ?? 0.3;
    const dur = opts.dur ?? 0.22;
    const group = new THREE.Group();
    const glowMat = new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.9, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide });
    const coreMat = new THREE.MeshBasicMaterial({ color: opts.core ?? 0xffffff, transparent: true, opacity: 1, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide });
    const build = () => {
      for (const c of [...group.children]) {
        (c as THREE.Mesh).geometry.dispose();
        group.remove(c);
      }
      const path = jaggedPath(from, to, jag, 4);
      group.add(new THREE.Mesh(ribbonGeometry(path, width * 3), glowMat));
      group.add(new THREE.Mesh(ribbonGeometry(path, width), coreMat));
      const nb = opts.branches ?? 2;
      for (let i = 0; i < nb; i++) {
        const start = path[Math.floor(rand(0.2, 0.8) * path.length)];
        const end = start.clone().add(new THREE.Vector3(rand(-1, 1), rand(-1, 0.5), rand(-1, 1)).multiplyScalar(from.distanceTo(to) * 0.25));
        group.add(new THREE.Mesh(ribbonGeometry(jaggedPath(start, end, 0.4, 3), width * 1.2), glowMat));
      }
    };
    build();
    for (const c of group.children) c.renderOrder = 7;
    let flick = 0;
    this.addTimed(group, dur, (t, dt) => {
      flick += dt;
      if (flick > 0.05) {
        flick = 0;
        build();
      }
      const o = 1 - t;
      glowMat.opacity = 0.9 * o;
      coreMat.opacity = o;
    }, () => {
      for (const c of group.children) (c as THREE.Mesh).geometry.dispose();
      glowMat.dispose();
      coreMat.dispose();
    });
  }

  /** Straight glowing streak (slash lines, beams). */
  beam(from: THREE.Vector3, to: THREE.Vector3, color: number, width = 0.2, dur = 0.2): void {
    const mat = new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 1, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide });
    const pts: THREE.Vector3[] = [];
    for (let i = 0; i <= 8; i++) pts.push(from.clone().lerp(to, i / 8));
    const m = new THREE.Mesh(ribbonGeometry(pts, width, true), mat);
    m.renderOrder = 7;
    this.addTimed(m, dur, (t) => {
      mat.opacity = 1 - t;
    }, () => {
      m.geometry.dispose();
      mat.dispose();
    });
  }

  /** Curved arc slash around an actor (sword / claw swipes). */
  slash(center: THREE.Vector3, yaw: number, color: number, radius: number, arcDeg = 160, dur = 0.22, tilt = 0, height = 1.1, thickness = 0.5): void {
    const arc = (arcDeg * Math.PI) / 180;
    const geo = new THREE.RingGeometry(radius - thickness, radius, 32, 1, -arc / 2, arc);
    // Fade the ends via vertex colours.
    const pos = geo.attributes.position as THREE.BufferAttribute;
    const cols = new Float32Array(pos.count * 3);
    const c = new THREE.Color(color);
    for (let i = 0; i < pos.count; i++) {
      const a = Math.atan2(pos.getY(i), pos.getX(i));
      const k = 1 - Math.abs(a) / (arc / 2);
      const f = Math.max(0, Math.min(1, k * 1.8));
      cols[i * 3] = c.r * f;
      cols[i * 3 + 1] = c.g * f;
      cols[i * 3 + 2] = c.b * f;
    }
    geo.setAttribute('color', new THREE.BufferAttribute(cols, 3));
    const mat = new THREE.MeshBasicMaterial({ vertexColors: true, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide });
    const m = new THREE.Mesh(geo, mat);
    const g = new THREE.Group();
    g.position.copy(center);
    g.position.y += height;
    g.rotation.y = yaw;
    m.rotation.x = -Math.PI / 2 + tilt;
    m.rotation.z = Math.PI / 2; // arc centred on forward (+Z)
    g.add(m);
    m.renderOrder = 7;
    this.addTimed(g, dur, (t) => {
      mat.opacity = 1 - t;
      m.rotation.z = Math.PI / 2 + (t - 0.5) * 0.6;
      g.scale.setScalar(1 + t * 0.15);
    }, () => {
      geo.dispose();
      mat.dispose();
    });
  }

  /** Flat decal on the ground (scorch, cracks, runes). */
  decal(pos: THREE.Vector3, radius: number, texture: THREE.Texture, color: number, dur: number, opts: { additive?: boolean; opacity?: number; rotation?: number; spin?: number; fadeIn?: number } = {}): THREE.Mesh {
    const mat = new THREE.MeshBasicMaterial({
      map: texture,
      color,
      transparent: true,
      opacity: 0,
      blending: opts.additive ? THREE.AdditiveBlending : THREE.NormalBlending,
      depthWrite: false,
      polygonOffset: true,
      polygonOffsetFactor: -6,
    });
    const m = new THREE.Mesh(new THREE.PlaneGeometry(radius * 2, radius * 2), mat);
    m.rotation.x = -Math.PI / 2;
    m.rotation.z = opts.rotation ?? Math.random() * TAU;
    m.position.set(pos.x, this.groundFn(pos.x, pos.z) + 0.06, pos.z);
    m.renderOrder = 2;
    const op = opts.opacity ?? 1;
    const fi = opts.fadeIn ?? 0.05;
    this.addTimed(m, dur, (t, dt) => {
      const age = t * dur;
      const fin = Math.min(1, age / Math.max(0.001, fi));
      const fout = Math.min(1, (dur - age) / Math.min(1, dur * 0.4));
      mat.opacity = op * fin * fout;
      if (opts.spin) m.rotation.z += opts.spin * dt;
    }, () => {
      m.geometry.dispose();
      mat.dispose();
    });
    return m;
  }

  /** Ghostly copy of an actor's current pose that fades out. */
  afterimage(actor: Actor, color: number, dur = 0.35, opacity = 0.55): void {
    const mat = new THREE.MeshBasicMaterial({ color, transparent: true, opacity, blending: THREE.AdditiveBlending, depthWrite: false });
    const copy = cloneRigVisual(actor.rig, mat);
    const g = new THREE.Group();
    actor.visual.updateWorldMatrix(true, false);
    actor.visual.matrixWorld.decompose(g.position, g.quaternion, g.scale);
    g.add(copy);
    this.addTimed(g, dur, (t) => {
      mat.opacity = opacity * (1 - t);
    }, () => mat.dispose());
  }

  /** Physical rock/wood chunks. */
  spawnDebris(pos: THREE.Vector3, count: number, color: number, opts: { dir?: THREE.Vector3; force?: number; size?: number; up?: number; life?: number } = {}): void {
    let mat = this.debrisMats.get(color);
    if (!mat) {
      mat = new THREE.MeshStandardMaterial({ color, roughness: 0.9, flatShading: true });
      this.debrisMats.set(color, mat);
    }
    const n = Math.max(1, Math.round(count * this.quality));
    for (let i = 0; i < n; i++) {
      if (this.debris.length > 90) {
        const old = this.debris.shift()!;
        this.scene.remove(old.mesh);
      }
      const geo = this.debrisGeos[Math.floor(Math.random() * this.debrisGeos.length)];
      const mesh = new THREE.Mesh(geo, mat);
      const size = (opts.size ?? 0.25) * rand(0.5, 1.4);
      mesh.scale.setScalar(size);
      mesh.position.copy(pos).add(new THREE.Vector3(rand(-0.4, 0.4), rand(0, 0.4), rand(-0.4, 0.4)));
      mesh.castShadow = true;
      const force = opts.force ?? 6;
      const vel = new THREE.Vector3(rand(-1, 1), 0, rand(-1, 1)).normalize().multiplyScalar(rand(0.3, 1) * force);
      if (opts.dir) vel.addScaledVector(opts.dir, force * 0.6);
      vel.y = rand(0.5, 1) * (opts.up ?? force * 1.1);
      this.scene.add(mesh);
      this.debris.push({ mesh, vel, spin: new THREE.Vector3(rand(-8, 8), rand(-8, 8), rand(-8, 8)), age: 0, life: (opts.life ?? 2.2) * rand(0.7, 1.2), size, bounced: 0 });
    }
  }

  trail(source: THREE.Object3D, color: number, width = 0.35): TrailHandle {
    const t = new Trail(source, color, width);
    this.scene.add(t.mesh);
    this.trails.push(t);
    return t;
  }

  // ------------------------------------------------------------- update --
  update(dt: number, viewportHeight: number): void {
    this.time += dt;
    const scale = viewportHeight / (2 * Math.tan((this.camera.fov * Math.PI) / 360));
    for (const l of Object.values(this.layers)) l.update(dt, scale);

    for (let i = this.timed.length - 1; i >= 0; i--) {
      const t = this.timed[i];
      t.age += dt;
      const k = Math.min(1, t.age / t.dur);
      t.update?.(k, dt);
      if (t.age >= t.dur) {
        if (t.obj) (t.parent ?? this.scene).remove(t.obj);
        t.end?.();
        this.timed.splice(i, 1);
      }
    }

    const camPos = this.camera.position;
    for (let i = this.trails.length - 1; i >= 0; i--) {
      if (!this.trails[i].update(dt, camPos)) {
        this.scene.remove(this.trails[i].mesh);
        this.trails[i].mesh.geometry.dispose();
        this.trails.splice(i, 1);
      }
    }

    for (let i = this.debris.length - 1; i >= 0; i--) {
      const d = this.debris[i];
      d.age += dt;
      d.vel.y -= 26 * dt;
      d.mesh.position.addScaledVector(d.vel, dt);
      const g = this.groundFn(d.mesh.position.x, d.mesh.position.z);
      if (d.mesh.position.y < g + d.size * 0.5) {
        d.mesh.position.y = g + d.size * 0.5;
        if (d.vel.y < -1.5 && d.bounced < 2) {
          d.vel.y *= -0.35;
          d.vel.x *= 0.6;
          d.vel.z *= 0.6;
          d.bounced++;
        } else {
          d.vel.set(d.vel.x * 0.85, 0, d.vel.z * 0.85);
          d.spin.multiplyScalar(0.8);
        }
      }
      d.mesh.rotation.x += d.spin.x * dt;
      d.mesh.rotation.y += d.spin.y * dt;
      d.mesh.rotation.z += d.spin.z * dt;
      const fade = d.age / d.life;
      if (fade > 0.7) d.mesh.scale.setScalar(d.size * Math.max(0.01, (1 - fade) / 0.3));
      if (d.age >= d.life) {
        this.scene.remove(d.mesh);
        this.debris.splice(i, 1);
      }
    }

    for (const l of this.lights) {
      if (l.t < l.dur) {
        l.t += dt;
        const k = Math.min(1, l.t / l.dur);
        l.light.intensity = l.peak * (1 - k) * (1 - k);
      } else if (l.light.intensity !== 0) {
        l.light.intensity = 0;
      }
    }

    for (const m of this.animated) if (m.uniforms.uTime) m.uniforms.uTime.value = this.time;
  }

  clear(): void {
    for (const l of Object.values(this.layers)) l.clear();
    for (const t of this.timed) {
      if (t.obj) (t.parent ?? this.scene).remove(t.obj);
      t.end?.();
    }
    this.timed = [];
    for (const t of this.trails) this.scene.remove(t.mesh);
    this.trails = [];
    for (const d of this.debris) this.scene.remove(d.mesh);
    this.debris = [];
    for (const l of this.lights) {
      l.t = l.dur;
      l.light.intensity = 0;
    }
  }
}
