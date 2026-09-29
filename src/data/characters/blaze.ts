import * as THREE from 'three';
import type { AbilityDef, AttackStep, CharacterDefinition, CharacterStats } from '../types';
import type { Actor } from '../../entities/Actor';
import type { World } from '../../core/World';
import { RigBuilder, Geo, glowMat, stdMat, basicGlow, Rig } from '../../characters/Rig';
import { AnimationSet, PoseSpec, clip, combine, gaitClip, idleClip } from '../../characters/AnimationClip';
import { FireFX, EarthFX, GenericFX, tornadoMaterial, fireGroundMaterial } from '../../vfx/ElementFX';
import { Effects } from '../../combat/Effects';
import { LYING_BACK, LYING_FACE, areaDamage, enemiesByDistance, steerTo } from './kit';
import { TAU, rand, yawFromDir, distXZ } from '../../core/math';
import { Textures } from '../../vfx/Textures';

// ================================================================= stats ==
const stats: CharacterStats = {
  maxHealth: 900,
  moveSpeed: 10,
  walkSpeed: 3.6,
  acceleration: 16,
  turnSpeed: 13,
  attackDamage: 34,
  defense: 15,
  attackSpeed: 1.15,
  dodgeDistance: 7,
  dodgeDuration: 0.3,
  dodgeCooldown: 0.6,
  dodgeIFrames: 0.24,
  abilityPower: 1.25,
  cooldownMultiplier: 1.0,
  critChance: 0.12,
  critMultiplier: 1.75,
  jumpVelocity: 12,
  airJumps: 0,
  gravityScale: 1,
  poise: 20,
  mass: 1,
  scale: 1,
  ultChargeRate: 1.1,
};

// ================================================================= model ==
function buildModel(): Rig {
  const b = new RigBuilder({
    hipHeight: 0.95,
    torso: 0.62,
    shoulderWidth: 0.25,
    hipWidth: 0.1,
    chestWidth: 0.26,
    chestDepth: 0.17,
    waistWidth: 0.16,
    upperArm: 0.3,
    foreArm: 0.28,
    armRadius: 0.068,
    foreArmRadius: 0.06,
    thighRadius: 0.088,
    shinRadius: 0.072,
    handSize: 0.12,
    footLength: 0.27,
    neck: 0.08,
    headRadius: 0.13,
    colors: { skin: 0xd8966a, torso: 0x2b1b16, arms: 0xd8966a, legs: 0x3b2a24, boots: 0x1c1411, gloves: 0xc0301a, accent: 0xff6a1a, belt: 0x7a4a20 },
  });
  const rig = b.rig;
  b.mats.gloves.emissive.setHex(0x5a1000);
  b.mats.gloves.emissiveIntensity = 1;

  // Flame hair: layered cones swept back.
  const hairInner = glowMat(0xffb030, 1.4);
  const hairOuter = glowMat(0xff5a10, 1.2);
  const head = rig.bones.head;
  const hr = 0.13;
  const hair: THREE.Mesh[] = [];
  const spikes: [number, number, number, number, number][] = [
    // x, z, height, radius, tilt
    [0, 0.04, 0.2, 0.06, -0.35],
    [0.06, 0.0, 0.17, 0.05, -0.55],
    [-0.06, 0.0, 0.17, 0.05, -0.55],
    [0.03, -0.05, 0.22, 0.055, -0.9],
    [-0.03, -0.05, 0.22, 0.055, -0.9],
    [0, -0.08, 0.2, 0.05, -1.2],
    [0.08, -0.06, 0.14, 0.04, -1.0],
    [-0.08, -0.06, 0.14, 0.04, -1.0],
  ];
  spikes.forEach(([x, z, h, r, tilt], i) => {
    const m = b.attach(head, Geo.cone(r, h, 6), i < 3 ? hairInner : hairOuter, [x, hr * 1.72 + h * 0.3, z], [tilt, 0, -x * 3]);
    hair.push(m);
  });
  rig.extras.hair = hair[0];
  rig.root.userData.hair = hair;
  // Scarf.
  const scarfMat = stdMat(0xb8201a, { roughness: 0.8 });
  b.attach(rig.bones.neck, Geo.torus(0.1, 0.035, 6, 14), scarfMat, [0, 0.02, 0], [Math.PI / 2, 0, 0]);
  b.attach(rig.bones.chest, Geo.box(0.08, 0.34, 0.02), scarfMat, [0.07, 0.42, -0.2], [0.35, 0, 0.15]);
  b.attach(rig.bones.chest, Geo.box(0.07, 0.26, 0.02), scarfMat, [-0.02, 0.4, -0.21], [0.5, 0, -0.1]);
  // Chest emblem + vest trim.
  b.attach(rig.bones.chest, Geo.cone(0.05, 0.12, 5), basicGlow(0xff8a2a), [0, 0.24, 0.16], [0.25, 0, 0]);
  b.attach(rig.bones.chest, Geo.box(0.03, 0.36, 0.02), stdMat(0xff6a1a, { emissive: 0x802000, emissiveIntensity: 1 }), [0.08, 0.2, 0.155], [0.2, 0, 0]);
  b.attach(rig.bones.chest, Geo.box(0.03, 0.36, 0.02), stdMat(0xff6a1a, { emissive: 0x802000, emissiveIntensity: 1 }), [-0.08, 0.2, 0.155], [0.2, 0, 0]);
  // Glowing gauntlet rings.
  const ringMat = basicGlow(0xff7a20);
  for (const fore of [rig.bones.foreL, rig.bones.foreR]) {
    b.attach(fore, Geo.torus(0.07, 0.015, 6, 14), ringMat, [0, -0.18, 0], [Math.PI / 2, 0, 0]);
    b.attach(fore, Geo.torus(0.068, 0.012, 6, 14), ringMat, [0, -0.1, 0], [Math.PI / 2, 0, 0]);
  }
  // Shoulder pad.
  b.attach(rig.bones.armL, Geo.sphere(0.11, 10, 8), stdMat(0x3a2a22, { metalness: 0.5, roughness: 0.4 }), [0.02, 0.02, 0], [0, 0, 0], [1, 0.7, 1]);
  // Belt buckle.
  b.attach(rig.bones.hips, Geo.box(0.08, 0.06, 0.02), basicGlow(0xffa030), [0, 0.07, 0.17]);
  b.eyes(0xffc050, 0.024, 0.05, 0.02, 'slit');
  return rig;
}

// ============================================================ animations ==
const G: PoseSpec = {
  root: [0.05, 0, 0],
  pos: [0, -0.06, 0],
  hips: [0, 0.25, 0],
  chest: [0.12, -0.3, 0],
  head: [0.05, 0.1, 0],
  armL: [-0.55, 0, 0.3],
  foreL: [-2.1, 0, 0],
  armR: [-0.35, 0, -0.35],
  foreR: [-2.25, 0, 0],
  legL: [-0.35, 0, 0.06],
  shinL: [0.4, 0, 0],
  legR: [0.2, 0, -0.08],
  shinR: [0.35, 0, 0],
  footL: [0, 0, 0],
};

const animations: AnimationSet = {
  idle: idleClip({ base: G, breathe: 0.05, crouch: 0.0, speed: 1.4, bob: 0.035, bobSpeed: 2 }),
  walk: gaitClip(0.95, { stride: 0.45, knee: 0.6, armSwing: 0.12, elbow: -1.9, armOut: 0.28, armFwd: 0.45, bounce: 0.03, crouch: 0.06, lean: 0.12, sway: 0.05, twist: 0.12, headStabilize: 0.8 }),
  run: gaitClip(0.6, { stride: 0.95, knee: 1.5, armSwing: 0.85, elbow: -1.5, armOut: 0.12, bounce: 0.08, crouch: 0.08, lean: 0.38, sway: 0.04, twist: 0.35, headStabilize: 0.8 }),
  jump: clip(0.4, [
    { t: 0, p: combine(G, { pos: [0, -0.15, 0] }) },
    { t: 0.4, p: { armL: [-0.9, 0, 0.5], foreL: [-1.6, 0, 0], armR: [-0.7, 0, -0.5], foreR: [-1.8, 0, 0], legL: [-1.1, 0, 0], shinL: [1.6, 0, 0], legR: [-0.3, 0, 0], shinR: [1.0, 0, 0], chest: [0.1, 0, 0] }, e: 'out' },
  ]),
  fall: clip(0.8, [
    { t: 0, p: { armL: [-0.5, 0, 0.8], foreL: [-0.7, 0, 0], armR: [-0.4, 0, -0.9], foreR: [-0.6, 0, 0], legL: [-0.4, 0, 0.1], shinL: [0.6, 0, 0], legR: [0.1, 0, -0.1], shinR: [0.4, 0, 0], chest: [-0.05, 0, 0] } },
    { t: 0.5, p: { armL: [-0.6, 0, 0.95], foreL: [-0.8, 0, 0], armR: [-0.3, 0, -0.8], foreR: [-0.5, 0, 0], legL: [-0.2, 0, 0.1], shinL: [0.4, 0, 0], legR: [-0.1, 0, -0.1], shinR: [0.6, 0, 0], chest: [0, 0, 0] } },
  ], true),
  land: clip(0.28, [
    { t: 0, p: { pos: [0, -0.32, 0], chest: [0.45, 0, 0], legL: [-0.9, 0, 0.1], shinL: [1.4, 0, 0], legR: [-0.6, 0, -0.1], shinR: [1.3, 0, 0], armL: [-0.3, 0, 0.6], armR: [-0.3, 0, -0.6], foreL: [-0.8, 0, 0], foreR: [-0.8, 0, 0] } },
    { t: 1, p: G, e: 'out' },
  ]),
  dodge: clip(0.38, [
    { t: 0, p: G },
    { t: 0.18, p: { root: [0.5, 0, 0], pos: [0, -0.28, 0], chest: [0.2, 0, 0], legL: [-1.2, 0, 0], shinL: [1.3, 0, 0], legR: [0.8, 0, 0], shinR: [0.7, 0, 0], armL: [0.9, 0, 0.25], foreL: [-0.4, 0, 0], armR: [0.9, 0, -0.25], foreR: [-0.4, 0, 0] }, e: 'out' },
    { t: 0.8, p: { root: [0.45, 0, 0], pos: [0, -0.25, 0], chest: [0.2, 0, 0], legL: [-1.0, 0, 0], shinL: [1.1, 0, 0], legR: [0.7, 0, 0], shinR: [0.8, 0, 0], armL: [0.8, 0, 0.3], foreL: [-0.4, 0, 0], armR: [0.8, 0, -0.3], foreR: [-0.4, 0, 0] } },
    { t: 1, p: G },
  ]),
  dodgeBack: clip(0.38, [
    { t: 0, p: G },
    { t: 0.3, p: { root: [-0.35, 0, 0], pos: [0, 0.1, 0], armL: [-0.7, 0, 0.5], foreL: [-2.0, 0, 0], armR: [-0.6, 0, -0.5], foreR: [-2.1, 0, 0], legL: [-0.9, 0, 0], shinL: [1.3, 0, 0], legR: [-0.5, 0, 0], shinR: [1.4, 0, 0] } },
    { t: 1, p: G },
  ]),
  hit: clip(0.32, [
    { t: 0, p: G },
    { t: 0.2, p: combine(G, { chest: [-0.5, 0.25, 0], head: [-0.55, 0.2, 0], armL: [0.3, 0, 0.2], armR: [0.3, 0, -0.2], foreL: [1.1, 0, 0], foreR: [1.2, 0, 0], pos: [0, -0.04, 0] }), e: 'out' },
    { t: 1, p: G },
  ]),
  knockback: clip(0.7, [
    { t: 0, p: { chest: [-0.5, 0, 0], head: [-0.4, 0, 0], armL: [-2.4, 0, 0.8], armR: [-2.6, 0, -0.7], legL: [-0.8, 0, 0], shinL: [0.9, 0, 0], legR: [-0.3, 0, 0], shinR: [0.5, 0, 0] } },
    { t: 0.4, p: { root: [-0.9, 0.3, 0], chest: [-0.3, 0, 0], armL: [-2.0, 0, 1.3], armR: [-2.9, 0, -0.9], legL: [-1.2, 0, 0.2], shinL: [1.2, 0, 0], legR: [-0.2, 0, 0], shinR: [0.2, 0, 0] } },
    { t: 0.8, p: LYING_BACK, e: 'out' },
    { t: 1, p: LYING_BACK },
  ]),
  getup: clip(0.6, [
    { t: 0, p: LYING_BACK },
    { t: 0.35, p: { root: [-1.2, 0, 0], pos: [0, 0.2, 0], legL: [-2.3, 0, 0], shinL: [2.2, 0, 0], legR: [-2.2, 0, 0], shinR: [2.3, 0, 0], armL: [-2.9, 0, 0.3], armR: [-2.9, 0, -0.3], foreL: [-1.5, 0, 0], foreR: [-1.5, 0, 0] } },
    { t: 0.6, p: { root: [-0.1, 0, 0], pos: [0, 0.35, 0], legL: [-0.4, 0, 0], shinL: [0.6, 0, 0], legR: [-0.2, 0, 0], shinR: [0.4, 0, 0], armL: [-1.5, 0, 0.6], armR: [-1.5, 0, -0.6] }, e: 'out' },
    { t: 0.8, p: combine(G, { pos: [0, -0.25, 0], chest: [0.3, 0, 0] }) },
    { t: 1, p: G },
  ]),
  death: clip(1.3, [
    { t: 0, p: combine(G, { chest: [-0.5, 0, 0], head: [-0.6, 0, 0] }) },
    { t: 0.3, p: { pos: [0, -0.48, 0], legL: [-1.5, 0, 0], shinL: [1.7, 0, 0], legR: [0.25, 0, 0], shinR: [2.3, 0, 0], chest: [0.35, 0, 0], head: [0.4, 0, 0], armL: [0.1, 0, 0.1], armR: [0.1, 0, -0.1], foreL: [-0.3, 0, 0], foreR: [-0.3, 0, 0] } },
    { t: 0.45, p: { pos: [0, -0.5, 0], legL: [-1.5, 0, 0], shinL: [1.7, 0, 0], legR: [0.25, 0, 0], shinR: [2.3, 0, 0], chest: [0.5, 0, 0], head: [0.6, 0, 0], armL: [0.2, 0, 0.1], armR: [0.2, 0, -0.1] } },
    { t: 0.75, p: LYING_FACE, e: 'in' },
    { t: 1, p: LYING_FACE },
  ]),
  // ---- combo --------------------------------------------------------
  jab: clip(0.36, [
    { t: 0, p: G },
    { t: 0.3, p: combine(G, { armL: [-1.1, 0, 0.3], chest: [0.2, -0.1, 0], foreL: [-0.95, 0, 0] }), e: 'out' },
    { t: 0.32, p: combine(G, { armL: [-1.0, 0, -0.25], foreL: [2.05, 0, 0], chest: [0.05, -0.3, 0], pos: [0, 0, 0.12] }), e: 'out' },
    { t: 0.6, p: combine(G, { armL: [-0.95, 0, -0.25], foreL: [2.0, 0, 0], chest: [0.05, -0.3, 0] }) },
    { t: 1, p: G },
  ]),
  cross: clip(0.4, [
    { t: 0, p: G },
    { t: 0.32, p: combine(G, { armR: [-1.25, 0, 0.3], foreR: [2.2, 0, 0], chest: [0.1, 0.75, 0], hips: [0, 0.2, 0], legR: [0.25, 0, 0], shinR: [0.2, 0, 0], pos: [0, 0, 0.15] }), e: 'out' },
    { t: 0.6, p: combine(G, { armR: [-1.2, 0, 0.3], foreR: [2.15, 0, 0], chest: [0.1, 0.7, 0] }) },
    { t: 1, p: G },
  ]),
  hook: clip(0.46, [
    { t: 0, p: G },
    { t: 0.2, p: combine(G, { armL: [0.2, 0, 0.9], foreL: [-0.3, 0, 0], chest: [0.05, 0.35, 0] }) },
    { t: 0.42, p: combine(G, { armL: [-0.95, 0, 0.8], foreL: [-0.15, 0, 0], chest: [0.1, -0.95, 0], hips: [0, -0.3, 0], pos: [0, -0.05, 0.1] }), e: 'out' },
    { t: 0.65, p: combine(G, { armL: [-0.9, 0, 0.75], foreL: [-0.2, 0, 0], chest: [0.1, -0.9, 0] }) },
    { t: 1, p: G },
  ]),
  uppercut: clip(0.62, [
    { t: 0, p: G },
    { t: 0.25, p: combine(G, { pos: [0, -0.22, 0], armR: [0.65, 0, -0.1], foreR: [-1.6, 0, 0], chest: [0.35, 0.35, 0], legL: [-0.5, 0, 0], shinL: [0.8, 0, 0], legR: [0.2, 0, 0], shinR: [0.8, 0, 0] }) },
    { t: 0.42, p: combine(G, { pos: [0, 0.18, 0.1], armR: [-3.1, 0, 0.1], foreR: [0.45, 0, 0], chest: [-0.35, 0.3, 0], head: [-0.35, 0, 0], legL: [0.1, 0, 0], shinL: [0.1, 0, 0], legR: [0.3, 0, 0], shinR: [0.5, 0, 0] }), e: 'out' },
    { t: 0.7, p: combine(G, { pos: [0, 0.1, 0], armR: [-3.0, 0, 0.1], foreR: [0.4, 0, 0], chest: [-0.25, 0.3, 0] }) },
    { t: 1, p: G },
  ]),
  axeKick: clip(0.5, [
    { t: 0, p: { legR: [-0.5, 0, 0], shinR: [1.2, 0, 0], armL: [-0.6, 0, 0.6], armR: [-0.6, 0, -0.6] } },
    { t: 0.35, p: { root: [-0.3, 0, 0], legR: [-2.5, 0, 0], shinR: [0.05, 0, 0], legL: [0.4, 0, 0], shinL: [0.8, 0, 0], armL: [-0.3, 0, 1.2], armR: [-0.3, 0, -1.2] } },
    { t: 0.55, p: { root: [0.35, 0, 0], legR: [-0.3, 0, 0], shinR: [0.2, 0, 0], legL: [0.2, 0, 0], shinL: [0.6, 0, 0], armL: [0.4, 0, 0.8], armR: [0.4, 0, -0.8], chest: [0.4, 0, 0] }, e: 'in' },
    { t: 1, p: { legR: [-0.2, 0, 0], shinR: [0.4, 0, 0], armL: [-0.4, 0, 0.7], armR: [-0.4, 0, -0.7] } },
  ]),
  // ---- abilities ----------------------------------------------------
  flameDash: clip(0.5, [
    { t: 0, p: combine(G, { pos: [0, -0.2, 0] }) },
    { t: 0.15, p: { root: [0.6, 0, 0], pos: [0, 0.1, 0], chest: [0.1, 0, 0], armL: [-1.7, 0, 0.1], foreL: [-0.1, 0, 0], armR: [1.0, 0, -0.25], foreR: [-0.4, 0, 0], legL: [-0.9, 0, 0], shinL: [1.5, 0, 0], legR: [0.7, 0, 0], shinR: [0.9, 0, 0], head: [-0.4, 0, 0] }, e: 'out' },
    { t: 0.75, p: { root: [0.55, 0, 0], pos: [0, 0.1, 0], chest: [0.1, 0, 0], armL: [-1.6, 0, 0.1], foreL: [-0.1, 0, 0], armR: [1.0, 0, -0.3], foreR: [-0.4, 0, 0], legL: [-0.8, 0, 0], shinL: [1.4, 0, 0], legR: [0.75, 0, 0], shinR: [1.0, 0, 0], head: [-0.4, 0, 0] } },
    { t: 1, p: combine(G, { pos: [0, -0.15, 0] }) },
  ]),
  infernoPunch: clip(0.85, [
    { t: 0, p: G },
    { t: 0.45, p: { pos: [0, -0.2, -0.05], hips: [0, -0.4, 0], chest: [0.1, -0.9, 0], armR: [0.7, 0, -0.6], foreR: [-1.9, 0, 0], armL: [-1.2, 0, 0.4], foreL: [-1.2, 0, 0], legL: [-0.6, 0, 0.2], shinL: [0.8, 0, 0], legR: [0.5, 0, -0.1], shinR: [0.6, 0, 0], head: [0.1, 0.5, 0] } },
    { t: 0.56, p: { pos: [0, -0.12, 0.25], root: [0.2, 0, 0], hips: [0, 0.5, 0], chest: [0.2, 0.9, 0], armR: [-1.62, 0, 0.05], foreR: [0, 0, 0], armL: [0.6, 0, 0.3], foreL: [-1.6, 0, 0], legL: [-0.9, 0, 0], shinL: [0.8, 0, 0], legR: [0.7, 0, 0], shinR: [0.4, 0, 0], head: [0.1, -0.4, 0] }, e: 'outExpo' },
    { t: 0.82, p: { pos: [0, -0.12, 0.25], root: [0.2, 0, 0], hips: [0, 0.5, 0], chest: [0.2, 0.85, 0], armR: [-1.6, 0, 0.05], foreR: [0, 0, 0], armL: [0.6, 0, 0.3], foreL: [-1.6, 0, 0], legL: [-0.9, 0, 0], shinL: [0.8, 0, 0], legR: [0.7, 0, 0], shinR: [0.4, 0, 0], head: [0.1, -0.4, 0] } },
    { t: 1, p: G },
  ]),
  fireballBarrage: clip(1.0, [
    { t: 0, p: G },
    { t: 0.13, p: combine(G, { armR: [-1.55, 0, 0.1], foreR: [0, 0, 0], chest: [0.15, 0.55, 0] }), e: 'outExpo' },
    { t: 0.28, p: combine(G, { armL: [-1.55, 0, -0.1], foreL: [0, 0, 0], chest: [0.15, -0.55, 0] }), e: 'outExpo' },
    { t: 0.43, p: combine(G, { armR: [-1.6, 0, 0.1], foreR: [0, 0, 0], chest: [0.15, 0.55, 0] }), e: 'outExpo' },
    { t: 0.58, p: combine(G, { armL: [-1.6, 0, -0.1], foreL: [0, 0, 0], chest: [0.15, -0.55, 0] }), e: 'outExpo' },
    { t: 0.73, p: combine(G, { armR: [-1.7, 0, 0.1], armL: [-1.7, 0, -0.1], foreR: [0, 0, 0], foreL: [0, 0, 0], chest: [0.2, 0, 0], pos: [0, 0, 0.1] }), e: 'outExpo' },
    { t: 1, p: G },
  ]),
  flameTornado: clip(0.9, [
    { t: 0, p: combine(G, { pos: [0, -0.2, 0] }) },
    { t: 0.22, p: { root: [0, Math.PI, 0], armL: [-0.1, 0, 1.45], armR: [-0.1, 0, -1.45], foreL: [-0.2, 0, 0], foreR: [-0.2, 0, 0], legL: [-0.3, 0, 0.2], legR: [-0.2, 0, -0.2], shinL: [0.4, 0, 0], shinR: [0.4, 0, 0], pos: [0, 0.05, 0] }, e: 'linear' },
    { t: 0.45, p: { root: [0, TAU, 0], armL: [-0.2, 0, 1.4], armR: [-0.2, 0, -1.4], foreL: [-0.2, 0, 0], foreR: [-0.2, 0, 0], legL: [-0.3, 0, 0.2], legR: [-0.2, 0, -0.2], shinL: [0.4, 0, 0], shinR: [0.4, 0, 0], pos: [0, 0.05, 0] }, e: 'linear' },
    { t: 0.7, p: { root: [0.15, TAU, 0], chest: [0.3, 0, 0], armL: [-1.55, 0, -0.15], armR: [-1.55, 0, 0.15], foreL: [0, 0, 0], foreR: [0, 0, 0], legL: [-0.8, 0, 0], shinL: [0.8, 0, 0], legR: [0.5, 0, 0], shinR: [0.4, 0, 0], pos: [0, -0.15, 0.15] }, e: 'outExpo' },
    { t: 1, p: combine(G, { root: [0, TAU, 0] }) },
  ]),
  meteorRise: clip(0.7, [
    { t: 0, p: combine(G, { pos: [0, -0.35, 0], chest: [0.45, 0, 0], legL: [-1.0, 0, 0], shinL: [1.6, 0, 0], legR: [-0.8, 0, 0], shinR: [1.6, 0, 0], armL: [0.8, 0, 0.3], armR: [0.8, 0, -0.3] }) },
    { t: 0.3, p: { pos: [0, 0.1, 0], chest: [-0.2, 0, 0], armL: [-2.9, 0, 0.2], armR: [-2.9, 0, -0.2], foreL: [-0.2, 0, 0], foreR: [-0.2, 0, 0], legL: [0.1, 0, 0], legR: [0.2, 0, 0], shinL: [0.2, 0, 0], shinR: [0.3, 0, 0], head: [-0.4, 0, 0] }, e: 'outExpo' },
    { t: 1, p: { root: [-0.35, 0, 0], armL: [-2.8, 0, -0.4], armR: [-2.8, 0, 0.4], foreL: [-1.2, 0, 0], foreR: [-1.2, 0, 0], legL: [-1.3, 0, 0], shinL: [2.0, 0, 0], legR: [-1.1, 0, 0], shinR: [2.1, 0, 0], head: [-0.2, 0, 0] } },
  ]),
  meteorDive: clip(0.3, [
    { t: 0, p: { root: [-0.35, 0, 0], armL: [-2.8, 0, -0.4], armR: [-2.8, 0, 0.4], foreL: [-1.2, 0, 0], foreR: [-1.2, 0, 0], legL: [-1.3, 0, 0], shinL: [2.0, 0, 0], legR: [-1.1, 0, 0], shinR: [2.1, 0, 0] } },
    { t: 0.5, p: { root: [0.9, 0, 0], armR: [-1.9, 0, 0], foreR: [0, 0, 0], armL: [0.6, 0, 0.5], foreL: [-0.8, 0, 0], legL: [0.5, 0, 0], shinL: [0.8, 0, 0], legR: [0.3, 0, 0], shinR: [1.0, 0, 0], head: [-0.6, 0, 0] }, e: 'out' },
    { t: 1, p: { root: [0.95, 0, 0], armR: [-1.95, 0, 0], foreR: [0, 0, 0], armL: [0.7, 0, 0.5], foreL: [-0.8, 0, 0], legL: [0.55, 0, 0], shinL: [0.9, 0, 0], legR: [0.35, 0, 0], shinR: [1.1, 0, 0], head: [-0.6, 0, 0] } },
  ]),
  meteorImpact: clip(0.6, [
    { t: 0, p: { pos: [0, -0.55, 0], chest: [0.7, 0.2, 0], head: [-0.5, 0, 0], armR: [-0.7, 0, -0.2], foreR: [-0.2, 0, 0], armL: [0.5, 0, 0.9], foreL: [-0.3, 0, 0], legL: [-1.4, 0, 0.1], shinL: [2.0, 0, 0], legR: [0.25, 0, -0.1], shinR: [2.3, 0, 0] } },
    { t: 0.6, p: { pos: [0, -0.52, 0], chest: [0.65, 0.2, 0], head: [-0.5, 0, 0], armR: [-0.7, 0, -0.2], foreR: [-0.2, 0, 0], armL: [0.5, 0, 0.9], foreL: [-0.3, 0, 0], legL: [-1.4, 0, 0.1], shinL: [2.0, 0, 0], legR: [0.25, 0, -0.1], shinR: [2.3, 0, 0] } },
    { t: 1, p: G },
  ]),
  worldBurner: clip(1.9, [
    { t: 0, p: G },
    { t: 0.3, p: { pos: [0, -0.35, 0], chest: [0.55, 0, 0], head: [0.4, 0, 0], armL: [-1.3, 0, -0.55], foreL: [-1.8, 0, 0], armR: [-1.3, 0, 0.55], foreR: [-1.8, 0, 0], legL: [-0.9, 0, 0.25], shinL: [1.4, 0, 0], legR: [-0.9, 0, -0.25], shinR: [1.4, 0, 0] } },
    { t: 0.5, p: { pos: [0, -0.4, 0], chest: [0.65, 0, 0], head: [0.5, 0, 0], armL: [-1.4, 0, -0.6], foreL: [-1.9, 0, 0], armR: [-1.4, 0, 0.6], foreR: [-1.9, 0, 0], legL: [-1.0, 0, 0.25], shinL: [1.5, 0, 0], legR: [-1.0, 0, -0.25], shinR: [1.5, 0, 0] } },
    { t: 0.56, p: { pos: [0, 0.1, 0], chest: [-0.45, 0, 0], head: [-0.6, 0, 0], armL: [-2.3, 0, 1.3], foreL: [0, 0, 0], armR: [-2.3, 0, -1.3], foreR: [0, 0, 0], legL: [0.1, 0, 0.45], shinL: [0.1, 0, 0], legR: [0.1, 0, -0.45], shinR: [0.1, 0, 0] }, e: 'outExpo' },
    { t: 0.85, p: { pos: [0, 0.08, 0], chest: [-0.4, 0, 0], head: [-0.55, 0, 0], armL: [-2.25, 0, 1.3], foreL: [0, 0, 0], armR: [-2.25, 0, -1.3], foreR: [0, 0, 0], legL: [0.1, 0, 0.45], shinL: [0.1, 0, 0], legR: [0.1, 0, -0.45], shinR: [0.1, 0, 0] } },
    { t: 1, p: G },
  ]),
};

// ================================================================= combo ==
const combo = {
  resetTime: 0.55,
  ground: [
    {
      name: 'Jab',
      anim: 'jab',
      duration: 0.36,
      hits: [{ time: 0.12, range: 2.0, arc: 70, damage: 0.8, knockback: 2, hitstun: 0.3, stagger: 30, element: 'fire' }],
      lunge: 0.6,
      lungeStart: 0.02,
      lungeEnd: 0.12,
      cancelTime: 0.2,
      swingSound: 'fire_swing',
      trail: [{ socket: 'handL', color: 0xff7a20, from: 0.06, to: 0.18 }],
    },
    {
      name: 'Cross',
      anim: 'cross',
      duration: 0.4,
      hits: [{ time: 0.14, range: 2.1, arc: 70, damage: 1.0, knockback: 3, hitstun: 0.32, stagger: 35, element: 'fire' }],
      lunge: 0.8,
      lungeStart: 0.03,
      lungeEnd: 0.14,
      cancelTime: 0.22,
      swingSound: 'fire_swing',
      trail: [{ socket: 'handR', color: 0xff7a20, from: 0.06, to: 0.2 }],
    },
    {
      name: 'Hook',
      anim: 'hook',
      duration: 0.46,
      hits: [{ time: 0.19, range: 2.2, arc: 120, damage: 1.2, knockback: 4.5, hitstun: 0.4, stagger: 45, element: 'fire' }],
      lunge: 0.7,
      lungeStart: 0.05,
      lungeEnd: 0.18,
      cancelTime: 0.28,
      swingSound: 'fire_swing',
      trail: [{ socket: 'handL', color: 0xff8a30, from: 0.08, to: 0.24, width: 0.45 }],
    },
    {
      name: 'Rising Flame',
      anim: 'uppercut',
      duration: 0.62,
      hits: [{ time: 0.26, range: 2.3, arc: 90, damage: 1.9, knockback: 5, launch: 11, hitstun: 0.6, stagger: 90, hitstop: 0.09, shake: 0.35, element: 'fire' }],
      lunge: 0.9,
      lungeStart: 0.1,
      lungeEnd: 0.26,
      cancelTime: 0.45,
      swingSound: 'heavy_whoosh',
      trail: [{ socket: 'handR', color: 0xffb040, from: 0.15, to: 0.36, width: 0.6 }],
      onHitFrame(ctx) {
        const p = ctx.attacker.socketPos('handR');
        FireFX.burst(ctx.world.vfx, p, 1.4, new THREE.Vector3(0, 1, 0));
        ctx.world.audio.play('fire_burst', p, { volume: 0.6 });
        if (ctx.attacker.grounded) ctx.attacker.velocity.y = 5;
      },
    },
  ] as AttackStep[],
  air: {
    name: 'Axe Kick',
    anim: 'axeKick',
    duration: 0.5,
    hits: [{ time: 0.26, range: 2.4, arc: 140, damage: 1.4, knockback: 6, launch: -2, hitstun: 0.45, stagger: 60, heightMin: -2.5, heightMax: 2, element: 'fire', shake: 0.25 }],
    cancelTime: 0.4,
    swingSound: 'heavy_whoosh',
    trail: [{ socket: 'footR', color: 0xff7a20, from: 0.1, to: 0.32, width: 0.5 }],
    onHitFrame(ctx) {
      FireFX.burst(ctx.world.vfx, ctx.attacker.socketPos('footR'), 1, new THREE.Vector3(0, -1, 0));
      ctx.attacker.velocity.y = Math.min(ctx.attacker.velocity.y, -6);
    },
  } as AttackStep,
};

// ============================================================= abilities ==
function burningPatch(world: World, owner: Actor, pos: THREE.Vector3, radius: number, duration: number, dps: number) {
  const mesh = FireFX.groundPatch(world.vfx, radius, 0.9);
  const g = new THREE.Group();
  g.add(mesh);
  mesh.position.y = world.arena.groundHeight(pos.x, pos.z, pos.y + 1) - pos.y + 0.07;
  world.zones.spawn({
    owner,
    position: pos,
    radius,
    duration,
    tickInterval: 0.5,
    harmful: true,
    visual: g,
    onTick(z, targets) {
      for (const t of targets) {
        world.combat.dealDamage(owner, t, { amount: dps * 0.5, element: 'fire', isDot: true, sound: null, vfx: false, ultGain: 0.5 });
        t.effects.apply(Effects.burn(owner, 10, 2.5), world);
      }
    },
    onUpdate(z, dt) {
      (mesh.material as THREE.ShaderMaterial).uniforms.uOpacity.value = 0.9 * z.fade;
      if (Math.random() < dt * radius * 5) {
        const p = z.position.clone();
        p.x += rand(-1, 1) * radius * 0.7;
        p.z += rand(-1, 1) * radius * 0.7;
        p.y = world.arena.groundHeight(p.x, p.z, p.y + 1) + 0.1;
        FireFX.trailPuff(world.vfx, p);
      }
    },
    onEnd() {
      world.vfx.release(mesh.material as THREE.Material);
    },
  });
}

const flameDash: AbilityDef = {
  id: 'flameDash',
  name: 'Flame Dash',
  description: 'Blast forward wrapped in fire, scorching everything in your path and leaving a burning trail.',
  cooldown: 5,
  damage: 55,
  anim: 'flameDash',
  castInAir: true,
  tags: ['mobility', 'damage', 'zone'],
  icon: { glyph: 'dash', bg: ['#ff9a3a', '#7a1a05'], fg: '#fff3d0', glow: '#ffb040' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const dir = c.aimDir(true, 14);
    a.facing = yawFromDir(dir.x, dir.z);
    const hitSet = new Set<Actor>();
    let lastPatch = a.position.clone();
    let lastImage = 0;
    const prev = a.position.clone();
    c.anim('flameDash', { duration: 0.5 });
    c.invulnerable(0.04, 0.3);
    c.at(0, () => {
      w.audio.play('fire_whoosh', a.position);
      w.camera.kickFov(9);
      FireFX.burst(w.vfx, a.position.clone().setY(a.position.y + 0.3), 1.2);
      a.noGravity = 0.4;
      a.velocity.y = 0;
    });
    c.during(0.06, 0.34, (dt, local) => {
      prev.copy(a.position);
      const speed = 12 / 0.28;
      a.velocity.set(dir.x * speed, 0, dir.z * speed);
      const top = a.position.clone().setY(a.position.y + 1);
      const hits = w.combat.querySegment(a.faction, prev.clone().setY(prev.y + 1), top, 1.1);
      for (const t of hits) {
        if (hitSet.has(t)) continue;
        hitSet.add(t);
        const side = new THREE.Vector3(-dir.z, 0, dir.x);
        if (side.dot(t.position.clone().sub(a.position)) < 0) side.negate();
        const r = w.combat.dealDamage(a, t, { amount: c.dmg(), element: 'fire', knockback: 9, launch: 4, hitstun: 0.45, stagger: 55, isAbility: true, dir: side.add(dir).normalize(), hitstop: 0.05 });
        if (r) t.effects.apply(Effects.burn(a, 14, 3), w);
      }
      FireFX.trailPuff(w.vfx, a.position.clone().setY(a.position.y + 0.5));
      w.vfx.emit('flame', a.center(), 3, { speed: [1, 3], life: [0.2, 0.4], size: [0.8, 1.3], sizeEnd: 0.3, color: FireFX.colors, colorEnd: 0x901800, jitter: 0.3 });
      if (distXZ(a.position, lastPatch) > 1.8 && a.grounded) {
        lastPatch = a.position.clone();
        burningPatch(w, a, a.position.clone(), 1.4, 3, 20 * a.stats.abilityPower);
      }
      if (local - lastImage > 0.06) {
        lastImage = local;
        w.vfx.afterimage(a, 0xff6a20, 0.3, 0.5);
      }
    });
    c.at(0.34, () => {
      a.velocity.x *= 0.2;
      a.velocity.z *= 0.2;
      burningPatch(w, a, a.position.clone(), 1.4, 3, 20 * a.stats.abilityPower);
    });
    c.end(0.5);
  },
};

const infernoPunch: AbilityDef = {
  id: 'infernoPunch',
  name: 'Inferno Punch',
  description: 'Wind up a flaming haymaker that detonates on contact and sends enemies flying.',
  cooldown: 6,
  damage: 140,
  anim: 'infernoPunch',
  tags: ['burst', 'knockback'],
  icon: { glyph: 'fist', bg: ['#ffcf4a', '#a02008'], fg: '#fff8e0', glow: '#ffdd66' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const target = c.findTarget(9, 80);
    c.faceAim(9);
    let lungeSpeed = 14;
    c.anim('infernoPunch', { duration: 0.85 });
    c.superArmor(0, 0.65);
    c.at(0, () => w.audio.play('charge_up', a.position, { pitch: 1.4, volume: 0.7 }));
    c.during(0, 0.45, (dt, local, k) => {
      const p = a.socketPos('handR');
      w.vfx.emit('flame', p, 2 + k * 4, { speed: [0.5, 2], life: [0.15, 0.35], size: [0.3 + k * 0.6, 0.6 + k * 0.9], sizeEnd: 0.2, color: FireFX.colors, colorEnd: 0x901800, jitter: 0.1 + k * 0.1 });
      w.vfx.emit('glow', p, 1, { speed: 0.1, life: 0.15, size: 0.8 + k * 1.2, sizeEnd: 0.5, color: 0xffa040 });
    });
    c.at(0.43, () => {
      // Step into the punch: close the gap to the target (up to ~6 m).
      if (target?.alive) {
        a.faceTowards(target.position);
        const gap = a.position.distanceTo(target.position) - target.radius - 1.6;
        lungeSpeed = Math.max(4, Math.min(6, gap) / 0.12);
      }
    });
    c.during(0.44, 0.56, () => {
      const f = a.forward();
      a.velocity.set(f.x * lungeSpeed, a.velocity.y, f.z * lungeSpeed);
      if (lungeSpeed > 20) w.vfx.afterimage(a, 0xff6a20, 0.2, 0.3);
    });
    c.at(0.48, () => {
      const f = a.forward();
      const targets = w.combat.queryArc(a, 3.4, 80);
      for (const t of targets) {
        w.combat.dealDamage(a, t, { amount: c.dmg(), element: 'fire', knockback: 28, launch: 7.5, hitstun: 0.8, stagger: 160, hitstop: 0.13, shake: 0.65, isAbility: true, dir: f, heavy: true });
        t.effects.apply(Effects.burn(a, 16, 3), w);
      }
      const p = a.socketPos('handR').addScaledVector(f, 0.8);
      FireFX.explosion(w.vfx, p, 2.3);
      w.vfx.emit('flame', p, 40, { speed: [8, 20], dir: f, spread: 0.25, life: [0.2, 0.45], size: [0.8, 1.6], sizeEnd: 0.3, color: FireFX.colors, colorEnd: 0x7a1000, drag: 3 });
      w.audio.play('fire_heavy_hit', p);
      w.audio.play('explosion', p, { pitch: 1.4, volume: 0.6 });
      w.camera.addShake(0.35);
      w.camera.kickFov(6);
      w.arena.damageInSphere(p, 2.5, 400, f);
    });
    c.at(0.6, () => c.stop());
    c.end(0.85);
  },
};

const fireballBarrage: AbilityDef = {
  id: 'fireballBarrage',
  name: 'Fireball Barrage',
  description: 'Hurl five homing fireballs at nearby enemies. Each explodes on impact.',
  cooldown: 8,
  damage: 48,
  anim: 'fireballBarrage',
  tags: ['ranged', 'aoe'],
  icon: { glyph: 'fireballs', bg: ['#ff7a2a', '#5a0a02'], fg: '#ffe7a0', glow: '#ff8a30' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const aim = c.faceAim(32);
    const targets = enemiesByDistance(w, a, 32, aim, 70).slice(0, 5);
    c.anim('fireballBarrage', { duration: 1.0 });
    c.every(0.15, 0.13, 0.73, (i) => {
      const hand = i % 2 === 0 ? 'handR' : 'handL';
      const from = a.socketPos(hand);
      const target = targets.length ? targets[i % targets.length] : null;
      if (target?.alive) a.faceTowards(target.position, 0.6);
      const dir = target && target.alive ? target.center().sub(from).normalize() : a.forward().setY(0.05).normalize().applyAxisAngle(new THREE.Vector3(0, 1, 0), rand(-0.25, 0.25));
      dir.y += 0.12;
      dir.normalize();
      w.audio.play('fireball', from);
      w.projectiles.spawn({
        owner: a,
        position: from,
        velocity: dir.multiplyScalar(26),
        radius: 0.5,
        lifetime: 2.2,
        homing: target ? 4.2 : 0,
        target,
        mesh: FireFX.fireball(0.42),
        onUpdate(p) {
          FireFX.trailPuff(w.vfx, p.position);
        },
        onImpact(p, pos) {
          areaDamage(w, a, pos, 2.6, { amount: c.dmg(), element: 'fire', knockback: 7, launch: 3.5, hitstun: 0.4, stagger: 45, isAbility: true, hitstop: 0.04 }, { onHit: (t) => t.effects.apply(Effects.burn(a, 12, 3), w) });
          FireFX.explosion(w.vfx, pos, 1.7);
          w.audio.play('explosion', pos, { pitch: 1.35, volume: 0.55 });
          w.camera.addShake(0.12, pos);
        },
      });
    });
    c.end(1.0);
  },
};

const flameTornado: AbilityDef = {
  id: 'flameTornado',
  name: 'Flame Tornado',
  description: 'Spin up a roaring fire tornado that hunts enemies, drags them into its core and burns them.',
  cooldown: 12,
  damage: 18,
  anim: 'flameTornado',
  tags: ['control', 'aoe', 'zone'],
  icon: { glyph: 'tornado', bg: ['#ff6a1a', '#4a0800'], fg: '#ffd890', glow: '#ff7a20' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const aim = c.faceAim(20);
    c.anim('flameTornado', { duration: 0.9 });
    c.during(0, 0.5, () => {
      w.vfx.emit('flame', a.center(), 3, { speed: [3, 6], life: [0.2, 0.4], size: [0.5, 0.9], sizeEnd: 0.2, color: FireFX.colors, ring: 1.2, radial: 3 });
    });
    c.at(0.62, () => {
      const start = a.position.clone().addScaledVector(aim, 6);
      start.y = w.arena.groundHeight(start.x, start.z, a.position.y + 3);
      const group = new THREE.Group();
      const mats: THREE.ShaderMaterial[] = [];
      const layers: THREE.Mesh[] = [];
      for (let i = 0; i < 3; i++) {
        const mat = w.vfx.animate(tornadoMaterial());
        mats.push(mat);
        const geo = new THREE.CylinderGeometry(2.4 + i * 0.7, 0.6 + i * 0.35, 8 + i, 20, 1, true);
        geo.translate(0, (8 + i) / 2, 0);
        const m = new THREE.Mesh(geo, mat);
        m.renderOrder = 5;
        group.add(m);
        layers.push(m);
      }
      w.audio.play('tornado', start);
      w.vfx.flash(start.clone().setY(start.y + 3), 0xff7020, 40, 20, 5);
      w.zones.spawn({
        owner: a,
        position: start,
        radius: 9,
        height: 10,
        duration: 5,
        tickInterval: 0.25,
        harmful: true,
        visual: group,
        onUpdate(z, dt) {
          // Drift toward the nearest enemy.
          const t = w.combat.nearestHostile(a.faction, z.position, 16);
          if (t) {
            const d = t.position.clone().sub(z.position).setY(0);
            if (d.length() > 1) z.position.addScaledVector(d.normalize(), 3.2 * dt);
          } else z.position.addScaledVector(aim, 2 * dt);
          z.position.y = w.arena.groundHeight(z.position.x, z.position.z, z.position.y + 2);
          layers.forEach((m, i) => (m.rotation.y += dt * (4 + i * 1.5)));
          mats.forEach((m) => (m.uniforms.uOpacity.value = z.fade));
          // Pull.
          for (const e of w.combat.hostilesOf(a.faction)) {
            const d = z.position.clone().sub(e.position).setY(0);
            const dist = d.length();
            if (dist > z.radius || dist < 0.4) continue;
            const pull = (1 - dist / z.radius) * 7 + 1.5;
            e.position.addScaledVector(d.normalize(), Math.min(dist, pull * dt) * (e.stats.mass > 2 ? 0.5 : 1));
          }
          // Spiral flames.
          const ang = w.time * 9;
          for (let k = 0; k < 3; k++) {
            const h = Math.random() * 8;
            const r = 0.8 + h * 0.3;
            const p = z.position.clone().add(new THREE.Vector3(Math.cos(ang + k * 2.1) * r, h, Math.sin(ang + k * 2.1) * r));
            w.vfx.emit('flame', p, 1, { speed: 1, velocity: new THREE.Vector3(-Math.sin(ang + k * 2.1) * 6, 3, Math.cos(ang + k * 2.1) * 6), life: [0.3, 0.5], size: [0.8, 1.4], sizeEnd: 0.3, color: FireFX.colors, colorEnd: 0x901800 });
          }
          if (Math.random() < dt * 12) FireFX.embers(w.vfx, z.position.clone().setY(z.position.y + 6), 2, 2);
          if (Math.random() < dt * 3) w.vfx.emit('smoke', z.position.clone().setY(z.position.y + 9), 1, { speed: [1, 2], life: 1.5, size: 2.5, sizeEnd: 2, color: 0x2a2220, alpha: 0.4, gravity: -1 });
          if (Math.random() < dt * 0.5) w.audio.play('tornado', z.position, { volume: 0.6 });
        },
        onTick(z, targets) {
          for (const t of targets) {
            const dist = distXZ(t.position, z.position);
            if (dist > 3.4) continue;
            w.combat.dealDamage(a, t, { amount: c.dmg(), element: 'fire', knockback: 0.5, launch: dist < 2 ? 3 : 0, hitstun: 0.3, stagger: 30, isAbility: true, hitstop: 0, shake: 0.03, dir: new THREE.Vector3(-(t.position.z - z.position.z), 0, t.position.x - z.position.x).normalize() });
            t.effects.apply(Effects.burn(a, 10, 2), w);
          }
        },
        onEnd() {
          mats.forEach((m) => w.vfx.release(m));
          FireFX.burst(w.vfx, start, 1);
        },
      });
    });
    c.end(0.9);
  },
};

const meteorCrash: AbilityDef = {
  id: 'meteorCrash',
  name: 'Meteor Crash',
  description: 'Leap high into the air, then crash down like a meteor, obliterating the landing zone and setting it ablaze.',
  cooldown: 10,
  damage: 170,
  anim: 'meteorRise',
  castInAir: true,
  tags: ['aoe', 'mobility', 'burst'],
  icon: { glyph: 'meteor', bg: ['#ffb04a', '#6a0a00'], fg: '#fff0c0', glow: '#ff9a30' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const t = c.findTarget(18);
    const aim = c.aimDir(true, 18);
    const start = a.position.clone();
    let dest = t ? t.position.clone() : start.clone().addScaledVector(aim, 12);
    if (distXZ(dest, start) > 16) dest = start.clone().addScaledVector(dest.clone().sub(start).setY(0).normalize(), 16);
    dest = w.arena.safePoint(start, dest, 0.6);
    a.facing = yawFromDir(dest.x - start.x, dest.z - start.z) || a.facing;
    const apex = new THREE.Vector3().lerpVectors(start, dest, 0.65);
    apex.y = Math.max(start.y, dest.y) + 9;
    let landed = false;
    c.anim('meteorRise', { duration: 0.7 });
    c.invulnerable(0.15, 1.0);
    c.superArmor(0, 1.45);
    c.at(0.15, () => {
      w.audio.play('fire_whoosh', a.position, { pitch: 0.8 });
      FireFX.burst(w.vfx, start, 1.4);
      w.vfx.ring(start, 0xff7a20, 3, 0.35);
      a.noGravity = 1.2;
    });
    c.during(0.15, 0.62, (dt, local, k) => {
      const e = 1 - Math.pow(1 - k, 2.2);
      const target = start.clone().lerp(apex, e);
      target.y = start.y + (apex.y - start.y) * Math.sin((e * Math.PI) / 2);
      steerTo(a, target, dt);
      FireFX.trailPuff(w.vfx, a.center());
    });
    c.at(0.62, () => {
      c.anim('meteorDive', { duration: 0.3 });
      w.audio.play('meteor_fall', a.position);
      c.stop();
      a.velocity.y = 0;
    });
    c.during(0.62, 0.74, () => {
      a.velocity.set(0, 0, 0);
      w.vfx.emit('flame', a.center(), 6, { speed: [2, 5], life: [0.2, 0.4], size: [0.7, 1.3], sizeEnd: 0.2, color: FireFX.colors, ring: 1.5, radial: -4 });
    });
    c.during(0.74, 0.96, (dt, local, k) => {
      if (landed) return;
      const from = apex;
      const target = from.clone().lerp(dest, Math.min(1, k * k * 1.05));
      steerTo(a, target, dt);
      w.vfx.emit('flame', a.center(), 8, { speed: [1, 4], life: [0.3, 0.5], size: [1, 1.8], sizeEnd: 0.3, color: FireFX.colors, colorEnd: 0x7a1000, jitter: 0.4 });
      w.vfx.afterimage(a, 0xff5a10, 0.25, 0.4);
      if (a.grounded && local > 0.05) impact();
    });
    const impact = () => {
      if (landed) return;
      landed = true;
      a.velocity.set(0, 0, 0);
      a.noGravity = 0;
      c.anim('meteorImpact', { duration: 0.5 });
      const p = a.position.clone();
      areaDamage(w, a, p, 7, { amount: c.dmg(), element: 'fire', knockback: 15, launch: 10, hitstun: 0.8, stagger: 200, isAbility: true, hitstop: 0.14, shake: 0.9, heavy: true }, { falloff: 0.45, onHit: (t) => t.effects.apply(Effects.burn(a, 14, 3), w), propDamage: 700 });
      FireFX.explosion(w.vfx, p.clone().setY(p.y + 0.5), 5);
      EarthFX.impact(w.vfx, p, 4.5, 14);
      burningPatch(w, a, p, 6, 4, 26 * a.stats.abilityPower);
      w.audio.play('explosion', p, { pitch: 0.8 });
      w.audio.play('stone_heavy', p, { volume: 0.6 });
      w.lighting.flash(0.6, 0xff9040);
      w.camera.addShake(0.9);
      w.camera.kickFov(10);
    };
    c.at(0.96, impact);
    c.end(1.45);
  },
};

const worldBurner: AbilityDef = {
  id: 'worldBurner',
  name: 'World Burner',
  description: 'ULTIMATE — Gather every ember of your power and detonate a colossal firestorm. The ground becomes a sea of flames that scorches all enemies inside.',
  cooldown: 0,
  damage: 320,
  ultimate: true,
  anim: 'worldBurner',
  tags: ['ultimate', 'aoe', 'zone'],
  icon: { glyph: 'nova', bg: ['#fff07a', '#b01a00'], fg: '#ffffff', glow: '#ffcc40' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    c.uninterruptible = true;
    c.invulnerable(0, 1.9);
    c.anim('worldBurner', { duration: 1.9 });
    const center = a.position.clone();
    c.at(0, () => {
      w.audio.play('charge_up', a.position, { pitch: 0.6 });
      w.audio.play('roar', a.position, { pitch: 1.6, volume: 0.5 });
      w.lighting.push('worldBurner', { sunColor: new THREE.Color(0xff8040), sunIntensity: 2.2, hemiSky: new THREE.Color(0xff9a60), hemiGround: new THREE.Color(0x5a1a08), fogColor: new THREE.Color(0xb04a20), fogDensity: 0.009, skyTop: new THREE.Color(0x5a1a10), skyBottom: new THREE.Color(0xff6a20), exposure: 1.1 }, 8, 0.6, 1.5);
      w.ui.announce('WORLD BURNER', undefined, '#ffb040');
      const orbit0 = w.camera.yaw;
      w.camera.playCinematic({
        duration: 1.05,
        sample(t, pos, look) {
          const ang = orbit0 + Math.PI + t * 0.9;
          pos.set(center.x + Math.sin(ang) * 7, center.y + 1.2 + t * 2.5, center.z + Math.cos(ang) * 7);
          look.set(center.x, center.y + 1.3, center.z);
        },
      });
      a.noGravity = 1.1;
    });
    c.during(0, 1.0, (dt, local, k) => {
      a.velocity.set(0, 0.6, 0);
      const p = a.center();
      w.vfx.emit('flame', p, 10, { speed: [2, 4], life: [0.4, 0.6], size: [0.8, 1.6], sizeEnd: 0.2, color: FireFX.colors, colorEnd: 0x901800, ring: 7 - k * 4, radial: -10 });
      w.vfx.emit('spark', p, 4, { speed: [1, 3], life: [0.5, 1], size: 0.2, color: 0xffd080, ring: 5, radial: -6, gravity: -3 });
      w.vfx.emit('glow', p, 2, { speed: 0.3, life: 0.2, size: 1 + k * 3, sizeEnd: 0.5, color: 0xffa040 });
      w.camera.addShake(dt * 0.5 * k);
    });
    c.at(1.05, () => {
      a.noGravity = 0;
      w.hitStop(0.12);
      w.camera.addShake(1);
      w.camera.kickFov(14);
      w.lighting.flash(2.2, 0xffb050);
      w.ui.screenFlash('#ffb060', 0.7, 0.6);
      const p = center.clone().setY(center.y + 1);
      w.vfx.sphere(p, 0xff7a20, 17, 0.7, 0.55);
      w.vfx.sphere(p, 0xfff0a0, 8, 0.4, 0.9);
      w.vfx.ring(center, 0xffa040, 22, 0.9);
      w.vfx.ring(center, 0xff5010, 28, 1.3, { opacity: 0.7 });
      w.vfx.emit('flame', p, 320, { speed: [10, 34], life: [0.4, 0.9], size: [1.5, 3], sizeEnd: 0.4, color: FireFX.colors, colorEnd: 0x7a1000, drag: 2.5, gravity: -2 });
      w.vfx.emit('spark', p, 160, { speed: [10, 30], life: [0.8, 1.6], size: [0.2, 0.4], color: 0xffd080, colorEnd: 0xff3000, gravity: 7 });
      w.vfx.emit('smoke', p, 50, { speed: [4, 14], life: [1.5, 3], size: [3, 5], sizeEnd: 2, color: 0x2a2220, alpha: 0.5, drag: 1.2, gravity: -1.5 });
      w.vfx.flash(p, 0xff8030, 160, 60, 1.2);
      w.vfx.decal(center, 16, Textures.scorch(), 0xffffff, 12, { opacity: 0.6 });
      w.audio.play('big_explosion', p);
      areaDamage(w, a, center, 18, { amount: c.dmg(), element: 'fire', knockback: 22, launch: 9, hitstun: 1, stagger: 300, isAbility: true, hitstop: 0, shake: 0, heavy: true, ultGain: 0 }, { falloff: 0.5, height: 8, onHit: (t) => t.effects.apply({ ...Effects.burn(a, 18, 4), stacks: 3 }, w), propDamage: 900 });
      // The ground becomes a sea of flames.
      const fieldMat = w.vfx.animate(fireGroundMaterial(1));
      const field = new THREE.Mesh(new THREE.PlaneGeometry(40, 40), fieldMat);
      field.rotation.x = -Math.PI / 2;
      field.position.y = 0.12;
      field.renderOrder = 3;
      const g = new THREE.Group();
      g.add(field);
      w.zones.spawn({
        owner: a,
        position: center,
        radius: 20,
        height: 6,
        duration: 6.5,
        tickInterval: 0.4,
        harmful: true,
        visual: g,
        fadeOut: 1.2,
        onUpdate(z, dt) {
          fieldMat.uniforms.uOpacity.value = z.fade;
          const n = Math.floor(dt * 70) + (Math.random() < (dt * 70) % 1 ? 1 : 0);
          for (let i = 0; i < n; i++) {
            const ang = Math.random() * TAU;
            const r = Math.sqrt(Math.random()) * 19;
            const q = new THREE.Vector3(center.x + Math.cos(ang) * r, 0, center.z + Math.sin(ang) * r);
            q.y = w.arena.terrainHeight(q.x, q.z) + 0.2;
            w.vfx.emit('flame', q, 1, { speed: [1, 3], dir: new THREE.Vector3(0, 1, 0), spread: 0.4, life: [0.4, 0.8], size: [0.9, 1.8], sizeEnd: 0.3, color: FireFX.colors, colorEnd: 0x901800, gravity: -3 });
            if (Math.random() < 0.3) FireFX.embers(w.vfx, q, 1, 0.5);
          }
        },
        onTick(z, targets) {
          for (const t of targets) {
            w.combat.dealDamage(a, t, { amount: c.dmg(26), element: 'fire', isDot: true, sound: null, vfx: false, ultGain: 0 });
            t.effects.apply(Effects.burn(a, 14, 2), w);
          }
        },
        onEnd() {
          w.vfx.release(fieldMat);
        },
      });
    });
    c.end(1.9);
  },
};

// ================================================================ define ==
export const Blaze: CharacterDefinition = {
  id: 'blaze',
  name: 'Blaze',
  title: 'The Living Inferno',
  role: 'Brawler',
  description: 'A hot-blooded street fighter whose fists burn hotter than the sun. Blaze overwhelms opponents with relentless pressure, explosive burst and scorched earth.',
  playstyle: 'Stay in their face. Chain fast punches into fiery abilities, keep enemies burning, and fight inside your own flames. Hits hard and moves fast, but can’t take much punishment.',
  difficulty: 1,
  element: 'fire',
  theme: { primary: '#ff6a1a', secondary: '#ffc04a', glow: '#ff8a30', dark: '#3a0e04' },
  stats,
  buildModel,
  animations,
  combo,
  abilities: [flameDash, infernoPunch, fireballBarrage, flameTornado, meteorCrash, worldBurner],
  passive: {
    name: 'Kindling',
    description: 'Basic attacks ignite enemies (stacking burn). Blaze deals +15% damage to burning targets, and +20% more while below 35% health.',
  },
  hooks: {
    modifyOutgoing(self, target, spec) {
      if (target.effects.has('burn')) spec.amount *= 1.15;
      if (self.health.ratio < 0.35) spec.amount *= 1.2;
    },
    onDealDamage(self, target, result, spec, world) {
      if (!spec.isAbility && !spec.isDot && self.kind === 'player') target.effects.apply(Effects.burn(self, 12, 3), world);
    },
  },
  vfx: {
    hit(world, pos, dir, strength, crit) {
      FireFX.burst(world.vfx, pos, 0.5 + strength * 0.5, dir);
      GenericFX.impact(world.vfx, pos, 0xff9a40, strength);
      if (crit) world.vfx.flash(pos, 0xff9040, 18, 8, 0.15);
    },
    dodge(world, actor, dir) {
      FireFX.burst(world.vfx, actor.position.clone().setY(actor.position.y + 0.4), 0.8, dir.clone().negate());
      world.vfx.afterimage(actor, 0xff6a20, 0.3, 0.45);
    },
    land(world, actor, s) {
      EarthFX.dust(world.vfx, actor.position, 0.8 * s + 0.4, Math.round(4 + s * 6));
      FireFX.embers(world.vfx, actor.position, 3, 0.4);
    },
    death(world, actor) {
      FireFX.burst(world.vfx, actor.center(), 2);
    },
    aura(world, actor, dt) {
      const rate = actor.health.ratio < 0.35 ? 30 : 10;
      if (Math.random() < dt * rate) FireFX.embers(world.vfx, actor.socketPos(Math.random() < 0.5 ? 'handL' : 'handR'), 1, 0.08);
      const hair = actor.rig.root.userData.hair as THREE.Mesh[] | undefined;
      if (hair) {
        const t = world.time * 12;
        hair.forEach((m, i) => (m.scale.y = 1 + Math.sin(t + i * 1.7) * 0.18));
        if (Math.random() < dt * 8) FireFX.embers(world.vfx, actor.socketPos('head').setY(actor.socketPos('head').y + 0.2), 1, 0.1);
      }
    },
  },
  sounds: {
    swing: 'fire_swing',
    heavySwing: 'heavy_whoosh',
    hit: 'fire_hit',
    heavyHit: 'fire_heavy_hit',
    dodge: 'fire_whoosh',
    jump: 'jump',
    land: 'land',
    hurt: 'hurt',
    death: 'death',
    footstep: 'footstep',
  },
  threat: { mobility: 0.6, range: 0.5, durability: 0.35, stealth: 0, area: 0.8 },
  camera: { distance: 6.2, height: 1.55, shoulder: 0.55, fov: 62 },
  portrait: { glyph: 'nova', bg: ['#ff9a3a', '#3a0e04'], fg: '#fff0c0' },
  ratings: { power: 8, speed: 7, defense: 3, range: 6, control: 5 },
};

