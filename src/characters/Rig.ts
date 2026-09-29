import * as THREE from 'three';
import { BONES, BoneName } from './AnimationClip';

/**
 * Procedural humanoid rig. Every fighter and enemy is built from joints
 * (THREE.Object3D) with primitive meshes attached, so the same animation
 * data drives all bodies while proportions stay unique per character.
 */
export interface Rig {
  /** Pivot at the feet. */
  root: THREE.Group;
  /** Receives the animated root offset/rotation. */
  body: THREE.Group;
  bones: Record<BoneName, THREE.Object3D>;
  sockets: Record<string, THREE.Object3D>;
  /** Materials that react to hit flashes / tints. */
  materials: THREE.MeshStandardMaterial[];
  height: number;
  extras: Record<string, THREE.Object3D>;
}

export interface BodyColors {
  skin: number;
  torso: number;
  arms: number;
  legs: number;
  boots: number;
  gloves: number;
  accent: number;
  belt: number;
}

export interface BodySpec {
  hipHeight: number;
  torso: number;
  shoulderWidth: number;
  hipWidth: number;
  chestWidth: number;
  chestDepth: number;
  waistWidth: number;
  upperArm: number;
  foreArm: number;
  armRadius: number;
  foreArmRadius: number;
  thighRadius: number;
  shinRadius: number;
  handSize: number;
  footLength: number;
  neck: number;
  headRadius: number;
  colors: BodyColors;
  roughness?: number;
  metalness?: number;
}

const geoCache = new Map<string, THREE.BufferGeometry>();
function cached<T extends THREE.BufferGeometry>(key: string, make: () => T): T {
  let g = geoCache.get(key);
  if (!g) {
    g = make();
    geoCache.set(key, g);
  }
  return g as T;
}

export const Geo = {
  capsule: (r: number, len: number) =>
    cached(`cap:${r.toFixed(3)}:${len.toFixed(3)}`, () => new THREE.CapsuleGeometry(r, Math.max(0.001, len), 4, 10)),
  sphere: (r: number, w = 14, h = 10) => cached(`sph:${r}:${w}:${h}`, () => new THREE.SphereGeometry(r, w, h)),
  box: (x: number, y: number, z: number) => cached(`box:${x}:${y}:${z}`, () => new THREE.BoxGeometry(x, y, z)),
  cyl: (rt: number, rb: number, h: number, seg = 10) =>
    cached(`cyl:${rt}:${rb}:${h}:${seg}`, () => new THREE.CylinderGeometry(rt, rb, h, seg)),
  cone: (r: number, h: number, seg = 8) => cached(`cone:${r}:${h}:${seg}`, () => new THREE.ConeGeometry(r, h, seg)),
  ico: (r: number, d = 0) => cached(`ico:${r}:${d}`, () => new THREE.IcosahedronGeometry(r, d)),
  octa: (r: number) => cached(`oct:${r}`, () => new THREE.OctahedronGeometry(r, 0)),
  torus: (r: number, t: number, rs = 6, ts = 20, arc = Math.PI * 2) =>
    cached(`tor:${r}:${t}:${rs}:${ts}:${arc}`, () => new THREE.TorusGeometry(r, t, rs, ts, arc)),
  dodeca: (r: number) => cached(`dod:${r}`, () => new THREE.DodecahedronGeometry(r, 0)),
  tetra: (r: number) => cached(`tet:${r}`, () => new THREE.TetrahedronGeometry(r, 0)),
};

export function stdMat(color: number, opts: Partial<THREE.MeshStandardMaterialParameters> = {}): THREE.MeshStandardMaterial {
  return new THREE.MeshStandardMaterial({ color, roughness: 0.6, metalness: 0.1, ...opts });
}

export function glowMat(color: number, intensity = 2): THREE.MeshStandardMaterial {
  return new THREE.MeshStandardMaterial({ color, emissive: color, emissiveIntensity: intensity, roughness: 0.4 });
}

export function basicGlow(color: number, opacity = 1): THREE.MeshBasicMaterial {
  return new THREE.MeshBasicMaterial({
    color,
    transparent: opacity < 1,
    opacity,
    blending: THREE.AdditiveBlending,
    depthWrite: false,
  });
}

export class RigBuilder {
  readonly rig: Rig;
  readonly mats: Record<keyof BodyColors, THREE.MeshStandardMaterial>;

  constructor(public spec: BodySpec) {
    const c = spec.colors;
    const rough = spec.roughness ?? 0.6;
    const metal = spec.metalness ?? 0.1;
    const m = (col: number) => stdMat(col, { roughness: rough, metalness: metal });
    this.mats = {
      skin: stdMat(c.skin, { roughness: 0.7, metalness: 0 }),
      torso: m(c.torso),
      arms: m(c.arms),
      legs: m(c.legs),
      boots: m(c.boots),
      gloves: m(c.gloves),
      accent: m(c.accent),
      belt: m(c.belt),
    };
    this.rig = this.build();
  }

  private addMesh(parent: THREE.Object3D, geo: THREE.BufferGeometry, mat: THREE.Material, pos?: [number, number, number], scale?: [number, number, number], rot?: [number, number, number]): THREE.Mesh {
    const mesh = new THREE.Mesh(geo, mat);
    if (pos) mesh.position.set(pos[0], pos[1], pos[2]);
    if (scale) mesh.scale.set(scale[0], scale[1], scale[2]);
    if (rot) mesh.rotation.set(rot[0], rot[1], rot[2]);
    mesh.castShadow = true;
    mesh.receiveShadow = false;
    parent.add(mesh);
    return mesh;
  }

  private build(): Rig {
    const s = this.spec;
    const mats = this.mats;
    const root = new THREE.Group();
    root.name = 'rig-root';
    const body = new THREE.Group();
    root.add(body);

    const bones = {} as Record<BoneName, THREE.Object3D>;
    for (const b of BONES) {
      const o = new THREE.Object3D();
      o.name = b;
      bones[b] = o;
    }

    const footH = 0.07;
    const legLen = s.hipHeight - footH;
    const thigh = legLen * 0.5;
    const shin = legLen * 0.5;
    const spineLen = s.torso * 0.38;
    const chestLen = s.torso * 0.62;

    // Hierarchy + joint offsets.
    body.add(bones.hips);
    bones.hips.position.set(0, s.hipHeight, 0);
    bones.hips.add(bones.spine);
    bones.spine.position.set(0, 0.04, 0);
    bones.spine.add(bones.chest);
    bones.chest.position.set(0, spineLen, 0);
    bones.chest.add(bones.neck);
    bones.neck.position.set(0, chestLen, 0);
    bones.neck.add(bones.head);
    bones.head.position.set(0, s.neck, 0);

    const shoulderY = chestLen * 0.86;
    bones.chest.add(bones.armL, bones.armR);
    bones.armL.position.set(s.shoulderWidth, shoulderY, 0);
    bones.armR.position.set(-s.shoulderWidth, shoulderY, 0);
    bones.armL.add(bones.foreL);
    bones.armR.add(bones.foreR);
    bones.foreL.position.set(0, -s.upperArm, 0);
    bones.foreR.position.set(0, -s.upperArm, 0);
    bones.foreL.add(bones.handL);
    bones.foreR.add(bones.handR);
    bones.handL.position.set(0, -s.foreArm, 0);
    bones.handR.position.set(0, -s.foreArm, 0);

    bones.hips.add(bones.legL, bones.legR);
    bones.legL.position.set(s.hipWidth, -0.02, 0);
    bones.legR.position.set(-s.hipWidth, -0.02, 0);
    bones.legL.add(bones.shinL);
    bones.legR.add(bones.shinR);
    bones.shinL.position.set(0, -thigh, 0);
    bones.shinR.position.set(0, -thigh, 0);
    bones.shinL.add(bones.footL);
    bones.shinR.add(bones.footR);
    bones.footL.position.set(0, -shin, 0);
    bones.footR.position.set(0, -shin, 0);

    // --- Meshes --------------------------------------------------------
    // Pelvis
    this.addMesh(bones.hips, Geo.cyl(s.waistWidth * 0.95, s.hipWidth + s.thighRadius * 0.9, 0.2, 10), mats.legs, [0, -0.04, 0], [1, 1, s.chestDepth / s.chestWidth + 0.1]);
    // Belt
    this.addMesh(bones.hips, Geo.cyl(s.waistWidth * 1.02, s.waistWidth * 1.02, 0.07, 12), mats.belt, [0, 0.07, 0], [1, 1, s.chestDepth / s.chestWidth + 0.12]);
    // Abdomen
    this.addMesh(bones.spine, Geo.cyl(s.waistWidth * 1.02, s.waistWidth, spineLen + 0.04, 10), mats.torso, [0, spineLen * 0.5, 0], [1, 1, s.chestDepth / s.chestWidth + 0.1]);
    // Chest (V taper)
    const chestMesh = this.addMesh(
      bones.chest,
      Geo.cyl(s.chestWidth, s.waistWidth * 1.02, chestLen, 10),
      mats.torso,
      [0, chestLen * 0.5, 0],
      [1, 1, s.chestDepth / s.chestWidth],
    );
    chestMesh.name = 'chest-mesh';
    // Shoulders caps
    for (const side of [1, -1]) {
      this.addMesh(bones.chest, Geo.sphere(s.armRadius * 1.35), mats.torso, [side * s.shoulderWidth, shoulderY, 0]);
    }
    // Neck + head
    this.addMesh(bones.neck, Geo.cyl(s.headRadius * 0.42, s.headRadius * 0.48, s.neck + 0.04, 8), mats.skin, [0, s.neck * 0.5, 0]);
    const head = this.addMesh(bones.head, Geo.sphere(s.headRadius, 16, 12), mats.skin, [0, s.headRadius * 0.85, 0], [0.92, 1.05, 1]);
    head.name = 'head-mesh';

    // Arms
    for (const [arm, fore, hand] of [
      [bones.armL, bones.foreL, bones.handL],
      [bones.armR, bones.foreR, bones.handR],
    ] as const) {
      this.addMesh(arm, Geo.capsule(s.armRadius, s.upperArm - s.armRadius), mats.arms, [0, -s.upperArm * 0.5, 0]);
      this.addMesh(fore, Geo.capsule(s.foreArmRadius, s.foreArm - s.foreArmRadius), mats.arms, [0, -s.foreArm * 0.5, 0]);
      this.addMesh(hand, Geo.box(s.handSize, s.handSize * 1.1, s.handSize * 0.9), mats.gloves, [0, -s.handSize * 0.45, 0.01]);
    }
    // Legs
    for (const [leg, sh, foot] of [
      [bones.legL, bones.shinL, bones.footL],
      [bones.legR, bones.shinR, bones.footR],
    ] as const) {
      this.addMesh(leg, Geo.capsule(s.thighRadius, thigh - s.thighRadius * 0.5), mats.legs, [0, -thigh * 0.5, 0]);
      this.addMesh(sh, Geo.capsule(s.shinRadius, shin - s.shinRadius * 0.5), mats.boots, [0, -shin * 0.5, 0]);
      this.addMesh(foot, Geo.box(s.shinRadius * 2.1, footH * 1.4, s.footLength), mats.boots, [0, -footH * 0.4, s.footLength * 0.28]);
    }

    // Sockets
    const sockets: Record<string, THREE.Object3D> = {};
    const mk = (name: string, parent: THREE.Object3D, pos: [number, number, number]) => {
      const o = new THREE.Object3D();
      o.name = `socket-${name}`;
      o.position.set(pos[0], pos[1], pos[2]);
      parent.add(o);
      sockets[name] = o;
    };
    mk('handL', bones.handL, [0, -s.handSize * 0.5, 0]);
    mk('handR', bones.handR, [0, -s.handSize * 0.5, 0]);
    mk('footL', bones.footL, [0, 0, s.footLength * 0.3]);
    mk('footR', bones.footR, [0, 0, s.footLength * 0.3]);
    mk('head', bones.head, [0, s.headRadius * 0.85, 0]);
    mk('chest', bones.chest, [0, chestLen * 0.55, s.chestDepth * 0.8]);
    mk('back', bones.chest, [0, chestLen * 0.6, -s.chestDepth * 0.9]);
    mk('center', bones.spine, [0, spineLen, 0]);
    mk('weapon', bones.handR, [0, -s.handSize * 0.6, 0]);

    const height = s.hipHeight + s.torso + 0.04 + s.neck + s.headRadius * 1.9;

    root.traverse((o) => {
      if ((o as THREE.Mesh).isMesh) (o as THREE.Mesh).castShadow = true;
    });

    return {
      root,
      body,
      bones,
      sockets,
      materials: Object.values(mats),
      height,
      extras: {},
    };
  }

  /** Adds a mesh to a bone or socket and registers its material for hit flashes. */
  attach(
    parent: THREE.Object3D,
    geo: THREE.BufferGeometry,
    mat: THREE.Material,
    pos: [number, number, number] = [0, 0, 0],
    rot: [number, number, number] = [0, 0, 0],
    scale: [number, number, number] = [1, 1, 1],
  ): THREE.Mesh {
    const mesh = this.addMesh(parent, geo, mat, pos, scale, rot);
    if ((mat as THREE.MeshStandardMaterial).isMeshStandardMaterial && !this.rig.materials.includes(mat as THREE.MeshStandardMaterial)) {
      this.rig.materials.push(mat as THREE.MeshStandardMaterial);
    }
    if ((mat as THREE.MeshBasicMaterial).isMeshBasicMaterial) mesh.castShadow = false;
    return mesh;
  }

  /** Eyes (glowing) facing forward (+Z) on the head. */
  eyes(color: number, size = 0.028, spread = 0.055, y = 0.02, shape: 'round' | 'slit' = 'round'): void {
    const s = this.spec;
    const mat = basicGlow(color);
    for (const side of [1, -1]) {
      const geo = shape === 'slit' ? Geo.box(size * 2, size * 0.5, size) : Geo.sphere(size, 8, 6);
      const e = new THREE.Mesh(geo, mat);
      e.position.set(side * spread, s.headRadius * 0.85 + y, s.headRadius * 0.9);
      this.rig.bones.head.add(e);
    }
  }
}

/** Creates a translucent copy of a rig in its current pose (afterimages, clones). */
export function cloneRigVisual(rig: Rig, material: THREE.Material): THREE.Object3D {
  const copy = rig.root.clone(true);
  const toRemove: THREE.Object3D[] = [];
  copy.traverse((o) => {
    if (o.userData.noClone) toRemove.push(o);
    const mesh = o as THREE.Mesh;
    if (mesh.isMesh) {
      mesh.material = material;
      mesh.castShadow = false;
    }
    if ((o as THREE.Points).isPoints || (o as THREE.Light).isLight) toRemove.push(o);
  });
  for (const o of toRemove) o.parent?.remove(o);
  return copy;
}
