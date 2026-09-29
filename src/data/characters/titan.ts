import * as THREE from 'three';
import type { AbilityDef, AttackStep, CharacterDefinition, CharacterStats } from '../types';
import type { Actor } from '../../entities/Actor';
import type { World } from '../../core/World';
import { RigBuilder, Geo, glowMat, stdMat, basicGlow, Rig } from '../../characters/Rig';
import { AnimationSet, PoseSpec, clip, combine, gaitClip, idleClip, addRot } from '../../characters/AnimationClip';
import { EarthFX, GenericFX } from '../../vfx/ElementFX';
import { Effects } from '../../combat/Effects';
import { LYING_BACK, LYING_FACE, areaDamage } from './kit';
import { TAU, rand, yawFromDir, distXZ } from '../../core/math';
import { Textures } from '../../vfx/Textures';

// ================================================================= stats ==
const stats: CharacterStats = {
  maxHealth: 1600,
  moveSpeed: 6.5,
  walkSpeed: 2.6,
  acceleration: 9,
  turnSpeed: 6.5,
  attackDamage: 60,
  defense: 80,
  attackSpeed: 0.7,
  dodgeDistance: 4.5,
  dodgeDuration: 0.42,
  dodgeCooldown: 1.2,
  dodgeIFrames: 0.28,
  abilityPower: 1.3,
  cooldownMultiplier: 1.25,
  critChance: 0.05,
  critMultiplier: 1.5,
  jumpVelocity: 10,
  airJumps: 0,
  gravityScale: 1.15,
  poise: 80,
  mass: 3.2,
  scale: 1.45,
  ultChargeRate: 0.9,
};

const AMBER = 0xffa040;
const ROCK = 0x6e6254;

// ================================================================= model ==
function buildModel(): Rig {
  const b = new RigBuilder({
    hipHeight: 0.82,
    torso: 0.78,
    shoulderWidth: 0.37,
    hipWidth: 0.15,
    chestWidth: 0.42,
    chestDepth: 0.3,
    waistWidth: 0.27,
    upperArm: 0.34,
    foreArm: 0.33,
    armRadius: 0.115,
    foreArmRadius: 0.11,
    thighRadius: 0.135,
    shinRadius: 0.12,
    handSize: 0.2,
    footLength: 0.34,
    neck: 0.04,
    headRadius: 0.12,
    colors: { skin: 0x8f8072, torso: 0x5a4d42, arms: 0x8f8072, legs: 0x3d3630, boots: 0x4a4038, gloves: 0x6a5a4a, accent: AMBER, belt: 0x3a2e24 },
    roughness: 0.9,
    metalness: 0.05,
  });
  const rig = b.rig;
  const rockMat = stdMat(ROCK, { roughness: 0.95, flatShading: true, map: Textures.rock() });
  const crack = basicGlow(AMBER);
  // Pauldrons.
  for (const [bone, side] of [
    [rig.bones.armL, 1],
    [rig.bones.armR, -1],
  ] as const) {
    b.attach(bone, Geo.dodeca(0.18), rockMat, [side * 0.03, 0.03, 0], [0.3, 0.5, 0.2], [1.1, 0.8, 1]);
    b.attach(bone, Geo.dodeca(0.1), rockMat, [side * 0.1, -0.06, 0.05], [0.5, 0.2, 0.1]);
  }
  // Boulder gauntlets.
  for (const fore of [rig.bones.foreL, rig.bones.foreR]) {
    b.attach(fore, Geo.dodeca(0.16), rockMat, [0, -0.3, 0], [0.4, 0.3, 0.2], [1, 1.1, 1]);
    b.attach(fore, Geo.torus(0.12, 0.02, 6, 12), crack, [0, -0.18, 0], [Math.PI / 2, 0, 0]);
  }
  for (const hand of [rig.bones.handL, rig.bones.handR]) b.attach(hand, Geo.dodeca(0.15), rockMat, [0, -0.1, 0.02], [0.2, 0.7, 0]);
  // Glowing amber fissures across the chest.
  b.attach(rig.bones.chest, Geo.box(0.26, 0.022, 0.02), crack, [0.03, 0.3, 0.29], [0.3, 0, 0.5]);
  b.attach(rig.bones.chest, Geo.box(0.18, 0.02, 0.02), crack, [-0.1, 0.2, 0.28], [0.3, 0, -0.7]);
  b.attach(rig.bones.chest, Geo.box(0.14, 0.02, 0.02), crack, [0.12, 0.12, 0.27], [0.3, 0, -0.3]);
  // Chest plate & spine ridge.
  b.attach(rig.bones.chest, Geo.box(0.46, 0.3, 0.1), stdMat(0x4a4038, { roughness: 0.85, flatShading: true }), [0, 0.34, 0.24], [0.15, 0, 0]);
  for (let i = 0; i < 4; i++) b.attach(rig.bones.chest, Geo.cone(0.07, 0.2, 5), rockMat, [0, 0.12 + i * 0.13, -0.3], [-0.9, 0, 0]);
  // Heavy brow + tusks.
  b.attach(rig.bones.head, Geo.box(0.22, 0.05, 0.08), rockMat, [0, 0.14, 0.09], [0.2, 0, 0]);
  b.eyes(AMBER, 0.022, 0.045, 0.0, 'slit');
  b.attach(rig.bones.head, Geo.box(0.16, 0.06, 0.1), stdMat(0x7a6c5e, { roughness: 0.9 }), [0, 0.03, 0.08]);
  // Belt with stone buckle.
  b.attach(rig.bones.hips, Geo.dodeca(0.08), crack, [0, 0.07, 0.3]);

  // Iron Skin armour (hidden until activated).
  const armor = new THREE.Group();
  armor.name = 'rockArmor';
  const armorMat = stdMat(0x5a5048, { roughness: 1, flatShading: true, map: Textures.rock(), emissive: 0x201008 });
  const add = (bone: THREE.Object3D, pos: [number, number, number], s: number) => {
    const m = new THREE.Mesh(Geo.dodeca(s), armorMat);
    m.position.set(...pos);
    m.rotation.set(rand(0, 3), rand(0, 3), rand(0, 3));
    m.castShadow = true;
    const holder = new THREE.Group();
    holder.add(m);
    bone.add(holder);
    armor.userData.parts = [...(armor.userData.parts ?? []), holder];
  };
  for (let i = 0; i < 7; i++) add(rig.bones.chest, [rand(-0.3, 0.3), rand(0.05, 0.55), i % 2 ? 0.28 : -0.28], rand(0.1, 0.16));
  for (const [bone, x] of [
    [rig.bones.armL, 0.06],
    [rig.bones.armR, -0.06],
    [rig.bones.foreL, 0.05],
    [rig.bones.foreR, -0.05],
    [rig.bones.legL, 0.07],
    [rig.bones.legR, -0.07],
    [rig.bones.shinL, 0.05],
    [rig.bones.shinR, -0.05],
  ] as const) {
    add(bone, [x, -0.12, 0.06], 0.1);
    add(bone, [x * 0.5, -0.24, -0.05], 0.09);
  }
  add(rig.bones.head, [0, 0.24, -0.02], 0.1);
  rig.extras.rockArmor = armor;
  rig.materials.push(armorMat);
  for (const h of armor.userData.parts as THREE.Object3D[]) h.visible = false;
  return rig;
}

// ============================================================ animations ==
const T: PoseSpec = {
  pos: [0, -0.05, 0],
  chest: [0.28, 0, 0],
  spine: [0.05, 0, 0],
  head: [-0.25, 0, 0],
  armL: [-0.2, 0, 0.38],
  foreL: [-0.55, 0, 0],
  armR: [-0.2, 0, -0.38],
  foreR: [-0.55, 0, 0],
  legL: [-0.12, 0, 0.14],
  shinL: [0.22, 0, 0],
  legR: [-0.12, 0, -0.14],
  shinR: [0.22, 0, 0],
};

const animations: AnimationSet = {
  idle: idleClip({ base: T, breathe: 0.09, crouch: 0, speed: 0.5 }),
  walk: gaitClip(1.3, { stride: 0.42, knee: 0.45, armSwing: 0.32, elbow: -0.5, armOut: 0.38, bounce: 0.02, crouch: 0.06, lean: 0.28, sway: 0.13, twist: 0.2, headStabilize: 0.5, stomp: 0.06 }),
  run: gaitClip(0.85, { stride: 0.72, knee: 1.0, armSwing: 0.7, elbow: -0.7, armOut: 0.32, bounce: 0.06, crouch: 0.1, lean: 0.42, sway: 0.1, twist: 0.3, headStabilize: 0.6, stomp: 0.12 }),
  jump: clip(0.5, [
    { t: 0, p: combine(T, { pos: [0, -0.3, 0], chest: [0.3, 0, 0], legL: [-0.8, 0, 0.1], shinL: [1.4, 0, 0], legR: [-0.8, 0, -0.1], shinR: [1.4, 0, 0] }) },
    { t: 0.5, p: { armL: [-2.2, 0, 0.6], armR: [-2.2, 0, -0.6], foreL: [-0.6, 0, 0], foreR: [-0.6, 0, 0], legL: [-0.6, 0, 0.1], shinL: [0.9, 0, 0], legR: [-0.3, 0, -0.1], shinR: [0.9, 0, 0], chest: [0.1, 0, 0] }, e: 'out' },
    { t: 1, p: { armL: [-1.8, 0, 0.7], armR: [-1.8, 0, -0.7], foreL: [-0.6, 0, 0], foreR: [-0.6, 0, 0], legL: [-0.5, 0, 0.1], shinL: [0.9, 0, 0], legR: [-0.2, 0, -0.1], shinR: [0.8, 0, 0] } },
  ]),
  fall: clip(1, [
    { t: 0, p: { armL: [-1.0, 0, 0.9], armR: [-1.0, 0, -0.9], foreL: [-0.5, 0, 0], foreR: [-0.5, 0, 0], legL: [-0.4, 0, 0.15], shinL: [0.6, 0, 0], legR: [-0.1, 0, -0.15], shinR: [0.5, 0, 0] } },
    { t: 0.5, p: { armL: [-1.1, 0, 1.0], armR: [-0.9, 0, -0.95], foreL: [-0.5, 0, 0], foreR: [-0.5, 0, 0], legL: [-0.3, 0, 0.15], shinL: [0.5, 0, 0], legR: [-0.2, 0, -0.15], shinR: [0.6, 0, 0] } },
  ], true),
  land: clip(0.5, [
    { t: 0, p: { pos: [0, -0.4, 0], chest: [0.7, 0, 0], head: [-0.5, 0, 0], armL: [-0.7, 0, 0.35], foreL: [-0.2, 0, 0], armR: [-0.7, 0, -0.35], foreR: [-0.2, 0, 0], legL: [-1.0, 0, 0.25], shinL: [1.5, 0, 0], legR: [-1.0, 0, -0.25], shinR: [1.5, 0, 0] } },
    { t: 1, p: T, e: 'inOut' },
  ]),
  dodge: clip(0.5, [
    { t: 0, p: T },
    { t: 0.3, p: { root: [0.3, 0, 0.3], pos: [0, -0.3, 0], chest: [0.4, 0, 0.2], armL: [-1.2, 0, -0.2], foreL: [-1.6, 0, 0], armR: [-0.4, 0, -0.9], foreR: [-0.6, 0, 0], legL: [-0.9, 0, 0.3], shinL: [1.2, 0, 0], legR: [0.3, 0, -0.4], shinR: [0.6, 0, 0] }, e: 'out' },
    { t: 0.75, p: { root: [0.25, 0, 0.25], pos: [0, -0.28, 0], chest: [0.4, 0, 0.2], armL: [-1.2, 0, -0.2], foreL: [-1.6, 0, 0], armR: [-0.4, 0, -0.9], foreR: [-0.6, 0, 0], legL: [-0.9, 0, 0.3], shinL: [1.2, 0, 0], legR: [0.3, 0, -0.4], shinR: [0.6, 0, 0] } },
    { t: 1, p: T },
  ]),
  hit: clip(0.3, [
    { t: 0, p: T },
    { t: 0.3, p: combine(T, { chest: [-0.15, 0.1, 0], head: [-0.2, 0.1, 0], armL: [0.1, 0, 0.1], armR: [0.1, 0, -0.1] }), e: 'out' },
    { t: 1, p: T },
  ]),
  knockback: clip(1.0, [
    { t: 0, p: combine(T, { chest: [-0.3, 0, 0], head: [-0.4, 0, 0], armL: [-1.4, 0, 0.8], armR: [-1.4, 0, -0.8] }) },
    { t: 0.55, p: { root: [-0.9, 0, 0], chest: [-0.2, 0, 0], armL: [-2.2, 0, 1.0], armR: [-2.2, 0, -1.0], legL: [-0.3, 0, 0.15], legR: [-0.2, 0, -0.15], shinL: [0.3, 0, 0], shinR: [0.3, 0, 0] }, e: 'in' },
    { t: 0.8, p: LYING_BACK, e: 'in' },
    { t: 1, p: LYING_BACK },
  ]),
  getup: clip(1.0, [
    { t: 0, p: LYING_BACK },
    { t: 0.35, p: { root: [-0.9, 0, 0], pos: [0, 0.1, 0], chest: [0.6, 0, 0], armL: [0.6, 0, 0.3], foreL: [-0.3, 0, 0], armR: [0.6, 0, -0.3], foreR: [-0.3, 0, 0], legL: [-1.6, 0, 0.2], shinL: [2.0, 0, 0], legR: [-0.4, 0, -0.1], shinR: [0.6, 0, 0] } },
    { t: 0.65, p: { pos: [0, -0.5, 0], chest: [0.7, 0, 0], armR: [-0.6, 0, -0.3], foreR: [-0.1, 0, 0], armL: [-0.3, 0, 0.3], legL: [-1.4, 0, 0.1], shinL: [2.0, 0, 0], legR: [0.3, 0, -0.1], shinR: [2.2, 0, 0] } },
    { t: 1, p: T },
  ]),
  death: clip(1.8, [
    { t: 0, p: combine(T, { chest: [-0.2, 0, 0], head: [-0.4, 0, 0] }) },
    { t: 0.35, p: { pos: [0, -0.42, 0], chest: [0.3, 0, 0], head: [0.2, 0, 0], armL: [-0.3, 0, 0.5], armR: [-0.3, 0, -0.5], legL: [-1.5, 0, 0.1], shinL: [1.6, 0, 0], legR: [-1.5, 0, -0.1], shinR: [1.6, 0, 0] } },
    { t: 0.5, p: { pos: [0, -0.45, 0], chest: [0.5, 0, 0], head: [0.5, 0, 0], armL: [-0.2, 0, 0.5], armR: [-0.2, 0, -0.5], legL: [-1.55, 0, 0.1], shinL: [1.7, 0, 0], legR: [-1.55, 0, -0.1], shinR: [1.7, 0, 0] } },
    { t: 0.8, p: LYING_FACE, e: 'in' },
    { t: 1, p: LYING_FACE },
  ]),
  // ---- combo --------------------------------------------------------
  hammerHook: clip(0.7, [
    { t: 0, p: T },
    { t: 0.4, p: combine(T, { armR: [0.2, 0, -1.2], foreR: [-1.2, 0, 0], chest: [0.2, -0.7, 0], hips: [0, -0.3, 0], pos: [0, -0.1, 0] }) },
    { t: 0.55, p: combine(T, { armR: [-1.3, 0, -0.4], foreR: [-0.9, 0, 0], chest: [0.35, 0.8, 0], hips: [0, 0.3, 0], pos: [0, -0.1, 0.15], legR: [0.3, 0, -0.14], legL: [-0.6, 0, 0.14], shinL: [0.6, 0, 0] }), e: 'outExpo' },
    { t: 0.75, p: combine(T, { armR: [-1.25, 0, -0.35], foreR: [-0.9, 0, 0], chest: [0.35, 0.75, 0], hips: [0, 0.3, 0], pos: [0, -0.1, 0.15] }) },
    { t: 1, p: T },
  ]),
  backhand: clip(0.72, [
    { t: 0, p: T },
    { t: 0.4, p: combine(T, { armL: [-1.2, 0, -0.9], foreL: [-1.6, 0, 0], chest: [0.2, 0.7, 0], pos: [0, -0.1, 0] }) },
    { t: 0.55, p: combine(T, { armL: [-1.2, 0, 1.3], foreL: [-0.3, 0, 0], chest: [0.3, -0.9, 0], hips: [0, -0.3, 0], pos: [0, -0.1, 0.1] }), e: 'outExpo' },
    { t: 0.75, p: combine(T, { armL: [-1.15, 0, 1.25], foreL: [-0.3, 0, 0], chest: [0.3, -0.85, 0], pos: [0, -0.1, 0.1] }) },
    { t: 1, p: T },
  ]),
  doubleHammer: clip(1.0, [
    { t: 0, p: T },
    { t: 0.4, p: { pos: [0, 0.05, -0.05], chest: [-0.35, 0, 0], head: [-0.3, 0, 0], armL: [-3.0, 0, -0.35], foreL: [-1.0, 0, 0], armR: [-3.0, 0, 0.35], foreR: [-1.0, 0, 0], legL: [-0.2, 0, 0.15], legR: [0.1, 0, -0.15], shinL: [0.2, 0, 0], shinR: [0.2, 0, 0] } },
    { t: 0.52, p: { pos: [0, -0.4, 0.2], chest: [0.9, 0, 0], head: [-0.6, 0, 0], armL: [-1.0, 0, -0.25], foreL: [-0.2, 0, 0], armR: [-1.0, 0, 0.25], foreR: [-0.2, 0, 0], legL: [-1.1, 0, 0.25], shinL: [1.3, 0, 0], legR: [0.2, 0, -0.25], shinR: [1.0, 0, 0] }, e: 'inExpo' },
    { t: 0.75, p: { pos: [0, -0.38, 0.2], chest: [0.85, 0, 0], head: [-0.6, 0, 0], armL: [-1.0, 0, -0.25], foreL: [-0.2, 0, 0], armR: [-1.0, 0, 0.25], foreR: [-0.2, 0, 0], legL: [-1.1, 0, 0.25], shinL: [1.3, 0, 0], legR: [0.2, 0, -0.25], shinR: [1.0, 0, 0] } },
    { t: 1, p: T },
  ]),
  groundPound: clip(0.6, [
    { t: 0, p: { armL: [-2.8, 0, 0.3], armR: [-2.8, 0, -0.3], foreL: [-0.6, 0, 0], foreR: [-0.6, 0, 0], legL: [-1.2, 0, 0.2], shinL: [1.8, 0, 0], legR: [-1.2, 0, -0.2], shinR: [1.8, 0, 0] } },
    { t: 0.45, p: { root: [0.3, 0, 0], armL: [-0.6, 0, 0.2], armR: [-0.6, 0, -0.2], foreL: [-0.2, 0, 0], foreR: [-0.2, 0, 0], legL: [-0.8, 0, 0.3], shinL: [1.3, 0, 0], legR: [-0.8, 0, -0.3], shinR: [1.3, 0, 0], chest: [0.6, 0, 0] }, e: 'inExpo' },
    { t: 1, p: { pos: [0, -0.4, 0], chest: [0.7, 0, 0], armL: [-0.7, 0, 0.3], armR: [-0.7, 0, -0.3], legL: [-1.0, 0, 0.25], shinL: [1.5, 0, 0], legR: [-1.0, 0, -0.25], shinR: [1.5, 0, 0] } },
  ]),
  // ---- abilities ----------------------------------------------------
  earthquake: clip(1.1, [
    { t: 0, p: T },
    { t: 0.4, p: { pos: [0, 0.05, 0], chest: [-0.3, 0.3, 0], head: [-0.3, 0, 0], armR: [-3.0, 0, -0.2], foreR: [-0.4, 0, 0], armL: [-0.4, 0, 0.7], foreL: [-0.8, 0, 0], legL: [-0.3, 0, 0.2], legR: [0.1, 0, -0.2] } },
    { t: 0.5, p: { pos: [0, -0.55, 0.1], chest: [1.0, 0.2, 0], head: [-0.7, 0, 0], armR: [-0.7, 0, -0.1], foreR: [0, 0, 0], armL: [0.3, 0, 0.8], foreL: [-0.5, 0, 0], legL: [-1.5, 0, 0.2], shinL: [2.0, 0, 0], legR: [0.2, 0, -0.2], shinR: [2.3, 0, 0] }, e: 'inExpo' },
    { t: 0.8, p: { pos: [0, -0.53, 0.1], chest: [0.95, 0.2, 0], head: [-0.7, 0, 0], armR: [-0.7, 0, -0.1], foreR: [0, 0, 0], armL: [0.3, 0, 0.8], foreL: [-0.5, 0, 0], legL: [-1.5, 0, 0.2], shinL: [2.0, 0, 0], legR: [0.2, 0, -0.2], shinR: [2.3, 0, 0] } },
    { t: 1, p: T },
  ]),
  rockThrow: clip(1.3, [
    { t: 0, p: T },
    { t: 0.3, p: { pos: [0, -0.5, 0], chest: [1.1, 0, 0], head: [-0.6, 0, 0], armL: [-1.1, 0, 0.25], foreL: [-0.3, 0, 0], armR: [-1.1, 0, -0.25], foreR: [-0.3, 0, 0], legL: [-1.4, 0, 0.35], shinL: [1.8, 0, 0], legR: [-1.4, 0, -0.35], shinR: [1.8, 0, 0] } },
    { t: 0.55, p: { pos: [0, 0.05, 0], chest: [-0.35, 0, 0], head: [-0.3, 0, 0], armL: [-2.9, 0, -0.2], foreL: [-0.9, 0, 0], armR: [-2.9, 0, 0.2], foreR: [-0.9, 0, 0], legL: [-0.2, 0, 0.2], legR: [0.2, 0, -0.2], shinL: [0.2, 0, 0], shinR: [0.2, 0, 0] }, e: 'inOut' },
    { t: 0.66, p: { pos: [0, 0.05, -0.1], chest: [-0.55, 0, 0], head: [-0.4, 0, 0], armL: [-3.3, 0, -0.2], foreL: [-1.3, 0, 0], armR: [-3.3, 0, 0.2], foreR: [-1.3, 0, 0], legL: [-0.3, 0, 0.2], legR: [0.35, 0, -0.2], shinL: [0.2, 0, 0], shinR: [0.4, 0, 0] } },
    { t: 0.74, p: { pos: [0, -0.2, 0.25], chest: [0.7, 0, 0], head: [-0.4, 0, 0], armL: [-1.3, 0, -0.1], foreL: [0, 0, 0], armR: [-1.3, 0, 0.1], foreR: [0, 0, 0], legL: [-0.9, 0, 0.2], shinL: [0.9, 0, 0], legR: [0.6, 0, -0.2], shinR: [0.3, 0, 0] }, e: 'outExpo' },
    { t: 1, p: T },
  ]),
  titanCharge: {
    ...gaitClip(0.55, { stride: 0.9, knee: 1.1, armSwing: 0.2, elbow: -1.2, armOut: 0.2, bounce: 0.08, crouch: 0.18, lean: 0.9, sway: 0.06, twist: 0.15, headStabilize: 0.9, stomp: 0.15 }),
    layer: (t, out) => {
      // Lead with the right shoulder.
      addRot(out, 'chest', 0, 0.5, 0);
      addRot(out, 'armR', -0.8, 0, 0);
    },
  },
  ironSkin: clip(0.7, [
    { t: 0, p: T },
    { t: 0.4, p: { pos: [0, -0.1, 0], chest: [-0.3, 0, 0], head: [-0.7, 0, 0], armL: [-0.3, 0, 1.3], foreL: [-2.2, 0, 0], armR: [-0.3, 0, -1.3], foreR: [-2.2, 0, 0], legL: [-0.2, 0, 0.3], legR: [-0.2, 0, -0.3], shinL: [0.3, 0, 0], shinR: [0.3, 0, 0] }, e: 'outBack' },
    { t: 0.8, p: { pos: [0, -0.1, 0], chest: [-0.25, 0, 0], head: [-0.6, 0, 0], armL: [-0.3, 0, 1.25], foreL: [-2.2, 0, 0], armR: [-0.3, 0, -1.25], foreR: [-2.2, 0, 0], legL: [-0.2, 0, 0.3], legR: [-0.2, 0, -0.3], shinL: [0.3, 0, 0], shinR: [0.3, 0, 0] } },
    { t: 1, p: T },
  ]),
  groundBreaker: clip(1.2, [
    { t: 0, p: T },
    { t: 0.35, p: { pos: [0, 0.1, 0], chest: [-0.5, 0, 0], head: [-0.5, 0, 0], armL: [-3.1, 0, 0.15], foreL: [-0.5, 0, 0], armR: [-3.1, 0, -0.15], foreR: [-0.5, 0, 0], legL: [-0.1, 0, 0.3], legR: [-0.1, 0, -0.3] } },
    { t: 0.46, p: { pos: [0, -0.65, 0.1], chest: [1.2, 0, 0], head: [-0.8, 0, 0], armL: [-0.55, 0, 0.35], foreL: [0, 0, 0], armR: [-0.55, 0, -0.35], foreR: [0, 0, 0], legL: [-1.5, 0, 0.45], shinL: [1.9, 0, 0], legR: [-1.5, 0, -0.45], shinR: [1.9, 0, 0] }, e: 'inExpo' },
    { t: 0.8, p: { pos: [0, -0.62, 0.1], chest: [1.15, 0, 0], head: [-0.8, 0, 0], armL: [-0.55, 0, 0.35], foreL: [0, 0, 0], armR: [-0.55, 0, -0.35], foreR: [0, 0, 0], legL: [-1.5, 0, 0.45], shinL: [1.9, 0, 0], legR: [-1.5, 0, -0.45], shinR: [1.9, 0, 0] } },
    { t: 1, p: T },
  ]),
  colossus: clip(1.6, [
    { t: 0, p: T },
    { t: 0.25, p: { pos: [0, -0.35, 0], chest: [0.8, 0, 0], head: [0.4, 0, 0], armL: [-0.9, 0, -0.4], foreL: [-1.9, 0, 0], armR: [-0.9, 0, 0.4], foreR: [-1.9, 0, 0], legL: [-1.0, 0, 0.3], shinL: [1.4, 0, 0], legR: [-1.0, 0, -0.3], shinR: [1.4, 0, 0] } },
    { t: 0.45, p: { pos: [0, 0.05, 0], chest: [-0.55, 0, 0], head: [-0.8, 0, 0], armL: [-0.9, 0, 1.4], foreL: [-1.4, 0, 0], armR: [-0.9, 0, -1.4], foreR: [-1.4, 0, 0], legL: [-0.1, 0, 0.4], legR: [-0.1, 0, -0.4] }, e: 'outBack' },
    { t: 0.62, p: { pos: [0, 0, 0], chest: [-0.2, 0, 0], head: [-0.3, 0, 0], armL: [-1.4, 0, -0.3], foreL: [-1.8, 0, 0], armR: [-0.9, 0, -0.9], foreR: [-1.5, 0, 0], legL: [-0.1, 0, 0.4], legR: [-0.1, 0, -0.4] } },
    { t: 0.72, p: { pos: [0, 0, 0], chest: [-0.2, 0, 0], head: [-0.3, 0, 0], armL: [-0.9, 0, 1.3], foreL: [-1.5, 0, 0], armR: [-1.4, 0, 0.3], foreR: [-1.8, 0, 0], legL: [-0.1, 0, 0.4], legR: [-0.1, 0, -0.4] } },
    { t: 0.82, p: { pos: [0, 0, 0], chest: [-0.2, 0, 0], head: [-0.3, 0, 0], armL: [-1.4, 0, -0.3], foreL: [-1.8, 0, 0], armR: [-0.9, 0, -0.9], foreR: [-1.5, 0, 0], legL: [-0.1, 0, 0.4], legR: [-0.1, 0, -0.4] } },
    { t: 1, p: T },
  ]),
};

// ================================================================= combo ==
const tr = (socket: 'handL' | 'handR', from: number, to: number) => ({ socket, color: 0xd8b890, from, to, width: 0.8 });

function smallShockwave(a: Actor, w: World, center: THREE.Vector3, radius: number, dmg: number): void {
  const g = center.clone().setY(w.arena.groundHeight(center.x, center.z, center.y + 1));
  EarthFX.impact(w.vfx, g, radius, 6);
  areaDamage(w, a, g, radius, { amount: dmg, element: 'earth', knockback: 6, launch: 4, hitstun: 0.4, stagger: 70, sound: null }, { propDamage: dmg * 3 });
  w.audio.play('stone_heavy', g, { volume: 0.7 });
}

const combo = {
  resetTime: 0.8,
  ground: [
    {
      name: 'Hammer Hook',
      anim: 'hammerHook',
      duration: 0.7,
      hits: [{ time: 0.38, range: 2.9, arc: 140, damage: 1.0, knockback: 8, hitstun: 0.5, stagger: 75, hitstop: 0.08, shake: 0.25, element: 'earth' }],
      lunge: 0.9,
      lungeStart: 0.25,
      lungeEnd: 0.38,
      cancelTime: 0.52,
      swingSound: 'stone_swing',
      superArmor: true,
      trail: [tr('handR', 0.28, 0.45)],
    },
    {
      name: 'Backhand',
      anim: 'backhand',
      duration: 0.72,
      hits: [{ time: 0.38, range: 2.9, arc: 150, damage: 1.1, knockback: 10, hitstun: 0.5, stagger: 80, hitstop: 0.08, shake: 0.25, element: 'earth' }],
      lunge: 0.9,
      lungeStart: 0.25,
      lungeEnd: 0.38,
      cancelTime: 0.52,
      swingSound: 'stone_swing',
      superArmor: true,
      trail: [tr('handL', 0.28, 0.45)],
    },
    {
      name: 'Mountain Smash',
      anim: 'doubleHammer',
      duration: 1.0,
      hits: [{ time: 0.52, range: 3.2, arc: 120, damage: 1.8, knockback: 6, launch: 7, hitstun: 0.7, stagger: 130, hitstop: 0.12, shake: 0.55, element: 'earth' }],
      lunge: 0.8,
      lungeStart: 0.35,
      lungeEnd: 0.52,
      cancelTime: 0.75,
      swingSound: 'heavy_whoosh',
      superArmor: true,
      trail: [tr('handL', 0.38, 0.55), tr('handR', 0.38, 0.55)],
      onHitFrame(ctx) {
        const a = ctx.attacker;
        const p = a.position.clone().addScaledVector(a.forward(), 2.2 * a.effects.mods.scale);
        smallShockwave(a, ctx.world, p, 3.8 * a.effects.mods.scale, a.stats.attackDamage * 0.6);
        ctx.world.camera.addShake(0.3);
      },
    },
  ] as AttackStep[],
  air: {
    name: 'Body Slam',
    anim: 'groundPound',
    duration: 0.6,
    hits: [{ time: 0.28, range: 3.4, arc: 360, damage: 1.5, knockback: 8, launch: 6, hitstun: 0.6, stagger: 120, heightMin: -3, heightMax: 1.5, hitstop: 0.1, shake: 0.5, element: 'earth' }],
    cancelTime: 0.5,
    swingSound: 'heavy_whoosh',
    superArmor: true,
    onStart(ctx) {
      ctx.attacker.velocity.y = -24;
    },
    onHitFrame(ctx) {
      smallShockwave(ctx.attacker, ctx.world, ctx.attacker.position, 4, ctx.attacker.stats.attackDamage * 0.7);
    },
  } as AttackStep,
};

// ============================================================= abilities ==
const earthquake: AbilityDef = {
  id: 'earthquake',
  name: 'Earthquake',
  description: 'Punch the earth so hard a shockwave rolls across the arena, launching every grounded enemy it passes.',
  cooldown: 8,
  damage: 110,
  anim: 'earthquake',
  tags: ['aoe', 'launch'],
  icon: { glyph: 'quake', bg: ['#d8a860', '#3a2410'], fg: '#fff0d0', glow: '#ffb050' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    c.anim('earthquake', { duration: 1.1 });
    c.superArmor(0, 1.1);
    c.at(0.1, () => w.audio.play('heavy_whoosh', a.position, { pitch: 0.6 }));
    c.at(0.55, () => {
      const center = a.position.clone().addScaledVector(a.forward(), 1.2);
      center.y = w.arena.groundHeight(center.x, center.z, a.position.y + 1);
      w.audio.play('quake', center);
      w.camera.addShake(0.85);
      w.camera.kickFov(5);
      EarthFX.impact(w.vfx, center, 3.5, 16);
      EarthFX.shockwaveRing(w.vfx, center, 24, 1.2);
      w.vfx.decal(center, 5, Textures.cracks(), 0x4a3a2c, 9, { opacity: 0.9 });
      const hitSet = new Set<Actor>();
      let r = 0;
      w.addTicker((dt) => {
        const prev = r;
        r += dt * 20;
        for (const t of w.combat.queryRing(a.faction, center, prev - 0.5, r + 0.5, 2.5)) {
          if (hitSet.has(t)) continue;
          hitSet.add(t);
          w.combat.dealDamage(a, t, { amount: c.dmg(), element: 'earth', knockback: 6, launch: 8, hitstun: 0.7, stagger: 110, isAbility: true, origin: center, hitstop: 0.03, heavy: true });
        }
        // Dust and debris along the front.
        const n = Math.ceil(r * 0.8);
        for (let i = 0; i < n; i++) {
          const ang = Math.random() * TAU;
          const p = new THREE.Vector3(center.x + Math.cos(ang) * r, 0, center.z + Math.sin(ang) * r);
          p.y = w.arena.terrainHeight(p.x, p.z);
          if (Math.random() < 0.4) w.vfx.emit('dust', p, 1, { speed: [1, 3], dir: new THREE.Vector3(Math.cos(ang), 0.6, Math.sin(ang)), spread: 0.4, life: [0.6, 1.1], size: [1.2, 2], sizeEnd: 1.8, color: [0x9c8a70, 0xb0a088], alpha: 0.5, drag: 1.5 });
        }
        if (Math.random() < 0.5) {
          const ang = Math.random() * TAU;
          const p = new THREE.Vector3(center.x + Math.cos(ang) * r, center.y, center.z + Math.sin(ang) * r);
          EarthFX.spike(w.vfx, p, rand(1.2, 2.4), 0.8);
          w.vfx.spawnDebris(p.clone().setY(w.arena.terrainHeight(p.x, p.z) + 0.2), 2, 0x7d7064, { force: 5, size: 0.25 });
        }
        w.arena.damageInSphere(center, r, 30);
        return r > 24;
      });
    });
    c.end(1.1);
  },
};

const rockThrow: AbilityDef = {
  id: 'rockThrow',
  name: 'Rock Throw',
  description: 'Rip a boulder out of the ground, heave it overhead and hurl it. It shatters on impact, crushing everything nearby.',
  cooldown: 7,
  damage: 150,
  anim: 'rockThrow',
  tags: ['ranged', 'aoe', 'knockdown'],
  icon: { glyph: 'rock', bg: ['#b09070', '#2a1a10'], fg: '#f4e4cc', glow: '#d8b890' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const target = c.findTarget(34, 60);
    c.faceAim(34);
    c.anim('rockThrow', { duration: 1.3 });
    c.superArmor(0, 1.2);
    const rock = EarthFX.rock(0.55);
    rock.userData.noClone = true;
    const front = a.position.clone().addScaledVector(a.forward(), 1.4 * a.scale);
    front.y = w.arena.groundHeight(front.x, front.z, a.position.y + 1);
    c.at(0.25, () => {
      w.audio.play('rock_rip', front);
      EarthFX.impact(w.vfx, front, 1.5, 8);
      w.vfx.decal(front, 1.6, Textures.cracks(), 0x4a3a2c, 6);
      rock.position.copy(front).setY(front.y - 0.4);
      w.scene.add(rock);
    });
    c.during(0.25, 0.85, (dt, local, k) => {
      // Rock follows the midpoint between both fists.
      const mid = a.socketPos('handL').add(a.socketPos('handR')).multiplyScalar(0.5);
      mid.y += 0.35 * a.scale;
      rock.position.lerp(mid, Math.min(1, dt * (k < 0.3 ? 8 : 25)));
      rock.rotation.x += dt * 2;
      if (k < 0.3) w.vfx.emit('dust', rock.position, 1, { speed: [0.5, 1.5], life: 0.8, size: 0.8, sizeEnd: 1.5, color: 0x9c8a70, alpha: 0.5, gravity: 2 });
    });
    c.at(0.87, () => {
      w.scene.remove(rock);
      const from = rock.position.clone();
      const aimPoint = target && target.alive ? target.position.clone().setY(target.position.y + 0.8) : from.clone().addScaledVector(a.forward(), 22).setY(w.arena.groundHeight(from.x, from.z) + 0.5);
      const dist = distXZ(from, aimPoint);
      const T = Math.min(1.2, Math.max(0.35, dist / 26));
      const g = 22;
      const vel = new THREE.Vector3((aimPoint.x - from.x) / T, (aimPoint.y - from.y + 0.5 * g * T * T) / T, (aimPoint.z - from.z) / T);
      w.audio.play('rock_throw', from);
      w.projectiles.spawn({
        owner: a,
        position: from,
        velocity: vel,
        gravity: g,
        radius: 0.85,
        lifetime: 3,
        mesh: rock,
        spin: new THREE.Vector3(5, 3, 1),
        onUpdate(p) {
          if (Math.random() < 0.4) w.vfx.emit('dust', p.position, 1, { speed: 0.3, life: 0.6, size: 0.7, sizeEnd: 1.6, color: 0x9c8a70, alpha: 0.45 });
        },
        onImpact(p, pos) {
          areaDamage(w, a, pos, 4.5, { amount: c.dmg(), element: 'earth', knockback: 11, launch: 7, hitstun: 0.8, stagger: 150, isAbility: true, hitstop: 0.1, shake: 0.6, heavy: true }, { falloff: 0.35, propDamage: 600 });
          EarthFX.impact(w.vfx, pos, 4, 18);
          w.vfx.spawnDebris(pos.clone().setY(pos.y + 0.5), 10, 0x9a8b7a, { force: 9, size: 0.35 });
          w.audio.play('stone_heavy', pos);
          w.audio.play('destroy_stone', pos, { volume: 0.6 });
          w.camera.addShake(0.45, pos);
        },
      });
    });
    c.onEnd(() => {
      if (rock.parent === w.scene && !w.projectiles.list.some((p) => p.opts.mesh === rock)) w.scene.remove(rock);
    });
    c.end(1.3);
  },
};

const titanCharge: AbilityDef = {
  id: 'titanCharge',
  name: 'Titan Charge',
  description: 'Lower your shoulder and stampede forward, bulldozing enemies and props out of your way. Unstoppable while charging.',
  cooldown: 9,
  damage: 90,
  anim: 'titanCharge',
  tags: ['mobility', 'knockback', 'unstoppable'],
  icon: { glyph: 'charge', bg: ['#c89060', '#301808'], fg: '#fff0dc', glow: '#ffa040' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const dir = c.faceAim(20);
    const hitSet = new Set<Actor>();
    let stopped = false;
    c.anim('titanCharge', { speed: 1 });
    c.superArmor(0, 1.5);
    c.at(0, () => {
      w.audio.play('roar', a.position, { pitch: 1.3, volume: 0.5 });
      w.camera.kickFov(8);
    });
    let stepT = 0;
    c.during(0.05, 1.25, (dt, local) => {
      if (stopped) return;
      const speed = 19;
      a.velocity.set(dir.x * speed, a.velocity.y, dir.z * speed);
      stepT += dt;
      if (stepT > 0.27) {
        stepT = 0;
        w.audio.play('giant_step', a.position, { volume: 0.6 });
        w.camera.addShake(0.12);
        EarthFX.dust(w.vfx, a.position, 1, 5);
      }
      for (const t of w.combat.queryArc(a, 2.3 * a.effects.mods.scale, 150)) {
        if (hitSet.has(t)) continue;
        hitSet.add(t);
        const side = new THREE.Vector3(-dir.z, 0, dir.x);
        if (side.dot(t.position.clone().sub(a.position)) < 0) side.negate();
        w.combat.dealDamage(a, t, { amount: c.dmg(), element: 'earth', knockback: 20, launch: 7, hitstun: 0.7, stagger: 160, isAbility: true, dir: side.multiplyScalar(0.8).add(dir).normalize(), hitstop: 0.07, shake: 0.35, heavy: true });
      }
      w.arena.damageInSphere(a.position.clone().setY(a.position.y + 1).addScaledVector(dir, 1.5), 2.2 * a.scale, 2000, dir);
      if (a.hitWall && local > 0.12) {
        stopped = true;
        c.stop();
        w.camera.addShake(0.6);
        w.audio.play('stone_heavy', a.position);
        EarthFX.impact(w.vfx, a.position.clone().addScaledVector(dir, 1.2), 2, 10);
        c.anim('hit', { duration: 0.4 });
        c.end(local + 0.5);
      }
    });
    c.at(1.25, () => {
      c.stop();
      c.anim('land', { duration: 0.4 });
    });
    c.end(1.6);
  },
};

const IRON_MOOD_COLOR = new THREE.Color(0x595a5e);

const ironSkin: AbilityDef = {
  id: 'ironSkin',
  name: 'Iron Skin',
  description: 'Harden into living rock for 6s: take 70% less damage and become immune to stagger and knockback.',
  cooldown: 16,
  damage: 0,
  anim: 'ironSkin',
  tags: ['defense', 'buff'],
  icon: { glyph: 'shield', bg: ['#a0a4aa', '#20242a'], fg: '#ffffff', glow: '#d0d4dc' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    c.anim('ironSkin', { duration: 0.7 });
    c.superArmor(0, 0.7);
    c.at(0.25, () => {
      w.audio.play('iron_skin', a.position);
      w.audio.play('roar', a.position, { pitch: 1.1, volume: 0.4 });
      EarthFX.dust(w.vfx, a.position, 2, 14);
      w.vfx.ring(a.position, 0xc0c4cc, 4, 0.5, { blend: THREE.NormalBlending, opacity: 0.7 });
      w.camera.addShake(0.25);
      const armor = a.rig.extras.rockArmor;
      const parts = (armor?.userData.parts ?? []) as THREE.Object3D[];
      a.effects.apply({
        id: 'ironSkin',
        duration: 6,
        icon: 'armor',
        mods: { damageTaken: 0.3, knockbackTaken: 0, poise: 999, moveSpeed: 0.9 },
        flags: { superArmor: true },
        onApply(t) {
          parts.forEach((p) => {
            p.visible = true;
            p.scale.setScalar(0.01);
          });
          for (const m of t.rig.materials) {
            m.userData.baseColor = m.userData.baseColor ?? m.color.clone();
            m.color.copy(m.userData.baseColor).lerp(IRON_MOOD_COLOR, 0.55);
          }
        },
        onUpdate(t, e, dt) {
          const k = Math.min(1, (6 - e.remaining) / 0.3);
          parts.forEach((p) => p.scale.setScalar(Math.max(0.01, k)));
          if (Math.random() < dt * 6) w.vfx.emit('dust', t.position.clone().setY(t.position.y + rand(0.5, 2.5)), 1, { speed: [0.2, 0.6], life: 0.8, size: 0.6, sizeEnd: 1.5, color: 0xa0a4aa, alpha: 0.4, gravity: 1, jitter: 0.8 });
        },
        onExpire(t) {
          parts.forEach((p) => (p.visible = false));
          for (const m of t.rig.materials) if (m.userData.baseColor) m.color.copy(m.userData.baseColor);
          w.vfx.spawnDebris(t.center(), 8, 0x5a5048, { force: 4, size: 0.2 });
          w.audio.play('destroy_stone', t.position, { volume: 0.4 });
        },
      }, w);
    });
    c.end(0.65);
  },
};

const groundBreaker: AbilityDef = {
  id: 'groundBreaker',
  name: 'Ground Breaker',
  description: 'Hammer both fists into the ground, tearing five fissures forward that erupt in stone spikes and launch enemies skyward.',
  cooldown: 12,
  damage: 160,
  anim: 'groundBreaker',
  tags: ['aoe', 'launch'],
  icon: { glyph: 'cracks', bg: ['#e0a060', '#2a1406'], fg: '#fff2dc', glow: '#ffa040' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const aim = c.faceAim(16);
    c.anim('groundBreaker', { duration: 1.2 });
    c.superArmor(0, 1.2);
    c.at(0.1, () => w.audio.play('heavy_whoosh', a.position, { pitch: 0.5 }));
    c.at(0.56, () => {
      const origin = a.position.clone().addScaledVector(aim, 1.5);
      origin.y = w.arena.groundHeight(origin.x, origin.z, a.position.y + 1);
      w.audio.play('quake', origin, { pitch: 1.3 });
      w.audio.play('stone_heavy', origin);
      w.camera.addShake(0.9);
      EarthFX.impact(w.vfx, origin, 3, 14);
      w.vfx.decal(origin, 3.5, Textures.cracks(), 0x4a3a2c, 8, { opacity: 0.95 });
      const hitSet = new Set<Actor>();
      const baseYaw = yawFromDir(aim.x, aim.z);
      for (let k = 0; k < 5; k++) {
        const yaw = baseYaw + (k - 2) * 0.3;
        const dir = new THREE.Vector3(Math.sin(yaw), 0, Math.cos(yaw));
        let dist = 0;
        let timer = 0;
        w.addTicker((dt) => {
          timer -= dt;
          if (timer > 0) return false;
          timer = 0.055;
          dist += 1.6;
          const p = origin.clone().addScaledVector(dir, dist);
          p.y = w.arena.groundHeight(p.x, p.z, origin.y + 2);
          EarthFX.spike(w.vfx, p, rand(1.8, 3.2), 1.3, 0.25);
          w.vfx.decal(p, 1.3, Textures.cracks(), 0x4a3a2c, 7, { opacity: 0.9 });
          w.vfx.emit('dust', p, 3, { speed: [1, 3], life: [0.6, 1], size: [1, 1.6], sizeEnd: 1.8, color: [0x9c8a70, 0xb0a088], alpha: 0.5, drag: 2 });
          w.vfx.spawnDebris(p.clone().setY(p.y + 0.3), 2, 0x7d7064, { force: 4, size: 0.22, up: 8 });
          for (const t of w.combat.queryRadius(a.faction, p, 2.0, 3)) {
            if (hitSet.has(t)) continue;
            hitSet.add(t);
            w.combat.dealDamage(a, t, { amount: c.dmg(), element: 'earth', knockback: 2, launch: 14, hitstun: 1.0, stagger: 180, isAbility: true, dir, hitstop: 0.05, heavy: true });
          }
          w.arena.damageInSphere(p, 2, 500, dir);
          if (k === 2 && Math.random() < 0.5) w.audio.play('stone_hit', p, { volume: 0.5 });
          return dist >= 14;
        });
      }
    });
    c.end(1.2);
  },
};

const colossus: AbilityDef = {
  id: 'colossus',
  name: 'Colossus',
  description: 'ULTIMATE — Swell into a mountain-sized giant for 12s: +120% size and reach, +60% damage, 50% damage reduction. Every step shakes the arena and anything in your path is flattened.',
  cooldown: 0,
  damage: 0,
  ultimate: true,
  anim: 'colossus',
  tags: ['ultimate', 'transform'],
  icon: { glyph: 'giant', bg: ['#ffd080', '#3a1e08'], fg: '#ffffff', glow: '#ffb050' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    c.uninterruptible = true;
    c.invulnerable(0, 1.6);
    c.anim('colossus', { duration: 1.6 });
    const center = a.position.clone();
    c.at(0, () => {
      w.ui.announce('COLOSSUS', undefined, '#ffc070');
      w.audio.play('charge_up', a.position, { pitch: 0.5 });
      const yaw0 = a.facing;
      w.camera.playCinematic({
        duration: 1.5,
        sample(t, pos, look) {
          const ang = yaw0 + 0.5 - t * 0.35;
          const d = 9 + t * 5;
          pos.set(center.x + Math.sin(ang) * d, center.y + 0.6, center.z + Math.cos(ang) * d);
          look.set(center.x, center.y + 2.5 + t * 2.5, center.z);
        },
      });
    });
    c.at(0.55, () => {
      w.audio.play('roar', a.position, { pitch: 0.7 });
      w.audio.play('quake', a.position, { volume: 0.8 });
      w.camera.addShake(0.9);
      w.lighting.flash(0.5, 0xffd090);
      w.lighting.push('colossus', { sunColor: new THREE.Color(0xffc080), hemiGround: new THREE.Color(0x6a4a2a), fogColor: new THREE.Color(0xb89878), exposure: 1.08 }, 12.5, 0.8, 1.5);
      EarthFX.shockwaveRing(w.vfx, a.position, 16, 0.9);
      EarthFX.impact(w.vfx, a.position, 5, 20);
      for (let i = 0; i < 10; i++) {
        const ang = (i / 10) * TAU;
        EarthFX.spike(w.vfx, a.position.clone().add(new THREE.Vector3(Math.cos(ang) * 5, 0, Math.sin(ang) * 5)), rand(2, 3.5), 1.4, 0.4);
      }
      areaDamage(w, a, a.position, 8, { amount: c.dmg(120), element: 'earth', knockback: 16, launch: 8, hitstun: 0.8, stagger: 300, isAbility: true, heavy: true }, { propDamage: 2000 });
      a.effects.apply({
        id: 'colossus',
        duration: 12,
        icon: 'giant',
        mods: { scale: 2.2, damage: 1.6, damageTaken: 0.5, moveSpeed: 1.3, attackSpeed: 0.95, poise: 999, knockbackTaken: 0 },
        flags: { superArmor: true },
        onUpdate(t, e, dt) {
          w.arena.damageInSphere(t.position.clone().setY(t.position.y + 1.5), 1.8 * t.scale * 0.6, 5000, t.forward());
          if (Math.random() < dt * 4) w.vfx.emit('dust', t.position.clone().setY(t.position.y + rand(1, 5)), 1, { speed: [0.2, 0.8], life: 1, size: 1, sizeEnd: 2, color: 0xa09080, alpha: 0.35, gravity: 1, jitter: 1.5 });
        },
        onExpire(t) {
          EarthFX.dust(w.vfx, t.position, 3, 20);
          w.audio.play('destroy_stone', t.position, { volume: 0.6 });
          w.lighting.release('colossus');
        },
      }, w);
    });
    c.end(1.6);
  },
};

// ================================================================ define ==
export const Titan: CharacterDefinition = {
  id: 'titan',
  name: 'Titan',
  title: 'The Walking Mountain',
  role: 'Juggernaut',
  description: 'An ancient stone colossus that shrugs off blows that would shatter lesser warriors. Titan is slow, but every swing lands like an avalanche and reshapes the battlefield.',
  playstyle: 'Walk through their attacks. Basic swings have super armor, so trade blows and win. Control crowds with shockwaves, launch them with Ground Breaker and flatten them in Colossus. Commit carefully — you can’t outrun anything.',
  difficulty: 1,
  element: 'earth',
  theme: { primary: '#d8a060', secondary: '#f0e0c8', glow: '#ffb050', dark: '#2a1a0c' },
  stats,
  buildModel,
  animations,
  combo,
  abilities: [earthquake, rockThrow, titanCharge, ironSkin, groundBreaker, colossus],
  passive: {
    name: 'Unstoppable',
    description: 'Titan cannot be staggered by ordinary attacks and all basic attacks have super armor. Landing from a jump releases a shockwave. Every step of Colossus crushes nearby enemies.',
  },
  hooks: {
    onLand(self, fall, world) {
      if (fall > 9) {
        smallShockwave(self, world, self.position, 3 + fall * 0.08, self.stats.attackDamage * 0.5 * Math.min(2, fall / 12));
        world.camera.addShake(0.3);
      }
    },
    onUpdate(self, dt, world) {
      if (!self.effects.has('colossus') || !self.grounded || !self.inLocomotion) return;
      const name = self.anim.current;
      if (name !== 'walk' && name !== 'run') return;
      const phase = (self.anim.time / self.anim.clipDuration(name)) % 1;
      const last = self.userData.stepPhase ?? phase;
      self.userData.stepPhase = phase;
      const crossed = (last < 0.5 && phase >= 0.5) || phase < last;
      if (!crossed) return;
      const foot = self.socketPos(phase >= 0.5 ? 'footL' : 'footR');
      foot.y = world.arena.groundHeight(foot.x, foot.z, self.position.y + 1);
      world.audio.play('giant_step', foot);
      world.camera.addShake(0.3, foot);
      EarthFX.dust(world.vfx, foot, 2.5, 10);
      world.vfx.ring(foot, 0xd8b890, 4.5, 0.4, { blend: THREE.NormalBlending, opacity: 0.6 });
      world.vfx.decal(foot, 1.8, Textures.cracks(), 0x4a3a2c, 5, { opacity: 0.8 });
      areaDamage(world, self, foot, 3.8, { amount: self.stats.attackDamage * 0.5, element: 'earth', knockback: 7, launch: 5, hitstun: 0.5, stagger: 100, sound: null, ultGain: 0 }, { propDamage: 3000 });
    },
  },
  vfx: {
    hit(world, pos, dir, strength, crit) {
      EarthFX.dust(world.vfx, pos, 0.6 * strength, 5);
      world.vfx.spawnDebris(pos, Math.round(2 + strength * 3), 0x7d7064, { force: 5, size: 0.15, dir });
      GenericFX.impact(world.vfx, pos, 0xffd8a0, strength * 1.2);
      world.vfx.ring(pos, 0xf0dcc0, 1.5 * strength + 0.5, 0.2, { vertical: true, opacity: 0.6 });
    },
    dodge(world, actor) {
      EarthFX.dust(world.vfx, actor.position, 1.2, 10);
    },
    land(world, actor, s) {
      EarthFX.dust(world.vfx, actor.position, 1 + s * 1.5, Math.round(6 + s * 10));
      if (s > 0.5) world.vfx.decal(actor.position, 1.5, Textures.cracks(), 0x4a3a2c, 4, { opacity: 0.7 });
    },
    death(world, actor) {
      world.vfx.spawnDebris(actor.center(), 14, 0x6e6254, { force: 5, size: 0.3 });
      EarthFX.dust(world.vfx, actor.position, 2.5, 16);
    },
    aura(world, actor, dt) {
      if (Math.random() < dt * 1.5) world.vfx.emit('spark', actor.socketPos(Math.random() < 0.5 ? 'handL' : 'handR'), 1, { speed: [0.2, 0.8], life: 0.6, size: 0.12, color: 0xffa040, gravity: -0.5 });
    },
  },
  sounds: {
    swing: 'stone_swing',
    heavySwing: 'heavy_whoosh',
    hit: 'stone_hit',
    heavyHit: 'stone_heavy',
    dodge: 'dodge_roll',
    jump: 'land',
    land: 'giant_step',
    hurt: 'hurt',
    death: 'destroy_stone',
    footstep: 'giant_step',
  },
  threat: { mobility: 0.15, range: 0.35, durability: 1.0, stealth: 0, area: 0.9 },
  camera: { distance: 7.6, height: 1.45, shoulder: 0.5, fov: 60 },
  portrait: { glyph: 'giant', bg: ['#d8a060', '#2a1a0c'], fg: '#fff0dc' },
  ratings: { power: 10, speed: 2, defense: 10, range: 5, control: 8 },
};
