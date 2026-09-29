import * as THREE from 'three';
import type { AbilityDef, AttackStep, CharacterDefinition, CharacterStats } from '../types';
import type { Actor } from '../../entities/Actor';
import type { World } from '../../core/World';
import { RigBuilder, Geo, glowMat, stdMat, basicGlow, Rig } from '../../characters/Rig';
import { AnimationSet, PoseSpec, clip, combine, gaitClip, idleClip, flipClip, addRot } from '../../characters/AnimationClip';
import { LightningFX, EarthFX, GenericFX, energyDomeMaterial } from '../../vfx/ElementFX';
import { Effects } from '../../combat/Effects';
import type { EffectSpec } from '../../combat/StatusEffects';
import { LYING_BACK, areaDamage, enemiesByDistance } from './kit';
import { TAU, rand, yawFromDir, pick } from '../../core/math';
import { Textures } from '../../vfx/Textures';

// ================================================================= stats ==
const stats: CharacterStats = {
  maxHealth: 750,
  moveSpeed: 13.5,
  walkSpeed: 4.5,
  acceleration: 24,
  turnSpeed: 18,
  attackDamage: 18,
  defense: 20,
  attackSpeed: 1.6,
  dodgeDistance: 10,
  dodgeDuration: 0.2,
  dodgeCooldown: 0.35,
  dodgeIFrames: 0.2,
  abilityPower: 0.9,
  cooldownMultiplier: 0.7,
  critChance: 0.1,
  critMultiplier: 1.5,
  jumpVelocity: 12.5,
  airJumps: 1,
  gravityScale: 1,
  poise: 0,
  mass: 0.8,
  scale: 0.95,
  ultChargeRate: 1.0,
};

const BLUE = 0x4fb0ff;
const WHITE_BLUE = 0xbfe8ff;

// ================================================================= model ==
function buildModel(): Rig {
  const b = new RigBuilder({
    hipHeight: 1.0,
    torso: 0.6,
    shoulderWidth: 0.22,
    hipWidth: 0.09,
    chestWidth: 0.22,
    chestDepth: 0.15,
    waistWidth: 0.14,
    upperArm: 0.31,
    foreArm: 0.29,
    armRadius: 0.055,
    foreArmRadius: 0.05,
    thighRadius: 0.075,
    shinRadius: 0.062,
    handSize: 0.1,
    footLength: 0.26,
    neck: 0.09,
    headRadius: 0.125,
    colors: { skin: 0xd1ab8e, torso: 0x16233f, arms: 0x16233f, legs: 0x1a2848, boots: 0xe6eefc, gloves: 0xe6eefc, accent: BLUE, belt: 0x2a3a5a },
    roughness: 0.45,
    metalness: 0.25,
  });
  const rig = b.rig;
  const stripe = basicGlow(0x6fc8ff);
  // Lightning stripes (zig-zag) on limbs and torso.
  const zig = (bone: THREE.Object3D, y0: number, len: number, side: number) => {
    b.attach(bone, Geo.box(0.018, len * 0.55, 0.018), stripe, [side * 0.05, y0 - len * 0.25, 0.045], [0, 0, 0.5 * side]);
    b.attach(bone, Geo.box(0.018, len * 0.55, 0.018), stripe, [side * 0.05, y0 - len * 0.7, 0.045], [0, 0, -0.5 * side]);
  };
  zig(rig.bones.armL, 0, 0.3, 1);
  zig(rig.bones.armR, 0, 0.3, -1);
  zig(rig.bones.legL, 0, 0.45, 1);
  zig(rig.bones.legR, 0, 0.45, -1);
  // Chest bolt emblem.
  b.attach(rig.bones.chest, Geo.box(0.03, 0.16, 0.02), stripe, [0.02, 0.26, 0.15], [0.2, 0, 0.5]);
  b.attach(rig.bones.chest, Geo.box(0.03, 0.16, 0.02), stripe, [-0.02, 0.14, 0.15], [0.2, 0, 0.5]);
  b.attach(rig.bones.chest, Geo.box(0.12, 0.025, 0.02), stripe, [0, 0.2, 0.152], [0.2, 0, 0]);
  // Visor.
  b.attach(rig.bones.head, Geo.box(0.22, 0.045, 0.06), basicGlow(0x8fe0ff), [0, 0.125, 0.1]);
  // Spiky silver hair swept back.
  const hairMat = stdMat(0xe8f4ff, { roughness: 0.3, metalness: 0.4, emissive: 0x2a70c0, emissiveIntensity: 0.5 });
  const tipMat = glowMat(0x6fc8ff, 1.2);
  for (let i = 0; i < 11; i++) {
    const a = (i / 11) * Math.PI - Math.PI / 2;
    const x = Math.sin(a) * 0.08;
    const z = -0.02 - Math.abs(Math.cos(a)) * 0.04;
    const h = 0.16 + (i % 3) * 0.04;
    b.attach(rig.bones.head, Geo.cone(0.035, h, 5), i % 4 === 0 ? tipMat : hairMat, [x, 0.22 + h * 0.2, z], [-1.25 + Math.abs(x) * 2, 0, -x * 5]);
  }
  // Shoulder coils.
  for (const [bone, side] of [
    [rig.bones.armL, 1],
    [rig.bones.armR, -1],
  ] as const) {
    b.attach(bone, Geo.torus(0.07, 0.018, 6, 14), glowMat(BLUE, 1.5), [side * 0.01, -0.02, 0], [0, 0, Math.PI / 2]);
    b.attach(bone, Geo.torus(0.055, 0.015, 6, 14), glowMat(BLUE, 1.5), [0, -0.1, 0], [Math.PI / 2, 0, 0]);
  }
  // Knee pads + back fins.
  for (const shin of [rig.bones.shinL, rig.bones.shinR]) b.attach(shin, Geo.box(0.1, 0.09, 0.06), stdMat(0xe6eefc, { metalness: 0.4 }), [0, -0.03, 0.055]);
  for (const side of [1, -1]) b.attach(rig.bones.chest, Geo.box(0.02, 0.24, 0.1), stdMat(0xe6eefc, { metalness: 0.5, roughness: 0.3 }), [side * 0.1, 0.34, -0.17], [-0.5, 0, side * 0.25]);
  return rig;
}

// ============================================================ animations ==
const V: PoseSpec = {
  pos: [0, -0.1, 0],
  hips: [0, -0.35, 0],
  chest: [0.12, 0.4, 0],
  head: [0.02, -0.15, 0],
  armL: [-1.15, 0, 0.12],
  foreL: [-0.45, 0, 0],
  armR: [-0.25, 0, -0.25],
  foreR: [-1.7, 0, 0],
  legL: [-0.5, 0, 0.12],
  shinL: [0.55, 0, 0],
  legR: [0.35, 0, -0.12],
  shinR: [0.5, 0, 0],
  footL: [0.1, 0, 0],
};

/** Electric twitch layer: occasional micro-spasms. */
const twitch = (t: number, out: Float32Array, time: number) => {
  const n = Math.sin(time * 37.1) * Math.sin(time * 13.7) * Math.sin(time * 5.3);
  if (n > 0.55) {
    const k = (n - 0.55) * 0.5;
    addRot(out, 'head', k * Math.sin(time * 90), k * Math.cos(time * 70), 0);
    addRot(out, 'foreL', k * Math.sin(time * 80), 0, 0);
    addRot(out, 'armR', 0, 0, k * Math.cos(time * 60));
  }
};

const FLIP_TUCK: PoseSpec = { legL: [-2.0, 0, 0.1], shinL: [2.2, 0, 0], legR: [-2.0, 0, -0.1], shinR: [2.2, 0, 0], armL: [-1.2, 0, 0.3], armR: [-1.2, 0, -0.3], foreL: [-1.5, 0, 0], foreR: [-1.5, 0, 0], chest: [0.4, 0, 0], head: [0.4, 0, 0] };

const animations: AnimationSet = {
  idle: { ...idleClip({ base: V, breathe: 0.04, crouch: 0.0, speed: 1.2, bob: 0.045, bobSpeed: 3 }), layer: twitch },
  walk: gaitClip(0.7, { stride: 0.5, knee: 0.7, armSwing: 0.3, elbow: -0.6, armOut: 0.12, bounce: 0.035, crouch: 0.05, lean: 0.12, sway: 0.03, twist: 0.15, headStabilize: 0.8 }),
  run: { ...gaitClip(0.42, { stride: 1.1, knee: 1.9, armSwing: 0.1, elbow: -0.3, armOut: 0.18, bounce: 0.05, crouch: 0.12, lean: 0.7, sway: 0.03, twist: 0.1, headStabilize: 1.0, armsBack: 1.0 }), layer: twitch },
  jump: clip(0.35, [
    { t: 0, p: combine(V, { pos: [0, -0.2, 0] }) },
    { t: 0.5, p: { root: [0.15, 0, 0], armL: [-2.6, 0, 0.3], armR: [-0.4, 0, -0.5], foreL: [-0.2, 0, 0], legL: [-1.4, 0, 0], shinL: [1.8, 0, 0], legR: [0.2, 0, 0], shinR: [0.6, 0, 0] }, e: 'out' },
    { t: 1, p: { root: [0.1, 0, 0], armL: [-2.3, 0, 0.4], armR: [-0.5, 0, -0.6], legL: [-1.3, 0, 0], shinL: [1.7, 0, 0], legR: [0.1, 0, 0], shinR: [0.8, 0, 0] } },
  ]),
  airJump: flipClip(0.45, 1.0, FLIP_TUCK, 1),
  fall: clip(0.6, [
    { t: 0, p: { armL: [-0.3, 0, 1.1], armR: [-0.3, 0, -1.1], foreL: [-0.3, 0, 0], foreR: [-0.3, 0, 0], legL: [-0.9, 0, 0.1], shinL: [1.3, 0, 0], legR: [0.2, 0, -0.1], shinR: [0.4, 0, 0] } },
    { t: 0.5, p: { armL: [-0.4, 0, 1.2], armR: [-0.2, 0, -1.0], foreL: [-0.3, 0, 0], foreR: [-0.3, 0, 0], legL: [-0.8, 0, 0.1], shinL: [1.2, 0, 0], legR: [0.25, 0, -0.1], shinR: [0.5, 0, 0] } },
  ], true),
  land: clip(0.24, [
    { t: 0, p: { pos: [0, -0.45, 0], chest: [0.6, 0.2, 0], armR: [-0.6, 0, -0.3], foreR: [0, 0, 0], armL: [0.6, 0, 0.9], legL: [-1.4, 0, 0.1], shinL: [2.1, 0, 0], legR: [0.3, 0, -0.1], shinR: [2.2, 0, 0], head: [-0.4, 0, 0] } },
    { t: 1, p: V, e: 'out' },
  ]),
  dodge: clip(0.28, [
    { t: 0, p: V },
    { t: 0.2, p: { root: [0.9, 0, 0], pos: [0, 0.15, 0], armL: [1.3, 0, 0.2], armR: [1.3, 0, -0.2], legL: [0.3, 0, 0], shinL: [0.6, 0, 0], legR: [0.6, 0, 0], shinR: [0.9, 0, 0], head: [-0.7, 0, 0] }, e: 'outExpo' },
    { t: 0.8, p: { root: [0.85, 0, 0], pos: [0, 0.15, 0], armL: [1.3, 0, 0.2], armR: [1.3, 0, -0.2], legL: [0.3, 0, 0], shinL: [0.6, 0, 0], legR: [0.6, 0, 0], shinR: [0.9, 0, 0], head: [-0.7, 0, 0] } },
    { t: 1, p: V },
  ]),
  hit: clip(0.26, [
    { t: 0, p: V },
    { t: 0.25, p: combine(V, { chest: [-0.4, -0.3, 0.2], head: [-0.5, 0.3, 0], armL: [0.6, 0, 0.5], armR: [0.3, 0, -0.6], foreL: [0.4, 0, 0], pos: [0, -0.05, -0.06] }), e: 'outExpo' },
    { t: 1, p: V },
  ]),
  knockback: clip(0.7, [
    { t: 0, p: { chest: [-0.5, 0, 0], armL: [-2.2, 0, 1.0], armR: [-2.2, 0, -1.0], legL: [-0.6, 0, 0], legR: [-0.1, 0, 0] } },
    { t: 0.45, p: { root: [-0.7, TAU * 0.75, 0], armL: [-1.5, 0, 1.5], armR: [-1.5, 0, -1.5], legL: [-0.9, 0, 0.3], shinL: [1.0, 0, 0], legR: [0.2, 0, -0.3] }, e: 'linear' },
    { t: 0.8, p: combine(LYING_BACK, { root: [0, TAU, 0] }), e: 'out' },
    { t: 1, p: combine(LYING_BACK, { root: [0, TAU, 0] }) },
  ]),
  getup: clip(0.4, [
    { t: 0, p: LYING_BACK },
    { t: 0.3, p: { root: [-0.9, 0, 0], pos: [0, 0.35, 0], armL: [-2.6, 0, 0.4], armR: [-2.6, 0, -0.4], foreL: [-1.6, 0, 0], foreR: [-1.6, 0, 0], legL: [-2.2, 0, 0], shinL: [0.4, 0, 0], legR: [-2.2, 0, 0], shinR: [0.4, 0, 0] } },
    { t: 0.6, p: { root: [0.2, 0, 0], pos: [0, 0.3, 0], armL: [-1.8, 0, 0.8], armR: [-1.8, 0, -0.8], legL: [-0.6, 0, 0], shinL: [1.0, 0, 0], legR: [-0.3, 0, 0], shinR: [0.8, 0, 0] }, e: 'out' },
    { t: 1, p: V },
  ]),
  death: {
    ...clip(1.4, [
      { t: 0, p: combine(V, { chest: [-0.3, 0, 0] }) },
      { t: 0.35, p: { chest: [-0.5, 0, 0.3], head: [-0.6, 0.4, 0], armL: [-1.8, 0, 1.4], armR: [-1.2, 0, -1.5], foreL: [-0.2, 0, 0], legL: [-0.2, 0, 0.3], legR: [0.2, 0, -0.2], pos: [0, 0.05, 0] } },
      { t: 0.75, p: { root: [0, 0.4, 1.5], pos: [0.2, 0.2, 0], chest: [0.1, 0, 0.1], head: [0, 0.5, 0.3], armL: [-2.6, 0, 0.6], armR: [-0.3, 0, -0.3], legL: [-0.5, 0, 0.1], shinL: [0.9, 0, 0], legR: [-0.2, 0, 0], shinR: [0.4, 0, 0] }, e: 'in' },
      { t: 1, p: { root: [0, 0.4, 1.52], pos: [0.2, 0.18, 0], chest: [0.1, 0, 0.1], head: [0, 0.5, 0.3], armL: [-2.6, 0, 0.6], armR: [-0.3, 0, -0.3], legL: [-0.5, 0, 0.1], shinL: [0.9, 0, 0], legR: [-0.2, 0, 0], shinR: [0.4, 0, 0] } },
    ]),
    layer: (t, out, time) => {
      if (t < 0.5) {
        const k = (0.5 - t) * 0.5;
        addRot(out, 'chest', Math.sin(time * 70) * k, 0, Math.cos(time * 55) * k);
        addRot(out, 'armL', Math.sin(time * 60) * k, 0, 0);
        addRot(out, 'armR', Math.cos(time * 65) * k, 0, 0);
      }
    },
  },
  stunned: { ...clip(0.6, [{ t: 0, p: combine(V, { chest: [0.3, 0, 0], head: [0.4, 0, 0] }) }, { t: 0.5, p: combine(V, { chest: [0.35, 0.1, 0], head: [0.45, 0.2, 0] }) }], true), layer: twitch },
  // ---- combo --------------------------------------------------------
  palmL: clip(0.26, [
    { t: 0, p: V },
    { t: 0.35, p: combine(V, { armL: [-0.45, 0, -0.1], foreL: [0.45, 0, 0], chest: [0.1, -0.7, 0], pos: [0, 0, 0.15] }), e: 'outExpo' },
    { t: 1, p: V },
  ]),
  palmR: clip(0.26, [
    { t: 0, p: V },
    { t: 0.35, p: combine(V, { armR: [-1.35, 0, 0.25], foreR: [1.7, 0, 0], armL: [0.6, 0, 0], foreL: [-1.0, 0, 0], chest: [0.1, 0.1, 0], pos: [0, 0, 0.15] }), e: 'outExpo' },
    { t: 1, p: V },
  ]),
  spinKick: clip(0.36, [
    { t: 0, p: V },
    { t: 0.2, p: { root: [0, -1.4, 0], pos: [0, -0.05, 0], armL: [-0.6, 0, 0.9], armR: [-0.6, 0, -0.9], legL: [-0.2, 0, 0], shinL: [0.4, 0, 0], legR: [0.2, 0, 0], shinR: [1.2, 0, 0] } },
    { t: 0.45, p: { root: [0, -3.0, -0.3], pos: [0, 0.05, 0], chest: [0, 0, -0.3], armL: [-0.4, 0, 1.2], armR: [-0.4, 0, -1.2], legL: [-0.1, 0, 0], shinL: [0.3, 0, 0], legR: [0, 0, -1.55], shinR: [0.05, 0, 0] }, e: 'outExpo' },
    { t: 0.7, p: { root: [0, -3.6, -0.2], armL: [-0.4, 0, 1.0], armR: [-0.4, 0, -1.0], legR: [0, 0, -1.2], shinR: [0.3, 0, 0] } },
    { t: 1, p: combine(V, { root: [0, -TAU, 0] }) },
  ]),
  knee: clip(0.3, [
    { t: 0, p: V },
    { t: 0.4, p: { root: [-0.1, 0, 0], pos: [0, 0.12, 0.1], legR: [-1.9, 0, 0], shinR: [2.3, 0, 0], legL: [0.15, 0, 0], shinL: [0.2, 0, 0], armL: [-1.4, 0, 0.3], foreL: [-1.6, 0, 0], armR: [-1.4, 0, -0.3], foreR: [-1.6, 0, 0], chest: [0.3, 0, 0] }, e: 'outExpo' },
    { t: 1, p: V },
  ]),
  doublePalm: clip(0.34, [
    { t: 0, p: V },
    { t: 0.2, p: combine(V, { armL: [0.3, 0, 0], armR: [0.3, 0, 0], foreL: [-1.9, 0, 0], foreR: [-1.9, 0, 0], chest: [-0.1, -0.35, 0], pos: [0, -0.15, 0] }) },
    { t: 0.45, p: { pos: [0, -0.12, 0.2], chest: [0.3, 0, 0], armL: [-1.5, 0, -0.15], armR: [-1.5, 0, 0.15], foreL: [0, 0, 0], foreR: [0, 0, 0], legL: [-0.8, 0, 0], shinL: [0.7, 0, 0], legR: [0.6, 0, 0], shinR: [0.3, 0, 0] }, e: 'outExpo' },
    { t: 1, p: V },
  ]),
  flyingKick: clip(0.5, [
    { t: 0, p: combine(V, { pos: [0, -0.2, 0] }) },
    { t: 0.3, p: { root: [-0.2, 0.9, 0], pos: [0, 0.35, 0], chest: [0, -0.4, 0], legL: [-1.6, 0, 0], shinL: [0.05, 0, 0], legR: [-0.5, 0, 0], shinR: [2.0, 0, 0], armL: [-0.2, 0, 0.8], armR: [-1.2, 0, -0.4], foreR: [-1.8, 0, 0] }, e: 'outExpo' },
    { t: 0.7, p: { root: [-0.2, 0.9, 0], pos: [0, 0.3, 0], chest: [0, -0.4, 0], legL: [-1.6, 0, 0], shinL: [0.05, 0, 0], legR: [-0.5, 0, 0], shinR: [2.0, 0, 0], armL: [-0.2, 0, 0.8], armR: [-1.2, 0, -0.4], foreR: [-1.8, 0, 0] } },
    { t: 1, p: V },
  ]),
  diveKick: clip(0.45, [
    { t: 0, p: FLIP_TUCK },
    { t: 0.3, p: { root: [0.5, 0, 0], legR: [-1.2, 0, 0], shinR: [0.1, 0, 0], legL: [-0.2, 0, 0], shinL: [1.8, 0, 0], armL: [0.8, 0, 0.6], armR: [0.8, 0, -0.6] }, e: 'outExpo' },
    { t: 1, p: { root: [0.55, 0, 0], legR: [-1.2, 0, 0], shinR: [0.1, 0, 0], legL: [-0.2, 0, 0], shinL: [1.8, 0, 0], armL: [0.8, 0, 0.6], armR: [0.8, 0, -0.6] } },
  ]),
  // ---- abilities ----------------------------------------------------
  lightningStep: clip(0.25, [
    { t: 0, p: { root: [0.8, 0, 0], pos: [0, 0.1, 0], armL: [1.3, 0, 0.3], armR: [1.3, 0, -0.3], legL: [0.2, 0, 0], legR: [0.5, 0, 0], shinR: [0.8, 0, 0], head: [-0.6, 0, 0] } },
    { t: 0.4, p: combine(V, { pos: [0, -0.25, 0], chest: [0.3, 0, 0] }), e: 'outExpo' },
    { t: 1, p: V },
  ]),
  thunderPunch: clip(0.55, [
    { t: 0, p: combine(V, { armR: [0.5, 0, -0.3], foreR: [-1.8, 0, 0], chest: [0.1, -0.2, 0] }) },
    { t: 0.25, p: { root: [0.3, 0, 0], pos: [0, -0.1, 0.1], chest: [0.1, 0.7, 0], armR: [-1.6, 0, 0.05], foreR: [0, 0, 0], armL: [0.8, 0, 0.3], foreL: [-1.2, 0, 0], legL: [-1.0, 0, 0], shinL: [0.9, 0, 0], legR: [0.7, 0, 0], shinR: [0.3, 0, 0] }, e: 'outExpo' },
    { t: 0.7, p: { root: [0.25, 0, 0], pos: [0, -0.1, 0.1], chest: [0.1, 0.65, 0], armR: [-1.6, 0, 0.05], foreR: [0, 0, 0], armL: [0.8, 0, 0.3], foreL: [-1.2, 0, 0], legL: [-1.0, 0, 0], shinL: [0.9, 0, 0], legR: [0.7, 0, 0], shinR: [0.3, 0, 0] } },
    { t: 1, p: V },
  ]),
  chainLightning: clip(0.6, [
    { t: 0, p: V },
    { t: 0.25, p: { chest: [0, 0.6, 0], head: [0, -0.5, 0], armR: [-1.6, 0.4, 0.2], foreR: [0, 0, 0], armL: [-0.6, 0, 0.3], foreL: [-2.3, 0, 0], legL: [-0.4, 0, 0.1], legR: [0.3, 0, -0.1], shinL: [0.4, 0, 0], shinR: [0.4, 0, 0], pos: [0, -0.08, 0] }, e: 'outExpo' },
    { t: 0.8, p: { chest: [0, 0.6, 0], head: [0, -0.5, 0], armR: [-1.62, 0.4, 0.2], foreR: [0, 0, 0], armL: [-0.6, 0, 0.3], foreL: [-2.3, 0, 0], legL: [-0.4, 0, 0.1], legR: [0.3, 0, -0.1], shinL: [0.4, 0, 0], shinR: [0.4, 0, 0], pos: [0, -0.08, 0] } },
    { t: 1, p: V },
  ]),
  staticField: clip(0.45, [
    { t: 0, p: V },
    { t: 0.35, p: { pos: [0, -0.5, 0], chest: [0.8, 0, 0], head: [-0.3, 0, 0], armR: [-0.6, 0, -0.1], foreR: [0, 0, 0], armL: [-0.6, 0, 0.1], foreL: [0, 0, 0], legL: [-1.4, 0, 0.3], shinL: [2.0, 0, 0], legR: [-1.2, 0, -0.3], shinR: [2.0, 0, 0] }, e: 'outExpo' },
    { t: 0.7, p: { pos: [0, 0, 0], chest: [-0.2, 0, 0], head: [-0.2, 0, 0], armL: [-0.3, 0, 1.4], armR: [-0.3, 0, -1.4], foreL: [0, 0, 0], foreR: [0, 0, 0], legL: [-0.1, 0, 0.3], legR: [-0.1, 0, -0.3] }, e: 'out' },
    { t: 1, p: V },
  ]),
  thunderSpear: clip(0.75, [
    { t: 0, p: V },
    { t: 0.4, p: { pos: [0, -0.05, -0.05], hips: [0, -0.6, 0], chest: [-0.15, -0.7, 0], head: [0, 0.6, 0], armR: [-2.6, 0, -0.5], foreR: [-1.2, 0, 0], armL: [-1.4, 0, 0.3], foreL: [0, 0, 0], legL: [-0.6, 0, 0.1], shinL: [0.4, 0, 0], legR: [0.5, 0, -0.1], shinR: [0.4, 0, 0] } },
    { t: 0.55, p: { pos: [0, -0.12, 0.25], hips: [0, 0.4, 0], chest: [0.4, 0.6, 0], head: [0, -0.3, 0], armR: [-1.3, 0, 0.1], foreR: [0, 0, 0], armL: [0.6, 0, 0.4], foreL: [-0.8, 0, 0], legL: [-1.0, 0, 0], shinL: [0.8, 0, 0], legR: [0.8, 0, 0], shinR: [0.3, 0, 0] }, e: 'outExpo' },
    { t: 0.85, p: { pos: [0, -0.1, 0.2], hips: [0, 0.4, 0], chest: [0.35, 0.55, 0], head: [0, -0.3, 0], armR: [-1.2, 0, 0.1], foreR: [0, 0, 0], armL: [0.6, 0, 0.4], foreL: [-0.8, 0, 0], legL: [-1.0, 0, 0], shinL: [0.8, 0, 0], legR: [0.8, 0, 0], shinR: [0.3, 0, 0] } },
    { t: 1, p: V },
  ]),
  stormGod: {
    ...clip(0.9, [
      { t: 0, p: V },
      { t: 0.3, p: { pos: [0, -0.3, 0], chest: [0.5, 0, 0], armL: [-0.3, 0, 0.3], armR: [-0.3, 0, -0.3], foreL: [-1.5, 0, 0], foreR: [-1.5, 0, 0], legL: [-1.0, 0, 0.2], shinL: [1.5, 0, 0], legR: [-1.0, 0, -0.2], shinR: [1.5, 0, 0] } },
      { t: 0.6, p: { pos: [0, 0.2, 0], chest: [-0.35, 0, 0], head: [-0.6, 0, 0], armL: [-2.8, 0, 0.5], armR: [-2.8, 0, -0.5], foreL: [0, 0, 0], foreR: [0, 0, 0], legL: [0.1, 0, 0.15], shinL: [0.3, 0, 0], legR: [0.2, 0, -0.15], shinR: [0.5, 0, 0] }, e: 'outExpo' },
      { t: 1, p: { pos: [0, 0.2, 0], chest: [-0.3, 0, 0], head: [-0.5, 0, 0], armL: [-2.8, 0, 0.5], armR: [-2.8, 0, -0.5], legL: [0.1, 0, 0.15], shinL: [0.3, 0, 0], legR: [0.2, 0, -0.15], shinR: [0.5, 0, 0] } },
    ]),
    layer: twitch,
  },
};

// ================================================================= combo ==
const tr = (socket: 'handL' | 'handR' | 'footL' | 'footR', from: number, to: number, width = 0.3) => ({ socket, color: 0x6fc8ff, from, to, width });

const combo = {
  resetTime: 0.45,
  ground: [
    { name: 'Palm Strike', anim: 'palmL', duration: 0.26, hits: [{ time: 0.09, range: 1.9, arc: 70, damage: 0.9, knockback: 1.5, hitstun: 0.28, stagger: 25, element: 'lightning' }], lunge: 1.0, lungeStart: 0, lungeEnd: 0.09, cancelTime: 0.13, swingSound: 'zap_swing', trail: [tr('handL', 0.02, 0.12)] },
    { name: 'Palm Strike', anim: 'palmR', duration: 0.26, hits: [{ time: 0.09, range: 1.9, arc: 70, damage: 0.9, knockback: 1.5, hitstun: 0.28, stagger: 25, element: 'lightning' }], lunge: 1.0, lungeStart: 0, lungeEnd: 0.09, cancelTime: 0.13, swingSound: 'zap_swing', trail: [tr('handR', 0.02, 0.12)] },
    { name: 'Arc Kick', anim: 'spinKick', duration: 0.36, hits: [{ time: 0.15, range: 2.3, arc: 160, damage: 1.1, knockback: 3, hitstun: 0.32, stagger: 30, element: 'lightning' }], lunge: 0.8, lungeStart: 0.02, lungeEnd: 0.15, cancelTime: 0.2, swingSound: 'whoosh', trail: [tr('footR', 0.06, 0.24, 0.45)] },
    { name: 'Volt Knee', anim: 'knee', duration: 0.3, hits: [{ time: 0.12, range: 1.8, arc: 70, damage: 1.0, knockback: 1, launch: 4.5, hitstun: 0.4, stagger: 35, element: 'lightning' }], lunge: 1.2, lungeStart: 0, lungeEnd: 0.12, cancelTime: 0.16, swingSound: 'zap_swing', trail: [tr('footR', 0.02, 0.14)] },
    { name: 'Twin Palm', anim: 'doublePalm', duration: 0.34, hits: [{ time: 0.15, range: 2.1, arc: 80, damage: 1.3, knockback: 5, hitstun: 0.35, stagger: 40, element: 'lightning' }], lunge: 1.0, lungeStart: 0.05, lungeEnd: 0.15, cancelTime: 0.2, swingSound: 'zap_swing', trail: [tr('handL', 0.08, 0.2), tr('handR', 0.08, 0.2)],
      onHitFrame(ctx) {
        LightningFX.arcBurst(ctx.world.vfx, ctx.attacker.socketPos('handR').addScaledVector(ctx.attacker.forward(), 0.4), 1.2, 3);
      } },
    { name: 'Thunderclap Kick', anim: 'flyingKick', duration: 0.5, hits: [{ time: 0.2, range: 2.4, arc: 90, damage: 2.0, knockback: 13, launch: 3, hitstun: 0.5, stagger: 70, hitstop: 0.07, shake: 0.3, element: 'lightning' }], lunge: 4.5, lungeStart: 0.04, lungeEnd: 0.22, cancelTime: 0.34, swingSound: 'whoosh', trail: [tr('footL', 0.05, 0.3, 0.5)],
      onHitFrame(ctx) {
        const a = ctx.attacker;
        const p = a.socketPos('footL');
        LightningFX.arcBurst(ctx.world.vfx, p, 2, 5);
        ctx.world.audio.play('zap_heavy', p, { volume: 0.7 });
      } },
  ] as AttackStep[],
  air: {
    name: 'Thunder Drop',
    anim: 'diveKick',
    duration: 0.45,
    hits: [
      { time: 0.14, range: 2.2, arc: 110, damage: 1.2, knockback: 5, hitstun: 0.35, stagger: 40, heightMin: -2.8, heightMax: 1.5, element: 'lightning' },
      { time: 0.3, range: 2.2, arc: 110, damage: 1.0, knockback: 6, hitstun: 0.35, stagger: 40, heightMin: -2.8, heightMax: 1.5, element: 'lightning' },
    ],
    cancelTime: 0.34,
    swingSound: 'zap_swing',
    trail: [tr('footR', 0.05, 0.4, 0.4)],
    onStart(ctx) {
      const a = ctx.attacker;
      const f = a.forward();
      a.velocity.set(f.x * 12, -14, f.z * 12);
    },
    onHitFrame(ctx) {
      LightningFX.sparks(ctx.world.vfx, ctx.attacker.socketPos('footR'), 10, 8);
    },
  } as AttackStep,
};

// ================================================================ static ==
/** Volt's passive: stacking static that discharges at 4 stacks. */
function staticEffect(source: Actor): EffectSpec {
  return {
    id: 'static',
    duration: 4,
    maxStacks: 4,
    icon: 'static',
    source,
    onUpdate(t, e, dt, w) {
      if (Math.random() < dt * e.stacks * 2) LightningFX.arcBurst(w.vfx, t.center(), 0.5 + e.stacks * 0.15, 1);
    },
  };
}

function addStatic(source: Actor, target: Actor, w: World, n = 1): void {
  if (!target.alive) return;
  let e = target.effects.apply({ ...staticEffect(source), stacks: n }, w);
  if (e.stacks >= 4) {
    target.effects.remove('static', w, true);
    const p = target.center();
    w.combat.dealDamage(source, target, { amount: 40 * source.stats.abilityPower, element: 'lightning', tag: 'static', knockback: 3, hitstun: 0.3, stagger: 30, sound: 'zap_heavy', ultGain: 0.8 });
    if (target.alive) target.effects.apply(Effects.stun(0.6, 0x9fdcff), w);
    LightningFX.arcBurst(w.vfx, p, 2.2, 6);
    w.vfx.sphere(p, 0x9fdcff, 1.6, 0.2, 0.8);
    w.ui.floatText(p.clone().setY(p.y + 1.2), 'OVERLOAD', '#8fe0ff', 0.9);
    // Arc to up to two nearby enemies.
    const others = w.combat.hostilesOf(source.faction).filter((o) => o !== target && o.position.distanceTo(target.position) < 5).slice(0, 2);
    for (const o of others) {
      w.vfx.bolt(p, o.center(), BLUE, { width: 0.1, dur: 0.2, branches: 1 });
      w.combat.dealDamage(source, o, { amount: 20 * source.stats.abilityPower, element: 'lightning', tag: 'static', hitstun: 0.2, stagger: 20, sound: null });
    }
    void e;
  }
}

// ============================================================= abilities ==
const lightningStep: AbilityDef = {
  id: 'lightningStep',
  name: 'Lightning Step',
  description: 'Instantly flash-step in any direction as a bolt of lightning, shocking enemies you pass through. Holds 2 charges.',
  cooldown: 2.5,
  charges: 2,
  damage: 30,
  anim: 'lightningStep',
  castInAir: true,
  tags: ['mobility', 'teleport'],
  icon: { glyph: 'blink', bg: ['#6fc8ff', '#0a1a4a'], fg: '#ffffff', glow: '#9fdcff' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const input = a.userData.inputDir as THREE.Vector3 | undefined;
    const dir = input && input.lengthSq() > 0.01 ? input.clone().normalize() : c.aimDir(false);
    const from = a.position.clone();
    const to = w.arena.safePoint(from, from.clone().addScaledVector(dir, 9), a.radius);
    if (!a.grounded) to.y = Math.max(to.y, from.y);
    a.facing = yawFromDir(dir.x, dir.z);
    w.vfx.afterimage(a, WHITE_BLUE, 0.45, 0.7);
    const eyeFrom = from.clone().setY(from.y + 1);
    const eyeTo = to.clone().setY(to.y + 1);
    w.vfx.bolt(eyeFrom, eyeTo, BLUE, { width: 0.2, jag: 0.12, dur: 0.25, branches: 3 });
    LightningFX.sparks(w.vfx, eyeFrom, 14, 8);
    a.position.copy(to);
    a.velocity.set(dir.x * 6, a.grounded ? 0 : Math.max(0, a.velocity.y), dir.z * 6);
    LightningFX.sparks(w.vfx, eyeTo, 18, 10);
    w.vfx.flash(eyeTo, 0x9fdcff, 25, 10, 0.2);
    w.audio.play('blink', to);
    w.camera.kickFov(6);
    for (const t of w.combat.querySegment(a.faction, eyeFrom, eyeTo, 1.0)) {
      w.combat.dealDamage(a, t, { amount: c.dmg(), element: 'lightning', knockback: 2, hitstun: 0.3, stagger: 30, isAbility: true, hitstop: 0.02 });
      addStatic(a, t, w, 1);
    }
    c.anim('lightningStep', { duration: 0.25 });
    c.invulnerable(0, 0.15);
    c.end(0.16);
  },
};

const thunderPunch: AbilityDef = {
  id: 'thunderPunch',
  name: 'Thunder Punch',
  description: 'Rocket forward with a lightning-charged straight that stuns the target and adds 2 Static stacks.',
  cooldown: 4,
  damage: 70,
  anim: 'thunderPunch',
  tags: ['stun', 'gap-close'],
  icon: { glyph: 'thunderFist', bg: ['#9fdcff', '#102a6a'], fg: '#ffffff', glow: '#6fc8ff' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const d = c.faceAim(8);
    c.anim('thunderPunch', { duration: 0.55 });
    c.at(0, () => w.audio.play('zap_swing', a.position, { pitch: 0.8 }));
    c.during(0, 0.16, () => {
      a.velocity.set(d.x * 22, a.velocity.y, d.z * 22);
      w.vfx.emit('spark', a.socketPos('handR'), 2, { speed: [1, 4], life: 0.2, size: 0.2, color: LightningFX.colors });
    });
    c.at(0.16, () => {
      c.stop();
      const f = a.forward();
      for (const t of w.combat.queryArc(a, 2.6, 80)) {
        const r = w.combat.dealDamage(a, t, { amount: c.dmg(), element: 'lightning', knockback: 7, hitstun: 0.5, stagger: 80, isAbility: true, hitstop: 0.09, shake: 0.35, dir: f, heavy: true });
        if (r) {
          t.effects.apply(Effects.stun(1.0, 0x9fdcff), w);
          addStatic(a, t, w, 2);
        }
      }
      const p = a.socketPos('handR').addScaledVector(f, 0.5);
      LightningFX.arcBurst(w.vfx, p, 2.4, 7);
      w.vfx.sphere(p, 0x9fdcff, 1.4, 0.18, 0.9);
      w.vfx.flash(p, 0x6fc8ff, 30, 12, 0.2);
      w.audio.play('zap_heavy', p);
      w.arena.damageInSphere(p, 1.5, 150, f);
    });
    c.end(0.5);
  },
};

const chainLightning: AbilityDef = {
  id: 'chainLightning',
  name: 'Chain Lightning',
  description: 'Unleash a bolt that leaps between up to 6 enemies, shocking and briefly stunning each one.',
  cooldown: 7,
  damage: 60,
  anim: 'chainLightning',
  tags: ['aoe', 'ranged', 'bounce'],
  icon: { glyph: 'chain', bg: ['#4fb0ff', '#081640'], fg: '#e8f8ff', glow: '#6fc8ff' },
  canCast(caster, world) {
    return enemiesByDistance(world, caster, 20).length > 0;
  },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const first = c.findTarget(20, 100) ?? enemiesByDistance(w, a, 20)[0];
    if (!first) {
      c.end(0.1);
      return;
    }
    a.faceTowards(first.position);
    c.anim('chainLightning', { duration: 0.6 });
    const chain: Actor[] = [first];
    const hitSet = new Set<Actor>([first]);
    for (let i = 0; i < 5; i++) {
      const prev = chain[chain.length - 1];
      const next = w.combat.nearestHostile(a.faction, prev.position, 10, undefined, 180, hitSet);
      if (!next) break;
      chain.push(next);
      hitSet.add(next);
    }
    chain.forEach((t, i) => {
      c.at(0.12 + i * 0.08, () => {
        const from = i === 0 ? a.socketPos('handR') : chain[i - 1].center();
        const to = t.center();
        w.vfx.bolt(from, to, BLUE, { width: 0.18, jag: 0.25, dur: 0.3, branches: 2 });
        w.vfx.bolt(from, to, 0xffffff, { width: 0.06, jag: 0.2, dur: 0.18, branches: 0 });
        LightningFX.sparks(w.vfx, to, 12, 8);
        w.audio.play('chain_zap', to, { pitch: 1 + i * 0.08 });
        if (!t.alive) return;
        const r = w.combat.dealDamage(a, t, { amount: c.dmg() * Math.pow(0.88, i), element: 'lightning', knockback: 2, hitstun: 0.35, stagger: 40, isAbility: true, hitstop: 0.02 });
        if (r) {
          t.effects.apply(Effects.stun(0.25, 0x9fdcff), w);
          addStatic(a, t, w, 1);
        }
      });
    });
    c.end(0.6);
  },
};

const staticField: AbilityDef = {
  id: 'staticField',
  name: 'Static Field',
  description: 'Electrify the air around you for 6s. Enemies inside are slowed by 45% and shocked twice per second.',
  cooldown: 12,
  damage: 14,
  anim: 'staticField',
  tags: ['zone', 'slow', 'aoe'],
  icon: { glyph: 'field', bg: ['#3a90ff', '#06102a'], fg: '#cfefff', glow: '#6fc8ff' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    c.anim('staticField', { duration: 0.45 });
    c.at(0.16, () => {
      w.audio.play('static_field', a.position);
      w.vfx.ring(a.position, BLUE, 7.5, 0.4);
      LightningFX.arcBurst(w.vfx, a.position.clone().setY(a.position.y + 0.3), 3, 8);
      const g = new THREE.Group();
      const domeMat = w.vfx.animate(energyDomeMaterial(new THREE.Color(0x2a80ff), new THREE.Color(0xbfe8ff)));
      const dome = new THREE.Mesh(new THREE.SphereGeometry(7, 32, 16, 0, TAU, 0, Math.PI / 2), domeMat);
      dome.renderOrder = 5;
      g.add(dome);
      const ringMat = new THREE.MeshBasicMaterial({ map: Textures.ring(), color: 0x6fc8ff, transparent: true, opacity: 0.7, blending: THREE.AdditiveBlending, depthWrite: false });
      const ring = new THREE.Mesh(new THREE.PlaneGeometry(14.5, 14.5), ringMat);
      ring.rotation.x = -Math.PI / 2;
      ring.position.y = 0.1;
      g.add(ring);
      w.zones.spawn({
        owner: a,
        position: a.position,
        follow: a,
        radius: 7,
        height: 7,
        duration: 6,
        tickInterval: 0.5,
        harmful: true,
        visual: g,
        onUpdate(z, dt) {
          domeMat.uniforms.uOpacity.value = z.fade * 0.55;
          ringMat.opacity = z.fade * 0.7;
          ring.rotation.z += dt * 0.8;
          if (Math.random() < dt * 10) {
            const ang = Math.random() * TAU;
            const p1 = z.position.clone().add(new THREE.Vector3(Math.cos(ang) * 6.8, rand(0.2, 3), Math.sin(ang) * 6.8));
            const p2 = p1.clone().add(new THREE.Vector3(rand(-1.5, 1.5), rand(-1, 1), rand(-1.5, 1.5)));
            w.vfx.bolt(p1, p2, 0x9fdcff, { width: 0.05, jag: 0.4, dur: 0.1, branches: 0 });
          }
        },
        onTick(z, targets) {
          for (const t of targets) {
            w.vfx.bolt(a.center(), t.center(), BLUE, { width: 0.08, jag: 0.35, dur: 0.12, branches: 1 });
            w.combat.dealDamage(a, t, { amount: c.dmg(), element: 'lightning', hitstun: 0.15, stagger: 15, isAbility: true, hitstop: 0, shake: 0, sound: 'zap_hit' });
            t.effects.apply(Effects.slow(0.45, 0.7, 'staticSlow'), w);
            addStatic(a, t, w, 1);
          }
        },
        onEnd() {
          w.vfx.release(domeMat);
          ringMat.dispose();
        },
      });
    });
    c.end(0.42);
  },
};

const thunderSpear: AbilityDef = {
  id: 'thunderSpear',
  name: 'Thunder Spear',
  description: 'Forge a spear of pure lightning and hurl it at blinding speed for massive single-target damage.',
  cooldown: 8,
  damage: 190,
  anim: 'thunderSpear',
  castInAir: true,
  tags: ['ranged', 'burst', 'single-target'],
  icon: { glyph: 'spear', bg: ['#bfe8ff', '#0a2060'], fg: '#ffffff', glow: '#9fdcff' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const target = c.findTarget(40, 60);
    const aim = c.faceAim(40);
    const spear = LightningFX.spear(2.2);
    spear.scale.setScalar(0.01);
    spear.userData.noClone = true;
    a.rig.sockets.handR.add(spear);
    spear.rotation.x = Math.PI / 2;
    c.anim('thunderSpear', { duration: 0.75 });
    if (!a.grounded) a.noGravity = 0.6;
    c.at(0, () => w.audio.play('spear_charge', a.position));
    c.during(0, 0.4, (dt, local, k) => {
      spear.scale.setScalar(0.2 + k * 0.8);
      if (Math.random() < 0.5) LightningFX.sparks(w.vfx, a.socketPos('handR'), 2, 4);
      if (!a.grounded) a.velocity.y = 0;
    });
    c.at(0.42, () => {
      spear.parent?.remove(spear);
      const from = a.socketPos('handR');
      const dir = target && target.alive ? target.center().sub(from).normalize() : aim.clone().setY(0.02).normalize();
      const mesh = LightningFX.spear(2.6);
      w.audio.play('spear_fire', from);
      w.camera.kickFov(5);
      w.projectiles.spawn({
        owner: a,
        position: from,
        velocity: dir.multiplyScalar(62),
        radius: 0.55,
        lifetime: 1.2,
        mesh,
        faceVelocity: true,
        homing: target ? 6 : 0,
        target,
        onUpdate(p) {
          w.vfx.emit('spark', p.position, 3, { speed: [0.5, 2], life: [0.1, 0.25], size: 0.25, color: LightningFX.colors, jitter: 0.2 });
          w.vfx.emit('glow', p.position, 1, { speed: 0, life: 0.18, size: 1.2, sizeEnd: 0.2, color: 0x4fb0ff });
        },
        onHit(p, t) {
          const r = w.combat.dealDamage(a, t, { amount: c.dmg(), element: 'lightning', knockback: 16, launch: 4, hitstun: 0.6, stagger: 150, isAbility: true, hitstop: 0.12, shake: 0.5, dir: p.velocity.clone().setY(0).normalize(), heavy: true });
          if (r) {
            t.effects.apply(Effects.stun(0.6, 0x9fdcff), w);
            addStatic(a, t, w, 2);
          }
        },
        onImpact(p, pos, hitActor) {
          LightningFX.strike(w.vfx, pos.clone().setY(w.arena.groundHeight(pos.x, pos.z, pos.y + 1)), 8, 2);
          LightningFX.arcBurst(w.vfx, pos, 3, 8);
          w.audio.play('thunder', pos, { volume: 0.7, pitch: 1.3 });
          areaDamage(w, a, pos, 2.5, { amount: c.dmg() * 0.3, element: 'lightning', knockback: 5, hitstun: 0.3, stagger: 40, isAbility: true, sound: null }, { exclude: new Set(hitActor ? [hitActor] : []) });
        },
      });
    });
    c.onEnd(() => spear.parent?.remove(spear));
    c.end(0.72);
  },
};

const stormGod: AbilityDef = {
  id: 'stormGod',
  name: 'Storm God',
  description: 'ULTIMATE — Become the storm. For 9s lightning rains down on every enemy in the arena while Volt moves 50% faster, attacks 40% faster and recharges abilities twice as fast.',
  cooldown: 0,
  damage: 110,
  ultimate: true,
  anim: 'stormGod',
  tags: ['ultimate', 'aoe', 'buff'],
  icon: { glyph: 'storm', bg: ['#e0f4ff', '#0a1440'], fg: '#ffffff', glow: '#9fdcff' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    c.uninterruptible = true;
    c.invulnerable(0, 0.9);
    c.anim('stormGod', { duration: 0.9 });
    const dur = 9;
    c.at(0, () => {
      w.audio.play('storm', a.position);
      w.audio.play('charge_up', a.position, { pitch: 1.2 });
      w.ui.announce('STORM GOD', undefined, '#9fdcff');
      w.lighting.push('stormGod', { sunIntensity: 0.5, sunColor: new THREE.Color(0x8090c0), hemiIntensity: 0.55, hemiSky: new THREE.Color(0x5a6a9a), hemiGround: new THREE.Color(0x1a1a2a), fogColor: new THREE.Color(0x2a3048), fogDensity: 0.011, skyTop: new THREE.Color(0x0a0e1e), skyBottom: new THREE.Color(0x3a4460), exposure: 1.0 }, dur + 0.9, 0.8, 1.5);
      a.noGravity = 0.9;
    });
    c.during(0, 0.9, (dt, local, k) => {
      a.velocity.set(0, local < 0.5 ? 2 : 0, 0);
      LightningFX.arcBurst(w.vfx, a.center(), 1.5 + k * 2, 1);
    });
    c.at(0.55, () => {
      const p = a.center();
      LightningFX.strike(w.vfx, a.position.clone(), 40, 3);
      w.lighting.flash(1.5, 0xcfe8ff);
      w.audio.play('thunder', p);
      w.camera.addShake(0.6);
      w.ui.screenFlash('#cfe8ff', 0.5, 0.35);
      a.effects.apply({
        id: 'stormGod',
        duration: dur,
        icon: 'storm',
        mods: { moveSpeed: 1.5, attackSpeed: 1.4, cooldownRate: 2, damage: 1.15 },
        onUpdate(t, e, dt2) {
          if (Math.random() < dt2 * 14) LightningFX.arcBurst(w.vfx, t.center(), 1.2, 1);
          if (Math.random() < dt2 * 20) w.vfx.emit('spark', t.position, 1, { speed: [1, 3], life: 0.3, size: 0.2, color: LightningFX.colors, jitter: 0.4 });
        },
      }, w);
      // Storm ticker: strikes enemies across the arena.
      let timer = 0;
      let elapsed = 0;
      const recent = new Map<Actor, number>();
      w.addTicker((dt2) => {
        if (!a.alive || a.removed) return true;
        elapsed += dt2;
        timer -= dt2;
        if (timer <= 0) {
          timer = 0.3;
          const pool = enemiesByDistance(w, a, 45).filter((e) => (recent.get(e) ?? -9) < elapsed - 0.8);
          let at: THREE.Vector3;
          let target: Actor | null = null;
          if (pool.length && Math.random() < 0.85) {
            target = pick(pool.slice(0, 6));
            recent.set(target, elapsed);
            at = target.position.clone();
          } else {
            const ang = Math.random() * TAU;
            const r = rand(4, 25);
            at = a.position.clone().add(new THREE.Vector3(Math.cos(ang) * r, 0, Math.sin(ang) * r));
          }
          at.y = w.arena.groundHeight(at.x, at.z, at.y + 2);
          const marker = w.vfx.decal(at, 1.8, Textures.ring(), 0x9fdcff, 0.3, { additive: true, opacity: 0.9 });
          void marker;
          const hitAt = at.clone();
          const tracked = target;
          let fuse = 0.25;
          w.addTicker((dt3) => {
            fuse -= dt3;
            if (fuse > 0) return false;
            if (tracked && tracked.alive) hitAt.copy(tracked.position);
            LightningFX.strike(w.vfx, hitAt, 35, 3);
            w.lighting.flash(0.9, 0xcfe8ff);
            w.audio.play('thunder', hitAt, { volume: 0.8, pitch: rand(0.85, 1.2) });
            w.camera.addShake(0.2, hitAt);
            areaDamage(w, a, hitAt, 3, { amount: c.dmg(), element: 'lightning', knockback: 4, launch: 5, hitstun: 0.5, stagger: 90, isAbility: true, hitstop: 0.03, shake: 0, sound: null, ultGain: 0 }, { onHit: (t) => { t.effects.apply(Effects.stun(0.5, 0x9fdcff), w); addStatic(a, t, w, 1); }, propDamage: 300 });
            return true;
          });
        }
        return elapsed >= dur;
      });
    });
    c.end(0.9);
  },
};

// ================================================================ define ==
export const Volt: CharacterDefinition = {
  id: 'volt',
  name: 'Volt',
  title: 'The Living Storm',
  role: 'Speedster',
  description: 'A lightning-fast martial artist who moves between heartbeats. Volt shreds enemies with blistering combos, teleports across the battlefield and chains lightning through entire packs.',
  playstyle: 'Never stop moving. Flash in, land a flurry of light hits to stack Static, detonate it for Overload stuns, and blink out before they react. Individual hits are weak and Volt is fragile — speed is the armor.',
  difficulty: 3,
  element: 'lightning',
  theme: { primary: '#4fb0ff', secondary: '#e0f4ff', glow: '#9fdcff', dark: '#06102a' },
  stats,
  buildModel,
  animations,
  combo,
  abilities: [lightningStep, thunderPunch, chainLightning, staticField, thunderSpear, stormGod],
  passive: {
    name: 'Overload',
    description: 'Every hit applies Static. At 4 stacks the target Overloads: bonus lightning damage, a 0.6s stun and arcs to 2 nearby enemies. Volt can double-jump.',
  },
  hooks: {
    onDealDamage(self, target, result, spec, world) {
      if (spec.tag === 'static' || spec.isDot || spec.isAbility) return;
      addStatic(self, target, world, 1);
    },
    onSpawn(self) {
      self.onDodgeFrame = (a, t, w) => {
        a.targetOpacity = t < 0.95 ? 0.15 : 1;
        if (Math.random() < 0.8) w.vfx.emit('spark', a.center(), 3, { speed: [0.5, 2], life: [0.15, 0.3], size: 0.22, color: LightningFX.colors, jitter: 0.3 });
        if (t >= 0.95) a.targetOpacity = 1;
      };
    },
  },
  vfx: {
    hit(world, pos, dir, strength, crit) {
      LightningFX.sparks(world.vfx, pos, 8 + strength * 6, 6 + strength * 6, dir);
      GenericFX.impact(world.vfx, pos, 0x6fc8ff, strength);
      if (crit || strength > 0.9) LightningFX.arcBurst(world.vfx, pos, 1.4, 3);
    },
    dodge(world, actor, dir) {
      const from = actor.center();
      world.vfx.afterimage(actor, WHITE_BLUE, 0.35, 0.6);
      const to = from.clone().addScaledVector(dir, actor.stats.dodgeDistance);
      world.vfx.bolt(from, to, BLUE, { width: 0.12, jag: 0.15, dur: 0.2, branches: 1 });
      LightningFX.sparks(world.vfx, from, 8, 6);
    },
    land(world, actor, s) {
      EarthFX.dust(world.vfx, actor.position, 0.6 + s, Math.round(3 + s * 4));
      LightningFX.sparks(world.vfx, actor.position.clone().setY(actor.position.y + 0.1), Math.round(4 + s * 8), 5);
    },
    death(world, actor) {
      LightningFX.arcBurst(world.vfx, actor.center(), 2.5, 8);
    },
    aura(world, actor, dt) {
      if (Math.random() < dt * 3) LightningFX.arcBurst(world.vfx, actor.socketPos(Math.random() < 0.5 ? 'handL' : 'handR'), 0.35, 1);
      const hs = Math.hypot(actor.velocity.x, actor.velocity.z);
      if (hs > 9 && Math.random() < dt * 25) world.vfx.emit('spark', actor.position.clone().setY(actor.position.y + rand(0.2, 1.6)), 1, { speed: [0.2, 1], life: 0.25, size: 0.18, color: LightningFX.colors });
    },
  },
  sounds: {
    swing: 'zap_swing',
    heavySwing: 'whoosh',
    hit: 'zap_hit',
    heavyHit: 'zap_heavy',
    dodge: 'blink',
    jump: 'jump',
    land: 'land',
    hurt: 'hurt',
    death: 'death',
    footstep: 'footstep',
  },
  threat: { mobility: 1.0, range: 0.6, durability: 0.3, stealth: 0, area: 0.5 },
  camera: { distance: 6.4, height: 1.5, shoulder: 0.5, fov: 66 },
  portrait: { glyph: 'storm', bg: ['#6fc8ff', '#06102a'], fg: '#ffffff' },
  ratings: { power: 5, speed: 10, defense: 3, range: 7, control: 7 },
};
