import * as THREE from 'three';
import { fbm2, seededRandom, smoothstep, TAU } from '../core/math';
import { Textures } from '../vfx/Textures';
import { mergeGeometries } from 'three/examples/jsm/utils/BufferGeometryUtils.js';

interface ColliderBase {
  id: number;
  enabled: boolean;
  walkable: boolean;
  bottom: number;
  top: number;
  destructible?: Destructible;
  qid: number;
}
export interface BoxCollider extends ColliderBase {
  kind: 'box';
  cx: number;
  cz: number;
  hx: number;
  hz: number;
  cos: number;
  sin: number;
}
export interface CylCollider extends ColliderBase {
  kind: 'cyl';
  cx: number;
  cz: number;
  r: number;
}
export type Collider = BoxCollider | CylCollider;

export type DestructibleKind = 'crate' | 'barrel' | 'pillar' | 'statue';

export interface Destructible {
  kind: DestructibleKind;
  object: THREE.Object3D;
  rubble: THREE.Object3D | null;
  collider: Collider | null;
  hp: number;
  maxHp: number;
  alive: boolean;
  center: THREE.Vector3;
  radius: number;
  height: number;
  color: number;
  originalTop: number;
}

interface FlattenZone {
  x: number;
  z: number;
  r: number;
  h: number;
}

const CELL = 8;
let colliderId = 1;

/**
 * The combat arena: terrain, ruins, platforms, rocks, destructible props,
 * sky and all collision queries used by movement, cameras and projectiles.
 */
export class Arena {
  readonly group = new THREE.Group();
  /** Structures and props (hidden inside the Realm of Shadows). */
  readonly props = new THREE.Group();
  /** Distant static scenery (mountains, cliffs) — merged like props but never hidden. */
  private readonly scenery = new THREE.Group();
  readonly colliders: Collider[] = [];
  readonly destructibles: Destructible[] = [];
  readonly boundary = 92;
  readonly spawnPoints: THREE.Vector3[] = [];
  readonly braziers: THREE.Vector3[] = [];
  readonly portalMeshes: THREE.Mesh[] = [];
  readonly crystalLights: THREE.Vector3[] = [];
  collidersEnabled = true;
  onDestroy: ((d: Destructible, dir: THREE.Vector3) => void) | null = null;
  terrain!: THREE.Mesh;
  terrainMat!: THREE.MeshStandardMaterial;
  private terrainColor = new THREE.Color();
  skyMat!: THREE.ShaderMaterial;
  private grid = new Map<number, Collider[]>();
  private qstamp = 1;
  private flatten: FlattenZone[] = [];
  private rnd = seededRandom(1337);
  private mats: Record<string, THREE.MeshStandardMaterial> = {};

  constructor() {
    this.flatten = [
      { x: 0, z: -62, r: 24, h: 0.4 },
      { x: 60, z: 6, r: 26, h: 0 },
      { x: -60, z: -8, r: 22, h: 0.8 },
      { x: 0, z: 62, r: 20, h: 0 },
      { x: 48, z: 48, r: 16, h: 0.2 },
      { x: -45, z: 50, r: 16, h: 0.3 },
    ];
    this.makeMaterials();
    this.buildSky();
    this.buildTerrain();
    this.buildPlaza();
    this.buildTemple();
    this.buildEastRuins();
    this.buildWestTower();
    this.buildArches();
    this.buildFloatingIsles();
    this.buildGraveyard();
    this.buildRocks();
    this.buildGrass();
    this.buildPortals();
    this.group.add(this.props);
    this.group.add(this.scenery);
    this.mergeStatic(this.props);
    this.mergeStatic(this.scenery);
  }

  /**
   * Merges every static, non-destructible prop mesh into one mesh per material.
   * Cuts the arena from ~250 draw calls to a few dozen.
   */
  private mergeStatic(root: THREE.Group): void {
    const keep = new Set<THREE.Object3D>();
    for (const d of this.destructibles) {
      d.object.traverse((o) => keep.add(o));
      d.rubble?.traverse((o) => keep.add(o));
    }
    root.updateMatrixWorld(true);
    const buckets = new Map<THREE.Material, THREE.BufferGeometry[]>();
    const remove: THREE.Mesh[] = [];
    root.traverse((o) => {
      const m = o as THREE.Mesh;
      if (!m.isMesh || (m as unknown as THREE.InstancedMesh).isInstancedMesh || keep.has(m) || Array.isArray(m.material)) return;
      let g = m.geometry.clone().applyMatrix4(m.matrixWorld);
      if (g.index) g = g.toNonIndexed();
      for (const name of Object.keys(g.attributes)) if (!['position', 'normal', 'uv'].includes(name)) g.deleteAttribute(name);
      if (!g.attributes.uv) g.setAttribute('uv', new THREE.BufferAttribute(new Float32Array(g.attributes.position.count * 2), 2));
      const list = buckets.get(m.material) ?? [];
      list.push(g);
      buckets.set(m.material, list);
      remove.push(m);
    });
    for (const m of remove) m.parent?.remove(m);
    for (const [mat, geos] of buckets) {
      const merged = mergeGeometries(geos, false);
      if (!merged) continue;
      const mesh = new THREE.Mesh(merged, mat);
      mesh.castShadow = root === this.props;
      mesh.receiveShadow = true;
      root.add(mesh);
    }
  }

  // ------------------------------------------------------------ terrain --
  terrainHeight(x: number, z: number): number {
    const r = Math.sqrt(x * x + z * z);
    const hills = (fbm2(x * 0.022 + 100, z * 0.022 + 100, 4, 7) - 0.45) * 8;
    let h = hills * smoothstep(27, 52, r);
    for (const f of this.flatten) {
      const d = Math.hypot(x - f.x, z - f.z);
      const w = 1 - smoothstep(f.r * 0.7, f.r, d);
      if (w > 0) h = h + (f.h - h) * w;
    }
    const rim = smoothstep(86, 128, r);
    h += rim * rim * 34 + rim * (fbm2(x * 0.05, z * 0.05, 3, 3) - 0.5) * 16;
    return h;
  }

  /** Highest walkable surface at (x,z) not above maxY. */
  groundHeight(x: number, z: number, maxY = Infinity): number {
    let h = this.terrainHeight(x, z);
    if (!this.collidersEnabled) return h;
    for (const c of this.near(x, z, 0.1)) {
      if (!c.enabled || !c.walkable || c.top > maxY || c.top <= h) continue;
      if (this.pointInside(c, x, z, 0.05)) h = c.top;
    }
    return h;
  }

  private pointInside(c: Collider, x: number, z: number, pad: number): boolean {
    if (c.kind === 'cyl') {
      const dx = x - c.cx;
      const dz = z - c.cz;
      return dx * dx + dz * dz <= (c.r + pad) * (c.r + pad);
    }
    const dx = x - c.cx;
    const dz = z - c.cz;
    const lx = c.cos * dx - c.sin * dz;
    const lz = c.sin * dx + c.cos * dz;
    return Math.abs(lx) <= c.hx + pad && Math.abs(lz) <= c.hz + pad;
  }

  /**
   * Pushes a vertical capsule (feet at pos.y) out of solid colliders.
   * Returns true when a wall was hit.
   */
  resolveCircle(pos: THREE.Vector3, radius: number, height: number, stepHeight: number): boolean {
    let hit = false;
    const boundary = this.boundary - radius;
    const r = Math.hypot(pos.x, pos.z);
    if (r > boundary) {
      pos.x *= boundary / r;
      pos.z *= boundary / r;
      hit = true;
    }
    if (!this.collidersEnabled) return hit;
    for (const c of this.near(pos.x, pos.z, radius + 0.5)) {
      if (!c.enabled) continue;
      if (c.top <= pos.y + stepHeight || c.bottom >= pos.y + height) continue;
      if (c.kind === 'cyl') {
        const dx = pos.x - c.cx;
        const dz = pos.z - c.cz;
        const d = Math.sqrt(dx * dx + dz * dz);
        const min = c.r + radius;
        if (d < min) {
          const nx = d > 1e-4 ? dx / d : 1;
          const nz = d > 1e-4 ? dz / d : 0;
          pos.x = c.cx + nx * min;
          pos.z = c.cz + nz * min;
          hit = true;
        }
      } else {
        const dx = pos.x - c.cx;
        const dz = pos.z - c.cz;
        const lx = c.cos * dx - c.sin * dz;
        const lz = c.sin * dx + c.cos * dz;
        const qx = Math.max(-c.hx, Math.min(c.hx, lx));
        const qz = Math.max(-c.hz, Math.min(c.hz, lz));
        let px = lx - qx;
        let pz = lz - qz;
        const d2 = px * px + pz * pz;
        if (d2 >= radius * radius) continue;
        let nlx: number;
        let nlz: number;
        if (d2 > 1e-8) {
          const d = Math.sqrt(d2);
          const push = radius - d;
          nlx = lx + (px / d) * push;
          nlz = lz + (pz / d) * push;
        } else {
          // Centre inside the box: exit along the shallowest axis.
          const ex = c.hx - Math.abs(lx);
          const ez = c.hz - Math.abs(lz);
          if (ex < ez) {
            nlx = Math.sign(lx || 1) * (c.hx + radius);
            nlz = lz;
          } else {
            nlx = lx;
            nlz = Math.sign(lz || 1) * (c.hz + radius);
          }
        }
        // Back to world space (inverse rotation).
        pos.x = c.cx + c.cos * nlx + c.sin * nlz;
        pos.z = c.cz - c.sin * nlx + c.cos * nlz;
        hit = true;
        px = pz = 0;
      }
    }
    return hit;
  }

  /** Distance along a ray until it hits terrain or a solid collider. */
  raycast(origin: THREE.Vector3, dir: THREE.Vector3, maxDist: number, pad = 0.25): number {
    const step = 0.25;
    const p = new THREE.Vector3();
    for (let d = step; d <= maxDist; d += step) {
      p.copy(origin).addScaledVector(dir, d);
      if (p.y < this.terrainHeight(p.x, p.z) + pad) return Math.max(0, d - step);
      if (this.solidAt(p, pad)) return Math.max(0, d - step);
    }
    return maxDist;
  }

  /** Is the point inside any solid collider? */
  solidAt(p: THREE.Vector3, pad = 0): boolean {
    if (!this.collidersEnabled) return false;
    for (const c of this.near(p.x, p.z, pad + 0.1)) {
      if (!c.enabled) continue;
      if (p.y < c.bottom - pad || p.y > c.top + pad) continue;
      if (this.pointInside(c, p.x, p.z, pad)) return true;
    }
    return false;
  }

  /** Swept point test for projectiles; returns the impact point or null. */
  sweep(a: THREE.Vector3, b: THREE.Vector3, pad = 0): THREE.Vector3 | null {
    const len = a.distanceTo(b);
    const steps = Math.max(1, Math.ceil(len / 0.4));
    const p = new THREE.Vector3();
    for (let i = 1; i <= steps; i++) {
      p.lerpVectors(a, b, i / steps);
      if (p.y < this.terrainHeight(p.x, p.z) + 0.05) {
        p.y = this.terrainHeight(p.x, p.z) + 0.05;
        return p;
      }
      if (this.solidAt(p, pad)) return p;
      if (Math.hypot(p.x, p.z) > this.boundary + 6) return p;
    }
    return null;
  }

  /** Clamp a teleport destination so it is not inside geometry. */
  safePoint(from: THREE.Vector3, to: THREE.Vector3, radius = 0.5): THREE.Vector3 {
    const dir = to.clone().sub(from);
    dir.y = 0;
    const dist = dir.length();
    if (dist < 1e-3) return from.clone();
    dir.normalize();
    const eye = from.clone().setY(from.y + 1);
    const free = this.raycast(eye, dir, dist, radius);
    const out = from.clone().addScaledVector(dir, Math.max(0, free - radius * 0.5));
    const r = Math.hypot(out.x, out.z);
    const b = this.boundary - 1;
    if (r > b) {
      out.x *= b / r;
      out.z *= b / r;
    }
    out.y = this.groundHeight(out.x, out.z, from.y + 1.5);
    return out;
  }

  // ------------------------------------------------------ destructibles --
  damageInSphere(center: THREE.Vector3, radius: number, amount: number, dir?: THREE.Vector3): void {
    for (const d of this.destructibles) {
      if (!d.alive) continue;
      const dx = d.center.x - center.x;
      const dz = d.center.z - center.z;
      const dy = Math.max(0, Math.abs(d.center.y - center.y) - d.height * 0.5);
      const dist = Math.sqrt(dx * dx + dz * dz + dy * dy) - d.radius;
      if (dist > radius) continue;
      d.hp -= amount;
      // Wobble feedback.
      d.object.rotation.z = (Math.random() - 0.5) * 0.06;
      if (d.hp <= 0) this.destroy(d, dir ?? new THREE.Vector3(dx, 0, dz).normalize());
    }
  }

  destroy(d: Destructible, dir: THREE.Vector3): void {
    if (!d.alive) return;
    d.alive = false;
    d.object.visible = false;
    if (d.rubble) d.rubble.visible = true;
    if (d.collider) {
      if (d.kind === 'pillar' || d.kind === 'statue') d.collider.top = d.collider.bottom + 1.6 + 0.9;
      else d.collider.enabled = false;
    }
    this.onDestroy?.(d, dir);
  }

  /** Restores everything a match can change (props, colliders, realm tint, destructibles). */
  resetState(): void {
    this.props.visible = true;
    this.collidersEnabled = true;
    this.terrainMat.color.copy(this.terrainColor);
    for (const m of this.portalMeshes) m.userData.active = 0;
    this.resetDestructibles();
  }

  resetDestructibles(): void {
    for (const d of this.destructibles) {
      d.alive = true;
      d.hp = d.maxHp;
      d.object.visible = true;
      d.object.rotation.z = 0;
      if (d.rubble) d.rubble.visible = false;
      if (d.collider) {
        d.collider.enabled = true;
        d.collider.top = d.originalTop;
      }
    }
  }

  // --------------------------------------------------------- grid utils --
  private cellKey(ix: number, iz: number): number {
    return (ix + 512) * 1024 + (iz + 512);
  }

  private insert(c: Collider): void {
    const r = c.kind === 'cyl' ? c.r : Math.hypot(c.hx, c.hz);
    const x0 = Math.floor((c.cx - r) / CELL);
    const x1 = Math.floor((c.cx + r) / CELL);
    const z0 = Math.floor((c.cz - r) / CELL);
    const z1 = Math.floor((c.cz + r) / CELL);
    for (let ix = x0; ix <= x1; ix++) {
      for (let iz = z0; iz <= z1; iz++) {
        const k = this.cellKey(ix, iz);
        let list = this.grid.get(k);
        if (!list) {
          list = [];
          this.grid.set(k, list);
        }
        list.push(c);
      }
    }
    this.colliders.push(c);
  }

  private nearBuf: Collider[] = [];
  near(x: number, z: number, r: number): Collider[] {
    const out = this.nearBuf;
    out.length = 0;
    const stamp = ++this.qstamp;
    const x0 = Math.floor((x - r) / CELL);
    const x1 = Math.floor((x + r) / CELL);
    const z0 = Math.floor((z - r) / CELL);
    const z1 = Math.floor((z + r) / CELL);
    for (let ix = x0; ix <= x1; ix++) {
      for (let iz = z0; iz <= z1; iz++) {
        const list = this.grid.get(this.cellKey(ix, iz));
        if (!list) continue;
        for (const c of list) {
          if (c.qid === stamp) continue;
          c.qid = stamp;
          out.push(c);
        }
      }
    }
    return out;
  }

  // ------------------------------------------------------ construction --
  private makeMaterials(): void {
    const bricks = Textures.bricks();
    const rock = Textures.rock();
    this.mats = {
      stone: new THREE.MeshStandardMaterial({ map: bricks, color: 0xd8cbb8, roughness: 0.92 }),
      stoneDark: new THREE.MeshStandardMaterial({ map: bricks, color: 0x9a8f84, roughness: 0.95 }),
      marble: new THREE.MeshStandardMaterial({ color: 0xe8e0d0, roughness: 0.55, metalness: 0.02 }),
      marbleDark: new THREE.MeshStandardMaterial({ color: 0xb9ae9c, roughness: 0.6 }),
      rock: new THREE.MeshStandardMaterial({ map: rock, color: 0x8d857c, roughness: 0.97, flatShading: true }),
      rockDark: new THREE.MeshStandardMaterial({ map: rock, color: 0x5f5a55, roughness: 0.97, flatShading: true }),
      wood: new THREE.MeshStandardMaterial({ map: Textures.wood(), color: 0xffffff, roughness: 0.85 }),
      metal: new THREE.MeshStandardMaterial({ color: 0x4a4d52, roughness: 0.4, metalness: 0.7 }),
      bronze: new THREE.MeshStandardMaterial({ color: 0x8a6a3a, roughness: 0.45, metalness: 0.75 }),
      crystal: new THREE.MeshStandardMaterial({ color: 0x7fe0ff, emissive: 0x2aa8e0, emissiveIntensity: 1.6, roughness: 0.2, metalness: 0.1, flatShading: true }),
      moss: new THREE.MeshStandardMaterial({ color: 0x4f6b35, roughness: 1 }),
    };
  }

  /** Box geometry whose UVs are scaled to world size so textures tile evenly. */
  private boxGeo(w: number, h: number, d: number, texScale = 3): THREE.BoxGeometry {
    const g = new THREE.BoxGeometry(w, h, d);
    const uv = g.attributes.uv as THREE.BufferAttribute;
    const spans: [number, number][] = [
      [d, h],
      [d, h],
      [w, d],
      [w, d],
      [w, h],
      [w, h],
    ];
    for (let f = 0; f < 6; f++) {
      for (let v = 0; v < 4; v++) {
        const i = f * 4 + v;
        uv.setXY(i, uv.getX(i) * (spans[f][0] / texScale), uv.getY(i) * (spans[f][1] / texScale));
      }
    }
    return g;
  }

  /** Solid box sitting on the terrain (sunk so slopes never show gaps). */
  private addBox(cx: number, cz: number, w: number, h: number, d: number, yaw: number, mat: THREE.Material, opts: { baseY?: number; sink?: number; walkable?: boolean; parent?: THREE.Object3D; noCollide?: boolean } = {}): { mesh: THREE.Mesh; collider: BoxCollider | null } {
    const baseY = opts.baseY ?? this.terrainHeight(cx, cz);
    const sink = opts.sink ?? 1.5;
    const mesh = new THREE.Mesh(this.boxGeo(w, h + sink, d), mat);
    mesh.position.set(cx, baseY + (h - sink) / 2, cz);
    mesh.rotation.y = yaw;
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    (opts.parent ?? this.props).add(mesh);
    let collider: BoxCollider | null = null;
    if (!opts.noCollide) {
      collider = {
        kind: 'box',
        id: colliderId++,
        cx,
        cz,
        hx: w / 2,
        hz: d / 2,
        cos: Math.cos(yaw),
        sin: Math.sin(yaw),
        bottom: baseY - sink,
        top: baseY + h,
        enabled: true,
        walkable: opts.walkable ?? true,
        qid: 0,
      };
      this.insert(collider);
    }
    return { mesh, collider };
  }

  private addCyl(cx: number, cz: number, r: number, h: number, mat: THREE.Material, opts: { baseY?: number; sink?: number; rTop?: number; seg?: number; walkable?: boolean; parent?: THREE.Object3D; noCollide?: boolean } = {}): { mesh: THREE.Mesh; collider: CylCollider | null } {
    const baseY = opts.baseY ?? this.terrainHeight(cx, cz);
    const sink = opts.sink ?? 1;
    const geo = new THREE.CylinderGeometry(opts.rTop ?? r, r, h + sink, opts.seg ?? 14);
    const mesh = new THREE.Mesh(geo, mat);
    mesh.position.set(cx, baseY + (h - sink) / 2, cz);
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    (opts.parent ?? this.props).add(mesh);
    let collider: CylCollider | null = null;
    if (!opts.noCollide) {
      collider = {
        kind: 'cyl',
        id: colliderId++,
        cx,
        cz,
        r: Math.max(r, opts.rTop ?? r),
        bottom: baseY - sink,
        top: baseY + h,
        enabled: true,
        walkable: opts.walkable ?? true,
        qid: 0,
      };
      this.insert(collider);
    }
    return { mesh, collider };
  }

  private buildSky(): void {
    const uniforms = {
      top: { value: new THREE.Color(0x3f6fb5) },
      bottom: { value: new THREE.Color(0xf2c9a0) },
      sunDir: { value: new THREE.Vector3(40, 70, 30).normalize() },
    };
    this.skyMat = new THREE.ShaderMaterial({
      uniforms,
      side: THREE.BackSide,
      depthWrite: false,
      fog: false,
      vertexShader: /* glsl */ `
        varying vec3 vDir;
        void main() {
          vDir = normalize(position);
          vec4 p = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
          gl_Position = p.xyww;
        }`,
      fragmentShader: /* glsl */ `
        uniform vec3 top; uniform vec3 bottom; uniform vec3 sunDir;
        varying vec3 vDir;
        void main() {
          float h = clamp(vDir.y * 1.6 + 0.08, 0.0, 1.0);
          vec3 col = mix(bottom, top, pow(h, 0.7));
          float s = max(dot(normalize(vDir), sunDir), 0.0);
          col += vec3(1.0, 0.85, 0.6) * (pow(s, 400.0) * 3.0 + pow(s, 12.0) * 0.25);
          gl_FragColor = vec4(col, 1.0);
          #include <tonemapping_fragment>
          #include <colorspace_fragment>
        }`,
    });
    const sky = new THREE.Mesh(new THREE.SphereGeometry(900, 32, 16), this.skyMat);
    sky.frustumCulled = false;
    sky.renderOrder = -10;
    this.group.add(sky);

    // Distant mountain silhouettes.
    const mtnMat = new THREE.MeshBasicMaterial({ color: 0x7c7f98, fog: false });
    const mtnMat2 = new THREE.MeshBasicMaterial({ color: 0x9a95a8, fog: false });
    for (let i = 0; i < 46; i++) {
      const a = (i / 46) * TAU + this.rnd() * 0.1;
      const far = i % 2 === 0;
      const r = far ? 620 + this.rnd() * 80 : 480 + this.rnd() * 60;
      const h = 70 + this.rnd() * (far ? 170 : 110);
      const m = new THREE.Mesh(new THREE.ConeGeometry(60 + this.rnd() * 70, h, 5 + Math.floor(this.rnd() * 3)), far ? mtnMat2 : mtnMat);
      m.position.set(Math.cos(a) * r, h / 2 - 10, Math.sin(a) * r);
      m.rotation.y = this.rnd() * TAU;
      this.scenery.add(m);
    }
    // Clouds.
    const cloudMat = new THREE.SpriteMaterial({ map: Textures.smoke(), color: 0xfff4ea, transparent: true, opacity: 0.55, fog: false, depthWrite: false });
    for (let i = 0; i < 16; i++) {
      const s = new THREE.Sprite(cloudMat);
      const a = this.rnd() * TAU;
      const r = 300 + this.rnd() * 350;
      s.position.set(Math.cos(a) * r, 110 + this.rnd() * 150, Math.sin(a) * r);
      const sc = 140 + this.rnd() * 160;
      s.scale.set(sc * 1.8, sc * 0.7, 1);
      this.group.add(s);
    }
  }

  private buildTerrain(): void {
    const size = 300;
    const seg = 150;
    const geo = new THREE.PlaneGeometry(size, size, seg, seg);
    geo.rotateX(-Math.PI / 2);
    const pos = geo.attributes.position as THREE.BufferAttribute;
    for (let i = 0; i < pos.count; i++) {
      const x = pos.getX(i);
      const z = pos.getZ(i);
      pos.setY(i, this.terrainHeight(x, z));
    }
    geo.computeVertexNormals();
    const nrm = geo.attributes.normal as THREE.BufferAttribute;
    const colors = new Float32Array(pos.count * 3);
    const grass = new THREE.Color(0xa7b889);
    const dry = new THREE.Color(0xc9b58f);
    const dirt = new THREE.Color(0xb49a7a);
    const rock = new THREE.Color(0x8e877f);
    const c = new THREE.Color();
    for (let i = 0; i < pos.count; i++) {
      const x = pos.getX(i);
      const z = pos.getZ(i);
      const y = pos.getY(i);
      const r = Math.hypot(x, z);
      const slope = 1 - nrm.getY(i);
      c.copy(grass).lerp(dry, fbm2(x * 0.04, z * 0.04, 3, 12));
      c.lerp(dirt, smoothstep(30, 24, r) * 0.8);
      c.lerp(rock, Math.min(1, smoothstep(0.12, 0.35, slope) + smoothstep(6, 16, y)));
      colors[i * 3] = c.r;
      colors[i * 3 + 1] = c.g;
      colors[i * 3 + 2] = c.b;
    }
    geo.setAttribute('color', new THREE.BufferAttribute(colors, 3));
    const tex = Textures.ground().clone();
    tex.wrapS = tex.wrapT = THREE.RepeatWrapping;
    tex.repeat.set(36, 36);
    tex.needsUpdate = true;
    this.terrainMat = new THREE.MeshStandardMaterial({ map: tex, vertexColors: true, roughness: 0.96, metalness: 0 });
    this.terrainColor.copy(this.terrainMat.color);
    this.terrain = new THREE.Mesh(geo, this.terrainMat);
    this.terrain.receiveShadow = true;
    this.group.add(this.terrain);

    // Cliff boulders ring the boundary.
    for (let i = 0; i < 38; i++) {
      const a = (i / 38) * TAU + this.rnd() * 0.08;
      const r = this.boundary + 5 + this.rnd() * 6;
      const x = Math.cos(a) * r;
      const z = Math.sin(a) * r;
      const s = 6 + this.rnd() * 8;
      const m = new THREE.Mesh(new THREE.DodecahedronGeometry(s, 0), this.rnd() < 0.5 ? this.mats.rock : this.mats.rockDark);
      m.position.set(x, this.terrainHeight(x, z) + s * 0.2, z);
      m.scale.set(1, 0.8 + this.rnd() * 0.8, 1);
      m.rotation.set(this.rnd(), this.rnd() * TAU, this.rnd());
      m.castShadow = true;
      m.receiveShadow = true;
      this.scenery.add(m);
    }
  }

  private buildPlaza(): void {
    const tiles = Textures.stoneTiles().clone();
    tiles.wrapS = tiles.wrapT = THREE.RepeatWrapping;
    tiles.repeat.set(9, 9);
    tiles.needsUpdate = true;
    const floorMat = new THREE.MeshStandardMaterial({ map: tiles, color: 0xe8ddd0, roughness: 0.85, polygonOffset: true, polygonOffsetFactor: -2 });
    const floor = new THREE.Mesh(new THREE.CircleGeometry(25, 72), floorMat);
    floor.rotation.x = -Math.PI / 2;
    floor.position.y = 0.03;
    floor.receiveShadow = true;
    this.group.add(floor);
    // Curb.
    const curb = new THREE.Mesh(new THREE.TorusGeometry(25.2, 0.45, 6, 96), this.mats.stoneDark);
    curb.rotation.x = Math.PI / 2;
    curb.position.y = 0.05;
    curb.scale.z = 0.5;
    curb.receiveShadow = true;
    this.group.add(curb);
    // Engraved rune circle in the centre.
    const runeMat = new THREE.MeshBasicMaterial({ map: Textures.runes(), color: 0x3a3028, transparent: true, opacity: 0.22, depthWrite: false, polygonOffset: true, polygonOffsetFactor: -4 });
    const rune = new THREE.Mesh(new THREE.PlaneGeometry(16, 16), runeMat);
    rune.rotation.x = -Math.PI / 2;
    rune.position.y = 0.05;
    this.group.add(rune);

    // Ring of pillars (destructible).
    for (let i = 0; i < 8; i++) {
      const a = (i / 8) * TAU + TAU / 16;
      const x = Math.cos(a) * 21.5;
      const z = Math.sin(a) * 21.5;
      const broken = i % 3 === 1;
      const h = broken ? 3 + this.rnd() * 1.5 : 7.5;
      this.addPillar(x, z, 0.85, h, !broken);
    }
    // Braziers at cardinal directions.
    for (let i = 0; i < 4; i++) {
      const a = (i / 4) * TAU;
      const x = Math.cos(a) * 27.5;
      const z = Math.sin(a) * 27.5;
      const baseY = this.terrainHeight(x, z);
      this.addCyl(x, z, 0.55, 1.3, this.mats.stoneDark, { rTop: 0.4 });
      const bowl = new THREE.Mesh(new THREE.CylinderGeometry(0.85, 0.45, 0.45, 12, 1, true), this.mats.bronze);
      bowl.position.set(x, baseY + 1.5, z);
      bowl.castShadow = true;
      this.props.add(bowl);
      const coals = new THREE.Mesh(new THREE.CircleGeometry(0.75, 12), new THREE.MeshBasicMaterial({ color: 0xff7a2a }));
      coals.rotation.x = -Math.PI / 2;
      coals.position.set(x, baseY + 1.6, z);
      this.props.add(coals);
      this.braziers.push(new THREE.Vector3(x, baseY + 1.7, z));
    }
    // Statues at diagonals (destructible).
    for (let i = 0; i < 4; i++) {
      const a = (i / 4) * TAU + TAU / 8;
      const x = Math.cos(a) * 32;
      const z = Math.sin(a) * 32;
      this.addStatue(x, z, a + Math.PI);
    }
  }

  private addPillar(x: number, z: number, r: number, h: number, capital: boolean): void {
    const baseY = this.terrainHeight(x, z);
    const obj = new THREE.Group();
    const shaft = new THREE.Mesh(new THREE.CylinderGeometry(r * 0.88, r, h, 14), this.mats.marble);
    shaft.position.y = h / 2;
    shaft.castShadow = shaft.receiveShadow = true;
    obj.add(shaft);
    // Fluting rings.
    for (const y of [0.3, h - 0.3]) {
      const ring = new THREE.Mesh(new THREE.CylinderGeometry(r * 1.12, r * 1.12, 0.35, 14), this.mats.marbleDark);
      ring.position.y = y;
      ring.castShadow = true;
      obj.add(ring);
    }
    if (capital) {
      const cap = new THREE.Mesh(new THREE.BoxGeometry(r * 2.6, 0.5, r * 2.6), this.mats.marbleDark);
      cap.position.y = h + 0.25;
      cap.castShadow = true;
      obj.add(cap);
    }
    obj.position.set(x, baseY, z);
    this.props.add(obj);
    const rubble = new THREE.Group();
    const stump = new THREE.Mesh(new THREE.CylinderGeometry(r * 0.9, r, 1.6, 14), this.mats.marble);
    stump.position.y = 0.8;
    stump.castShadow = true;
    rubble.add(stump);
    for (let k = 0; k < 5; k++) {
      const chunk = new THREE.Mesh(new THREE.DodecahedronGeometry(0.3 + this.rnd() * 0.35, 0), this.mats.marble);
      chunk.position.set((this.rnd() - 0.5) * 3, 0.2, (this.rnd() - 0.5) * 3);
      chunk.castShadow = true;
      rubble.add(chunk);
    }
    rubble.position.copy(obj.position);
    rubble.visible = false;
    this.props.add(rubble);
    const topY = baseY + h + (capital ? 0.5 : 0);
    const collider: CylCollider = { kind: 'cyl', id: colliderId++, cx: x, cz: z, r: r * (capital ? 1.25 : 1), bottom: baseY - 1, top: topY, enabled: true, walkable: true, qid: 0 };
    this.insert(collider);
    const d: Destructible = {
      kind: 'pillar',
      object: obj,
      rubble,
      collider,
      hp: 520,
      maxHp: 520,
      alive: true,
      center: new THREE.Vector3(x, baseY + h / 2, z),
      radius: r,
      height: h,
      color: 0xe8e0d0,
      originalTop: topY,
    };
    collider.destructible = d;
    this.destructibles.push(d);
  }

  private addStatue(x: number, z: number, yaw: number): void {
    const baseY = this.terrainHeight(x, z);
    this.addBox(x, z, 2.4, 1.2, 2.4, yaw, this.mats.stoneDark);
    const obj = new THREE.Group();
    const m = this.mats.marble;
    const body = new THREE.Mesh(new THREE.CylinderGeometry(0.55, 0.75, 2.2, 8), m);
    body.position.y = 1.1;
    const chest = new THREE.Mesh(new THREE.CylinderGeometry(0.85, 0.55, 1.1, 8), m);
    chest.position.y = 2.6;
    const head = new THREE.Mesh(new THREE.SphereGeometry(0.42, 10, 8), m);
    head.position.y = 3.5;
    const armL = new THREE.Mesh(new THREE.CylinderGeometry(0.2, 0.18, 1.6, 6), m);
    armL.position.set(0.95, 2.3, 0.2);
    armL.rotation.x = -0.4;
    const sword = new THREE.Mesh(new THREE.BoxGeometry(0.15, 2.6, 0.35), m);
    sword.position.set(-0.9, 2.1, 0.5);
    sword.rotation.z = 0.1;
    for (const part of [body, chest, head, armL, sword]) {
      part.castShadow = true;
      part.receiveShadow = true;
      obj.add(part);
    }
    obj.position.set(x, baseY + 1.2, z);
    obj.rotation.y = yaw;
    this.props.add(obj);
    const rubble = new THREE.Group();
    for (let k = 0; k < 6; k++) {
      const chunk = new THREE.Mesh(new THREE.DodecahedronGeometry(0.35 + this.rnd() * 0.3, 0), m);
      chunk.position.set((this.rnd() - 0.5) * 2, 0.3, (this.rnd() - 0.5) * 2);
      chunk.castShadow = true;
      rubble.add(chunk);
    }
    rubble.position.set(x, baseY + 1.2, z);
    rubble.visible = false;
    this.props.add(rubble);
    const collider: CylCollider = { kind: 'cyl', id: colliderId++, cx: x, cz: z, r: 0.9, bottom: baseY + 1.2, top: baseY + 5, enabled: true, walkable: false, qid: 0 };
    this.insert(collider);
    const d: Destructible = {
      kind: 'statue',
      object: obj,
      rubble,
      collider,
      hp: 380,
      maxHp: 380,
      alive: true,
      center: new THREE.Vector3(x, baseY + 3, z),
      radius: 0.9,
      height: 3.8,
      color: 0xe8e0d0,
      originalTop: baseY + 5,
    };
    collider.destructible = d;
    this.destructibles.push(d);
  }

  private addCrate(x: number, z: number, size: number, baseY?: number, yaw = 0): void {
    const by = baseY ?? this.terrainHeight(x, z);
    const { mesh, collider } = this.addBox(x, z, size, size, size, yaw, this.mats.wood, { baseY: by, sink: 0 });
    // Wood texture is per-face so reset UVs.
    mesh.geometry.dispose();
    mesh.geometry = new THREE.BoxGeometry(size, size, size);
    mesh.position.y = by + size / 2;
    const d: Destructible = {
      kind: 'crate',
      object: mesh,
      rubble: null,
      collider,
      hp: 60,
      maxHp: 60,
      alive: true,
      center: new THREE.Vector3(x, by + size / 2, z),
      radius: size * 0.6,
      height: size,
      color: 0x8a6035,
      originalTop: by + size,
    };
    if (collider) collider.destructible = d;
    this.destructibles.push(d);
  }

  private addBarrel(x: number, z: number): void {
    const by = this.terrainHeight(x, z);
    const { mesh, collider } = this.addCyl(x, z, 0.5, 1.2, this.mats.wood, { baseY: by, sink: 0, seg: 12 });
    const band = new THREE.Mesh(new THREE.CylinderGeometry(0.53, 0.53, 0.1, 12), this.mats.metal);
    band.position.y = 0.3;
    mesh.add(band);
    const band2 = band.clone();
    band2.position.y = -0.3;
    mesh.add(band2);
    const d: Destructible = {
      kind: 'barrel',
      object: mesh,
      rubble: null,
      collider,
      hp: 45,
      maxHp: 45,
      alive: true,
      center: new THREE.Vector3(x, by + 0.6, z),
      radius: 0.5,
      height: 1.2,
      color: 0x7a5530,
      originalTop: by + 1.2,
    };
    if (collider) collider.destructible = d;
    this.destructibles.push(d);
  }

  private buildTemple(): void {
    const cx = 0;
    const cz = -62;
    const base = 0.4;
    // Main platform.
    this.addBox(cx, cz, 28, 3.2, 16, 0, this.mats.stone, { baseY: base });
    // Stairs (walkable steps) on the south side.
    for (let i = 0; i < 5; i++) {
      const h = 0.64 * (i + 1);
      this.addBox(cx, cz + 8 + (5 - i) * 1.1 - 0.55, 12, h, 1.1, 0, this.mats.stoneDark, { baseY: base });
    }
    // Columns on the platform.
    const top = base + 3.2;
    for (let i = 0; i < 5; i++) {
      for (const row of [-5, 4.5]) {
        const x = cx - 11 + i * 5.5;
        const broken = (i + (row > 0 ? 1 : 0)) % 3 === 0;
        const h = broken ? 2 + this.rnd() * 2 : 8;
        const { mesh } = this.addCyl(x, cz + row, 0.75, h, this.mats.marble, { baseY: top, sink: 0.2, rTop: 0.65 });
        mesh.castShadow = true;
      }
    }
    // Lintel across some columns.
    this.addBox(cx - 5.5, cz - 5, 12.5, 1.1, 2, 0, this.mats.marbleDark, { baseY: top + 8, sink: 0 });
    this.addBox(cx + 8.25, cz + 4.5, 7, 1.1, 2, 0, this.mats.marbleDark, { baseY: top + 8, sink: 0 });
    // Jagged back wall.
    for (let i = 0; i < 7; i++) {
      const h = 5 + this.rnd() * 6;
      this.addBox(cx - 12 + i * 4, cz - 8.5, 4.1, h, 1.4, 0, this.mats.stone, { baseY: top });
    }
    // Side walls.
    for (const side of [-1, 1]) {
      for (let i = 0; i < 2; i++) {
        this.addBox(cx + side * 14.3, cz - 5 + i * 5, 1.2, 3 + this.rnd() * 4, 4.8, 0, this.mats.stone, { baseY: top });
      }
    }
    // Barrels around the temple.
    for (let i = 0; i < 6; i++) this.addBarrel(cx - 16 + (i % 3) * 1.15, cz + 10 + Math.floor(i / 3) * 1.2);
    this.addCrate(cx + 16, cz + 9, 1.4);
    this.addCrate(cx + 17.5, cz + 9.3, 1.4);
    this.addCrate(cx + 16.7, cz + 9.2, 1.3, base + 1.4);
  }

  private buildEastRuins(): void {
    const cx = 60;
    const cz = 6;
    const walls: [number, number, number, number, number][] = [
      // x, z, length, height, yaw
      [-8, -10, 14, 4.5, 0],
      [-15, -3, 12, 3.2, Math.PI / 2],
      [4, -12, 8, 6, 0.2],
      [10, 2, 12, 3.8, Math.PI / 2],
      [-4, 8, 10, 2.6, 0.1],
      [6, 12, 7, 5, -0.3],
      [-12, 12, 6, 2, Math.PI / 3],
    ];
    for (const [x, z, len, h, yaw] of walls) {
      // Split each wall into segments with a gap (broken look).
      const segs = 3;
      for (let i = 0; i < segs; i++) {
        if (i === 1 && this.rnd() < 0.5) continue;
        const off = (i - (segs - 1) / 2) * (len / segs);
        const sh = h * (0.55 + this.rnd() * 0.45);
        const wx = cx + x + Math.cos(yaw) * off;
        const wz = cz + z - Math.sin(yaw) * off;
        this.addBox(wx, wz, len / segs - 0.1, sh, 1.1, yaw, this.mats.stone);
      }
    }
    // Raised ledge with a ramp of blocks.
    this.addBox(cx + 2, cz - 2, 8, 2.2, 6, 0, this.mats.stoneDark);
    this.addBox(cx - 3.2, cz - 2, 2.4, 1.1, 3, 0, this.mats.stoneDark);
    // Crates.
    const crates: [number, number, number][] = [
      [-2, 4, 0],
      [-0.6, 4.2, 0],
      [-1.3, 4.1, 1],
      [12, -6, 0],
      [13.4, -6.2, 0],
      [8, 8, 0],
      [-10, -6, 0],
      [-9, -7.3, 0],
    ];
    for (const [x, z, lvl] of crates) {
      const by = this.terrainHeight(cx + x, cz + z) + lvl * 1.3;
      this.addCrate(cx + x, cz + z, 1.3, by, this.rnd() * 0.5);
    }
    for (let i = 0; i < 4; i++) this.addBarrel(cx + 14 + (i % 2) * 1.1, cz + 6 + Math.floor(i / 2) * 1.1);
  }

  private buildWestTower(): void {
    const cx = -60;
    const cz = -8;
    const base = 0.8;
    this.addBox(cx, cz, 14, 2.4, 14, 0, this.mats.stoneDark, { baseY: base });
    // Steps.
    for (let i = 0; i < 4; i++) this.addBox(cx + 7 + (4 - i) * 1 - 0.5, cz + 3, 1, 0.6 * (i + 1), 5, 0, this.mats.stone, { baseY: base });
    const pTop = base + 2.4;
    // Tower with climbable ledges.
    this.addBox(cx - 3, cz - 3, 6, 9, 6, 0, this.mats.stone, { baseY: pTop, sink: 0.1 });
    this.addBox(cx + 1.2, cz - 3, 2.4, 2, 3, 0, this.mats.stoneDark, { baseY: pTop, sink: 0.1 });
    this.addBox(cx + 0.8, cz + 0.8, 3, 4.1, 2.2, 0, this.mats.stoneDark, { baseY: pTop, sink: 0.1 });
    this.addBox(cx - 2.2, cz + 1.2, 2.6, 6.3, 2.4, 0, this.mats.stoneDark, { baseY: pTop, sink: 0.1 });
    // Battlements.
    for (let i = 0; i < 4; i++) {
      const a = (i / 4) * TAU + TAU / 8;
      this.addBox(cx - 3 + Math.cos(a) * 2.4, cz - 3 + Math.sin(a) * 2.4, 1, 1, 1, 0, this.mats.stone, { baseY: pTop + 9, sink: 0 });
    }
    // Banner pole.
    const pole = new THREE.Mesh(new THREE.CylinderGeometry(0.08, 0.08, 5, 6), this.mats.metal);
    pole.position.set(cx - 3, pTop + 11.5, cz - 3);
    this.props.add(pole);
    const banner = new THREE.Mesh(new THREE.PlaneGeometry(2.2, 1.3), new THREE.MeshStandardMaterial({ color: 0xa3262a, side: THREE.DoubleSide, roughness: 0.9 }));
    banner.position.set(cx - 1.9, pTop + 13.2, cz - 3);
    this.props.add(banner);
    // Crates at the base.
    this.addCrate(cx + 8, cz - 6, 1.3);
    this.addCrate(cx + 9.4, cz - 6.2, 1.3);
    this.addCrate(cx + 8.7, cz - 6.1, 1.3, this.terrainHeight(cx + 8.7, cz - 6.1) + 1.3);
  }

  private buildArches(): void {
    const cx = 0;
    const cz = 62;
    for (let i = 0; i < 3; i++) {
      const x = cx - 12 + i * 12;
      const z = cz + (i === 1 ? 3 : 0);
      const h = 7;
      for (const side of [-1, 1]) this.addBox(x + side * 2.8, z, 1.4, h, 1.4, 0, this.mats.stone);
      const by = this.terrainHeight(x, z);
      if (i !== 2) this.addBox(x, z, 7.2, 1.2, 1.8, 0, this.mats.stoneDark, { baseY: by + h, sink: 0 });
      else this.addBox(x - 1.5, z, 4, 1.2, 1.8, 0.15, this.mats.stoneDark, { baseY: by + h - 0.6, sink: 0 });
    }
    // Fallen column.
    const fallen = new THREE.Mesh(new THREE.CylinderGeometry(0.75, 0.75, 8, 14), this.mats.marble);
    fallen.rotation.z = Math.PI / 2;
    fallen.rotation.y = 0.4;
    fallen.position.set(cx + 6, this.terrainHeight(cx + 6, cz - 8) + 0.7, cz - 8);
    fallen.castShadow = fallen.receiveShadow = true;
    this.props.add(fallen);
    const col: BoxCollider = { kind: 'box', id: colliderId++, cx: cx + 6, cz: cz - 8, hx: 4, hz: 0.75, cos: Math.cos(0.4), sin: Math.sin(0.4), bottom: -2, top: fallen.position.y + 0.75, enabled: true, walkable: true, qid: 0 };
    this.insert(col);
    for (let i = 0; i < 3; i++) this.addCrate(cx - 17 + i * 1.4, cz - 4, 1.3);
  }

  private buildFloatingIsles(): void {
    const cx = 48;
    const cz = 48;
    const isles: [number, number, number, number][] = [
      [-6, -4, 2.1, 3.2],
      [0, 2, 4.0, 2.8],
      [6, -3, 5.9, 2.6],
      [2, -9, 7.6, 2.4],
    ];
    for (const [x, z, top, r] of isles) {
      const wx = cx + x;
      const wz = cz + z;
      const g = new THREE.Group();
      const slab = new THREE.Mesh(new THREE.CylinderGeometry(r, r * 0.92, 0.8, 9), this.mats.rock);
      slab.position.y = -0.4;
      const under = new THREE.Mesh(new THREE.ConeGeometry(r * 0.9, r * 1.6, 8), this.mats.rockDark);
      under.rotation.x = Math.PI;
      under.position.y = -0.8 - r * 0.8;
      const grassTop = new THREE.Mesh(new THREE.CylinderGeometry(r * 0.98, r * 0.98, 0.08, 9), this.mats.moss);
      grassTop.position.y = 0.02;
      for (const m of [slab, under, grassTop]) {
        m.castShadow = true;
        m.receiveShadow = true;
        g.add(m);
      }
      for (let k = 0; k < 3; k++) {
        const cr = new THREE.Mesh(new THREE.OctahedronGeometry(0.3 + this.rnd() * 0.3, 0), this.mats.crystal);
        cr.position.set((this.rnd() - 0.5) * r, -0.9 - this.rnd() * r, (this.rnd() - 0.5) * r);
        cr.scale.y = 2;
        g.add(cr);
      }
      g.position.set(wx, top, wz);
      this.props.add(g);
      this.crystalLights.push(new THREE.Vector3(wx, top - 1.5, wz));
      const collider: CylCollider = { kind: 'cyl', id: colliderId++, cx: wx, cz: wz, r, bottom: top - 1.2, top, enabled: true, walkable: true, qid: 0 };
      this.insert(collider);
    }
    // Crystal cluster on the ground below.
    for (let k = 0; k < 7; k++) {
      const x = cx + (this.rnd() - 0.5) * 12;
      const z = cz + (this.rnd() - 0.5) * 12;
      const cr = new THREE.Mesh(new THREE.OctahedronGeometry(0.5 + this.rnd() * 0.6, 0), this.mats.crystal);
      cr.scale.y = 2.4;
      cr.position.set(x, this.terrainHeight(x, z) + 0.8, z);
      cr.rotation.set(this.rnd() * 0.5, this.rnd() * TAU, this.rnd() * 0.5);
      this.props.add(cr);
    }
  }

  private buildGraveyard(): void {
    // South-west field of broken obelisks and low walls.
    const cx = -45;
    const cz = 50;
    for (let i = 0; i < 9; i++) {
      const x = cx + (i % 3) * 5 - 5 + (this.rnd() - 0.5) * 1.5;
      const z = cz + Math.floor(i / 3) * 5 - 5 + (this.rnd() - 0.5) * 1.5;
      const h = 1.5 + this.rnd() * 3.5;
      this.addBox(x, z, 1.1, h, 0.5, this.rnd() * 0.6 - 0.3, this.mats.stoneDark, { walkable: false });
    }
    this.addBox(cx, cz - 9, 14, 1.6, 0.9, 0.05, this.mats.stone);
    this.addBox(cx - 8, cz, 0.9, 1.4, 12, 0, this.mats.stone);
    const obelisk = this.addBox(cx + 8, cz + 2, 1.8, 9, 1.8, 0.3, this.mats.stoneDark);
    obelisk.mesh.castShadow = true;
  }

  private buildRocks(): void {
    // Large boulders (solid).
    for (let i = 0; i < 30; i++) {
      const a = this.rnd() * TAU;
      const r = 34 + this.rnd() * 52;
      const x = Math.cos(a) * r;
      const z = Math.sin(a) * r;
      if (this.flatten.some((f) => Math.hypot(x - f.x, z - f.z) < f.r * 0.9)) continue;
      const s = 1.2 + this.rnd() * 2.2;
      const by = this.terrainHeight(x, z);
      const m = new THREE.Mesh(new THREE.DodecahedronGeometry(s, 0), this.rnd() < 0.6 ? this.mats.rock : this.mats.rockDark);
      m.position.set(x, by + s * 0.35, z);
      m.scale.set(1 + this.rnd() * 0.4, 0.7 + this.rnd() * 0.4, 1 + this.rnd() * 0.4);
      m.rotation.set(this.rnd(), this.rnd() * TAU, this.rnd());
      m.castShadow = true;
      m.receiveShadow = true;
      this.props.add(m);
      const collider: CylCollider = { kind: 'cyl', id: colliderId++, cx: x, cz: z, r: s * 0.95, bottom: by - 1, top: by + s * 0.35 + s * m.scale.y * 0.7, enabled: true, walkable: true, qid: 0 };
      this.insert(collider);
    }
    // Small scattered rocks (visual only).
    const count = 260;
    const geo = new THREE.DodecahedronGeometry(0.35, 0);
    const inst = new THREE.InstancedMesh(geo, this.mats.rock, count);
    const m4 = new THREE.Matrix4();
    const q = new THREE.Quaternion();
    const e = new THREE.Euler();
    const sc = new THREE.Vector3();
    const p = new THREE.Vector3();
    for (let i = 0; i < count; i++) {
      const a = this.rnd() * TAU;
      const r = 26 + this.rnd() * 64;
      p.set(Math.cos(a) * r, 0, Math.sin(a) * r);
      p.y = this.terrainHeight(p.x, p.z) + 0.05;
      e.set(this.rnd() * 3, this.rnd() * 3, this.rnd() * 3);
      q.setFromEuler(e);
      const s = 0.4 + this.rnd() * 1.2;
      sc.set(s, s * (0.5 + this.rnd() * 0.5), s);
      m4.compose(p, q, sc);
      inst.setMatrixAt(i, m4);
    }
    inst.castShadow = true;
    inst.receiveShadow = true;
    this.props.add(inst);
  }

  private buildGrass(): void {
    // Tuft: three crossed blades.
    const blade = new THREE.BufferGeometry();
    const verts: number[] = [];
    const cols: number[] = [];
    for (let i = 0; i < 3; i++) {
      const a = (i / 3) * Math.PI;
      const cx = Math.cos(a) * 0.12;
      const cz = Math.sin(a) * 0.12;
      verts.push(-cx, 0, -cz, cx, 0, cz, cx * 0.3, 0.42, cz * 0.3);
      cols.push(0.2, 0.28, 0.1, 0.2, 0.28, 0.1, 0.45, 0.55, 0.22);
    }
    blade.setAttribute('position', new THREE.Float32BufferAttribute(verts, 3));
    blade.setAttribute('color', new THREE.Float32BufferAttribute(cols, 3));
    blade.computeVertexNormals();
    const mat = new THREE.MeshLambertMaterial({ vertexColors: true, side: THREE.DoubleSide });
    const count = 3200;
    const inst = new THREE.InstancedMesh(blade, mat, count);
    const m4 = new THREE.Matrix4();
    const q = new THREE.Quaternion();
    const sc = new THREE.Vector3();
    const p = new THREE.Vector3();
    const up = new THREE.Vector3(0, 1, 0);
    let n = 0;
    for (let i = 0; i < count * 2 && n < count; i++) {
      const a = this.rnd() * TAU;
      const r = 27 + this.rnd() * 60;
      p.set(Math.cos(a) * r, 0, Math.sin(a) * r);
      if (this.flatten.some((f) => Math.hypot(p.x - f.x, p.z - f.z) < f.r * 0.6)) continue;
      p.y = this.terrainHeight(p.x, p.z);
      q.setFromAxisAngle(up, this.rnd() * TAU);
      const s = 0.7 + this.rnd() * 1.1;
      sc.set(s, s * (0.7 + this.rnd() * 0.8), s);
      m4.compose(p, q, sc);
      inst.setMatrixAt(n++, m4);
    }
    inst.count = n;
    this.props.add(inst);
  }

  private buildPortals(): void {
    const mat = new THREE.MeshBasicMaterial({ map: Textures.runes(), color: 0xff3344, transparent: true, opacity: 0.25, blending: THREE.AdditiveBlending, depthWrite: false });
    for (let i = 0; i < 6; i++) {
      const a = (i / 6) * TAU + 0.35;
      const r = 72;
      const x = Math.cos(a) * r;
      const z = Math.sin(a) * r;
      const p = new THREE.Vector3(x, this.terrainHeight(x, z), z);
      this.spawnPoints.push(p);
      const m = new THREE.Mesh(new THREE.PlaneGeometry(7, 7), mat.clone());
      m.rotation.x = -Math.PI / 2;
      m.position.set(x, p.y + 0.12, z);
      this.group.add(m);
      this.portalMeshes.push(m);
    }
  }

  /** Per-frame ambience (portal pulses). Fire in braziers is emitted by VFXManager. */
  update(dt: number, time: number): void {
    for (const m of this.portalMeshes) {
      const mat = m.material as THREE.MeshBasicMaterial;
      const target = m.userData.active > 0 ? 0.9 : 0.22;
      if (m.userData.active > 0) m.userData.active -= dt;
      mat.opacity += (target - mat.opacity) * Math.min(1, dt * 4);
      m.rotation.z += dt * (m.userData.active > 0 ? 1.5 : 0.1);
    }
    void time;
  }
}
