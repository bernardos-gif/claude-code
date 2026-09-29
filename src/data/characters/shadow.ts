import * as THREE from 'three';
import type { AbilityDef, AttackStep, CharacterDefinition, CharacterStats } from '../types';
import type { World } from '../../core/World';
import { Actor } from '../../entities/Actor';
import { CloneAI } from '../../entities/CloneAI';
import { RigBuilder, Geo, stdMat, basicGlow, Rig } from '../../characters/Rig';
import { AnimationSet, PoseSpec, clip, combine, gaitClip, idleClip, flipClip } from '../../characters/AnimationClip';
import { ShadowFX, GenericFX, EarthFX, voidDomeMaterial } from '../../vfx/ElementFX';
import { Effects } from '../../combat/Effects';
import { LYING_BACK, enemiesByDistance } from './kit';
import { TAU, rand, yawFromDir, distXZ } from '../../core/math';
import { Textures } from '../../vfx/Textures';

// ================================================================= stats ==
const stats: CharacterStats = {
  maxHealth: 700,
  moveSpeed: 11.5,
  walkSpeed: 3.4,
  acceleration: 20,
  turnSpeed: 16,
  attackDamage: 24,
  defense: 10,
  attackSpeed: 1.35,
  dodgeDistance: 9,
  dodgeDuration: 0.26,
  dodgeCooldown: 0.5,
  dodgeIFrames: 0.26,
  abilityPower: 1.1,
  cooldownMultiplier: 0.9,
  critChance: 0.3,
  critMultiplier: 2.5,
  jumpVelocity: 12.5,
  airJumps: 1,
  gravityScale: 1,
  poise: 0,
  mass: 0.9,
  scale: 0.95,
  ultChargeRate: 1.0,
};

const PURPLE = 0xa050ff;

// ================================================================= model ==
function buildModel(): Rig {
  const b = new RigBuilder({
    hipHeight: 0.96,
    torso: 0.6,
    shoulderWidth: 0.22,
    hipWidth: 0.09,
    chestWidth: 0.22,
    chestDepth: 0.15,
    waistWidth: 0.14,
    upperArm: 0.3,
    foreArm: 0.29,
    armRadius: 0.055,
    foreArmRadius: 0.05,
    thighRadius: 0.078,
    shinRadius: 0.062,
    handSize: 0.1,
    footLength: 0.26,
    neck: 0.08,
    headRadius: 0.12,
    colors: { skin: 0x6a5a70, torso: 0x241a32, arms: 0x2c2240, legs: 0x221830, boots: 0x120e18, gloves: 0x3a2c50, accent: PURPLE, belt: 0x3a2450 },
    roughness: 0.75,
  });
  const rig = b.rig;
  const cloth = stdMat(0x281c3a, { roughness: 0.9, side: THREE.DoubleSide });
  const edge = basicGlow(0xb070ff);
  // Hood + mask.
  b.attach(rig.bones.head, new THREE.SphereGeometry(0.145, 14, 10, 0, TAU, 0, Math.PI * 0.62), cloth, [0, 0.12, -0.012], [-0.25, 0, 0]);
  b.attach(rig.bones.head, Geo.box(0.2, 0.09, 0.08), stdMat(0x0c0a10, { roughness: 0.6 }), [0, 0.05, 0.075]);
  b.attach(rig.bones.head, Geo.cone(0.05, 0.14, 4), cloth, [0, 0.26, -0.1], [-1.2, 0, 0]);
  b.eyes(0xc080ff, 0.02, 0.045, 0.02, 'slit');
  // Scarf tails.
  const scarf = new THREE.Group();
  scarf.position.set(0, 0.46, -0.13);
  rig.bones.chest.add(scarf);
  for (const side of [1, -1]) {
    const tail = b.attach(scarf, Geo.box(0.06, 0.55, 0.015), cloth, [side * 0.04, -0.26, 0], [0, 0, side * 0.08]);
    tail.castShadow = true;
  }
  rig.extras.scarf = scarf;
  // Cape.
  const cape = new THREE.Group();
  cape.position.set(0, 0.48, -0.15);
  rig.bones.chest.add(cape);
  b.attach(cape, Geo.box(0.42, 0.95, 0.015), cloth, [0, -0.46, 0]);
  b.attach(cape, Geo.box(0.42, 0.02, 0.02), edge, [0, -0.93, 0]);
  rig.extras.cape = cape;
  // Forearm blades (reverse grip, extending past the fists).
  const bladeMat = stdMat(0x2a2236, { metalness: 0.9, roughness: 0.25 });
  for (const [fore, side, name] of [
    [rig.bones.foreL, 1, 'bladeL'],
    [rig.bones.foreR, -1, 'bladeR'],
  ] as const) {
    const g = new THREE.Group();
    g.position.set(side * 0.055, -0.12, 0.02);
    g.rotation.set(0.12, 0, 0);
    fore.add(g);
    b.attach(g, Geo.box(0.018, 0.62, 0.07), bladeMat, [0, -0.22, 0]);
    b.attach(g, Geo.box(0.02, 0.6, 0.012), edge, [0, -0.22, 0.04]);
    b.attach(g, Geo.cone(0.035, 0.12, 4), bladeMat, [0, -0.58, 0], [Math.PI, 0, 0], [0.5, 1, 1]);
    const tip = new THREE.Object3D();
    tip.position.set(0, -0.6, 0.02);
    g.add(tip);
    rig.sockets[name] = tip;
  }
  // Belt pouches + shoulder wrap.
  for (const x of [-0.12, 0.12]) b.attach(rig.bones.hips, Geo.box(0.07, 0.08, 0.06), stdMat(0x2a1a3a), [x, 0.04, 0.12]);
  b.attach(rig.bones.chest, Geo.box(0.34, 0.06, 0.05), cloth, [0, 0.3, 0.08], [0.3, 0, 0.6]);
  for (const shin of [rig.bones.shinL, rig.bones.shinR]) b.attach(shin, Geo.cyl(0.07, 0.065, 0.12, 8), cloth, [0, -0.3, 0]);
  return rig;
}

/** Translucent clone body: same silhouette, ghostly void material. */
function buildCloneModel(): Rig {
  const rig = buildModel();
  const ghost = new THREE.MeshStandardMaterial({ color: 0x2a0a4a, emissive: 0x6a20c0, emissiveIntensity: 0.8, transparent: true, opacity: 0.6, roughness: 0.4, depthWrite: false });
  rig.root.traverse((o) => {
    const m = o as THREE.Mesh;
    if (m.isMesh) {
      m.material = ghost;
      m.castShadow = false;
    }
  });
  rig.materials.length = 0;
  rig.materials.push(ghost);
  return rig;
}

// ============================================================ animations ==
const S: PoseSpec = {
  root: [0.12, 0, 0],
  pos: [0, -0.24, 0],
  hips: [0, -0.2, 0],
  chest: [0.3, 0.25, 0],
  head: [-0.3, -0.15, 0],
  armL: [-0.95, 0, 0.45],
  foreL: [-1.25, 0, 0],
  armR: [0.35, 0, -0.55],
  foreR: [-0.9, 0, 0],
  legL: [-0.75, 0, 0.22],
  shinL: [1.1, 0, 0],
  legR: [0.2, 0, -0.18],
  shinR: [1.0, 0, 0],
  footL: [0.3, 0, 0],
};

const TUCK: PoseSpec = { legL: [-2.0, 0, 0.1], shinL: [2.2, 0, 0], legR: [-2.0, 0, -0.1], shinR: [2.2, 0, 0], armL: [-0.6, 0, 0.9], armR: [-0.6, 0, -0.9], chest: [0.3, 0, 0] };

const animations: AnimationSet = {
  idle: idleClip({ base: S, breathe: 0.035, crouch: 0, speed: 0.8 }),
  walk: gaitClip(1.0, { stride: 0.45, knee: 0.9, armSwing: 0.1, elbow: -1.0, armOut: 0.35, armFwd: 0.5, bounce: 0.02, crouch: 0.22, lean: 0.32, sway: 0.03, twist: 0.1, headStabilize: 1 }),
  run: gaitClip(0.5, { stride: 1.0, knee: 1.7, armSwing: 0.05, elbow: -0.2, armOut: 0.28, bounce: 0.04, crouch: 0.2, lean: 0.85, sway: 0.02, twist: 0.08, headStabilize: 1, armsBack: 1 }),
  jump: clip(0.35, [
    { t: 0, p: combine(S, { pos: [0, -0.3, 0] }) },
    { t: 0.6, p: { legL: [-1.4, 0, 0], shinL: [2.0, 0, 0], legR: [-0.4, 0, 0], shinR: [1.4, 0, 0], armL: [-0.5, 0, 0.8], armR: [0.3, 0, -0.8], foreL: [-1.0, 0, 0], chest: [0.3, 0, 0] }, e: 'out' },
    { t: 1, p: { legL: [-1.3, 0, 0], shinL: [2.0, 0, 0], legR: [-0.5, 0, 0], shinR: [1.5, 0, 0], armL: [-0.5, 0, 0.9], armR: [0.3, 0, -0.9], foreL: [-1.0, 0, 0], chest: [0.3, 0, 0] } },
  ]),
  airJump: flipClip(0.5, 0.96, TUCK, -1),
  fall: clip(0.8, [
    { t: 0, p: { armL: [0.3, 0, 1.2], armR: [0.3, 0, -1.2], foreL: [-0.4, 0, 0], foreR: [-0.4, 0, 0], legL: [-1.0, 0, 0.1], shinL: [1.5, 0, 0], legR: [-0.2, 0, -0.1], shinR: [1.2, 0, 0], chest: [0.2, 0, 0] } },
    { t: 0.5, p: { armL: [0.2, 0, 1.3], armR: [0.4, 0, -1.1], foreL: [-0.4, 0, 0], foreR: [-0.4, 0, 0], legL: [-0.9, 0, 0.1], shinL: [1.4, 0, 0], legR: [-0.3, 0, -0.1], shinR: [1.3, 0, 0], chest: [0.2, 0, 0] } },
  ], true),
  land: clip(0.3, [
    { t: 0, p: { pos: [0, -0.55, 0], root: [0.2, 0, 0], chest: [0.6, 0, 0], armL: [-0.7, 0, 0.2], foreL: [0, 0, 0], armR: [0.6, 0, -1.0], legL: [-1.6, 0, 0.15], shinL: [2.3, 0, 0], legR: [0.1, 0, -0.2], shinR: [2.3, 0, 0], head: [-0.6, 0, 0] } },
    { t: 1, p: S, e: 'out' },
  ]),
  dodge: clip(0.3, [
    { t: 0, p: S },
    { t: 0.25, p: { root: [0.8, 0, 0], pos: [0, -0.1, 0], armL: [1.4, 0, 0.3], armR: [1.4, 0, -0.3], legL: [-0.4, 0, 0], shinL: [1.6, 0, 0], legR: [0.6, 0, 0], shinR: [1.2, 0, 0], head: [-0.8, 0, 0] }, e: 'outExpo' },
    { t: 0.85, p: { root: [0.75, 0, 0], pos: [0, -0.1, 0], armL: [1.4, 0, 0.3], armR: [1.4, 0, -0.3], legL: [-0.4, 0, 0], shinL: [1.6, 0, 0], legR: [0.6, 0, 0], shinR: [1.2, 0, 0], head: [-0.8, 0, 0] } },
    { t: 1, p: S },
  ]),
  dodgeBack: flipClip(0.32, 0.96, TUCK, -1),
  hit: clip(0.28, [
    { t: 0, p: S },
    { t: 0.25, p: combine(S, { chest: [-0.5, -0.2, 0], head: [-0.4, 0, 0], armL: [0.7, 0, 0.2], armR: [0.3, 0, -0.2], pos: [0, 0.05, -0.08] }), e: 'outExpo' },
    { t: 1, p: S },
  ]),
  knockback: clip(0.7, [
    { t: 0, p: { chest: [-0.5, 0, 0], armL: [-2.2, 0, 0.9], armR: [-2.2, 0, -0.9], legL: [-0.8, 0, 0], shinL: [1.1, 0, 0], legR: [-0.2, 0, 0], shinR: [0.4, 0, 0] } },
    { t: 0.5, p: { root: [-1.8, 0, 0.3], chest: [-0.2, 0, 0], armL: [-1.8, 0, 1.3], armR: [-2.4, 0, -1.0], legL: [-1.3, 0, 0.2], shinL: [1.6, 0, 0], legR: [-0.3, 0, 0], shinR: [0.6, 0, 0] }, e: 'linear' },
    { t: 0.8, p: LYING_BACK, e: 'out' },
    { t: 1, p: LYING_BACK },
  ]),
  getup: clip(0.45, [
    { t: 0, p: LYING_BACK },
    { t: 0.4, p: { root: [-2.6, 0, 0], pos: [0, 0.8, 0.3], armL: [-2.9, 0, 0.2], armR: [-2.9, 0, -0.2], legL: [-1.6, 0, 0], shinL: [1.8, 0, 0], legR: [-1.6, 0, 0], shinR: [1.8, 0, 0] } },
    { t: 0.75, p: combine(S, { root: [-TAU + 0.3, 0, 0], pos: [0, -0.3, 0] }), e: 'out' },
    { t: 1, p: combine(S, { root: [-TAU, 0, 0] }) },
  ]),
  death: clip(1.6, [
    { t: 0, p: combine(S, { chest: [-0.4, 0, 0], head: [-0.5, 0, 0] }) },
    { t: 0.35, p: { pos: [0, -0.5, 0], chest: [0.4, 0, 0], head: [0.5, 0, 0], armL: [0.2, 0, 0.2], armR: [0.2, 0, -0.2], foreL: [-0.4, 0, 0], foreR: [-0.4, 0, 0], legL: [-1.5, 0, 0.1], shinL: [1.8, 0, 0], legR: [0.2, 0, 0], shinR: [2.3, 0, 0] } },
    { t: 1, p: { pos: [0, -1.1, 0], chest: [0.6, 0, 0], head: [0.7, 0, 0], armL: [0.3, 0, 0.2], armR: [0.3, 0, -0.2], legL: [-1.5, 0, 0.1], shinL: [1.8, 0, 0], legR: [0.2, 0, 0], shinR: [2.3, 0, 0] }, e: 'in' },
  ]),
  // ---- combo --------------------------------------------------------
  slashL: clip(0.3, [
    { t: 0, p: combine(S, { armL: [-0.9, 0, -1.0], foreL: [-1.6, 0, 0], chest: [0.3, 0.7, 0] }) },
    { t: 0.4, p: combine(S, { armL: [-0.7, 0, 1.3], foreL: [-0.3, 0, 0], chest: [0.3, -0.6, 0], pos: [0, 0, 0.15] }), e: 'outExpo' },
    { t: 1, p: S },
  ]),
  slashR: clip(0.3, [
    { t: 0, p: combine(S, { armR: [-1.4, 0, 1.0], foreR: [-1.6, 0, 0], chest: [0.3, -0.5, 0] }) },
    { t: 0.4, p: combine(S, { armR: [-1.4, 0, -1.4], foreR: [-0.3, 0, 0], chest: [0.3, 0.8, 0], armL: [0.4, 0, 0.6], pos: [0, 0, 0.15] }), e: 'outExpo' },
    { t: 1, p: S },
  ]),
  spinSlash: clip(0.4, [
    { t: 0, p: combine(S, { pos: [0, -0.3, 0] }) },
    { t: 0.35, p: { root: [0, Math.PI, 0], pos: [0, -0.2, 0], armL: [-1.4, 0, 1.3], foreL: [-0.2, 0, 0], armR: [-1.4, 0, -1.3], foreR: [-0.2, 0, 0], legL: [-0.6, 0, 0.3], shinL: [0.9, 0, 0], legR: [-0.3, 0, -0.3], shinR: [0.9, 0, 0], chest: [0.2, 0, 0] }, e: 'linear' },
    { t: 0.7, p: { root: [0, TAU, 0], pos: [0, -0.2, 0], armL: [-1.4, 0, 1.3], foreL: [-0.2, 0, 0], armR: [-1.4, 0, -1.3], foreR: [-0.2, 0, 0], legL: [-0.6, 0, 0.3], shinL: [0.9, 0, 0], legR: [-0.3, 0, -0.3], shinR: [0.9, 0, 0], chest: [0.2, 0, 0] }, e: 'linear' },
    { t: 1, p: combine(S, { root: [0, TAU, 0] }) },
  ]),
  risingSlash: clip(0.42, [
    { t: 0, p: combine(S, { pos: [0, -0.4, 0], armR: [0.6, 0, -0.3], foreR: [-0.3, 0, 0], chest: [0.6, 0.3, 0] }) },
    { t: 0.4, p: { pos: [0, 0.2, 0.1], chest: [-0.3, 0.3, 0], head: [-0.4, 0, 0], armR: [-2.9, 0, -0.2], foreR: [-0.2, 0, 0], armL: [0.4, 0, 0.8], legL: [-0.2, 0, 0], shinL: [0.3, 0, 0], legR: [0.4, 0, 0], shinR: [0.6, 0, 0] }, e: 'outExpo' },
    { t: 1, p: S },
  ]),
  crossSlash: clip(0.55, [
    { t: 0, p: S },
    { t: 0.35, p: { pos: [0, 0, -0.05], chest: [-0.2, 0, 0], armL: [-2.8, 0, 0.9], foreL: [-0.3, 0, 0], armR: [-2.8, 0, -0.9], foreR: [-0.3, 0, 0], legL: [-0.3, 0, 0.2], legR: [0.1, 0, -0.2], shinL: [0.4, 0, 0], shinR: [0.4, 0, 0] } },
    { t: 0.5, p: { pos: [0, -0.35, 0.25], chest: [0.7, 0, 0], armL: [-0.9, 0, -0.6], foreL: [-0.2, 0, 0], armR: [-0.9, 0, 0.6], foreR: [-0.2, 0, 0], legL: [-1.2, 0, 0.2], shinL: [1.3, 0, 0], legR: [0.5, 0, -0.2], shinR: [0.9, 0, 0] }, e: 'outExpo' },
    { t: 0.8, p: { pos: [0, -0.33, 0.25], chest: [0.65, 0, 0], armL: [-0.9, 0, -0.6], foreL: [-0.2, 0, 0], armR: [-0.9, 0, 0.6], foreR: [-0.2, 0, 0], legL: [-1.2, 0, 0.2], shinL: [1.3, 0, 0], legR: [0.5, 0, -0.2], shinR: [0.9, 0, 0] } },
    { t: 1, p: S },
  ]),
  airSpin: clip(0.45, [
    { t: 0, p: TUCK },
    { t: 0.45, p: { root: [0.2, Math.PI, 0], armL: [-1.4, 0, 1.4], armR: [-1.4, 0, -1.4], legL: [-1.0, 0, 0.2], shinL: [1.5, 0, 0], legR: [-0.8, 0, -0.2], shinR: [1.5, 0, 0] }, e: 'linear' },
    { t: 0.9, p: { root: [0.2, TAU, 0], armL: [-1.4, 0, 1.4], armR: [-1.4, 0, -1.4], legL: [-1.0, 0, 0.2], shinL: [1.5, 0, 0], legR: [-0.8, 0, -0.2], shinR: [1.5, 0, 0] }, e: 'linear' },
    { t: 1, p: { root: [0, TAU, 0], armL: [0.3, 0, 1.2], armR: [0.3, 0, -1.2], legL: [-1.0, 0, 0.1], shinL: [1.5, 0, 0], legR: [-0.2, 0, -0.1], shinR: [1.2, 0, 0] } },
  ]),
  // ---- abilities ----------------------------------------------------
  shadowStep: clip(0.4, [
    { t: 0, p: { pos: [0, -0.5, 0], root: [0.5, 0, 0], armL: [0.9, 0, 0.5], armR: [0.9, 0, -0.5], legL: [-1.4, 0, 0.2], shinL: [2.2, 0, 0], legR: [0.2, 0, -0.2], shinR: [2.3, 0, 0], head: [-0.6, 0, 0] } },
    { t: 0.6, p: combine(S, { armL: [-1.3, 0, 0.2], foreL: [-0.5, 0, 0], armR: [-0.3, 0, -0.8] }), e: 'outExpo' },
    { t: 1, p: S },
  ]),
  darkBlades: clip(0.5, [
    { t: 0, p: combine(S, { armR: [-1.2, 0, 1.2], foreR: [-1.8, 0, 0], chest: [0.2, -0.6, 0] }) },
    { t: 0.35, p: combine(S, { armR: [-1.5, 0, -0.5], foreR: [0, 0, 0], chest: [0.2, 0.5, 0], pos: [0, 0, 0.1] }), e: 'outExpo' },
    { t: 0.55, p: combine(S, { armL: [-1.5, 0, 0.5], foreL: [0, 0, 0], armR: [0.4, 0, -0.6], chest: [0.2, -0.4, 0] }), e: 'outExpo' },
    { t: 1, p: S },
  ]),
  smokeVanish: clip(0.4, [
    { t: 0, p: combine(S, { armR: [-2.8, 0, -0.3], foreR: [-0.5, 0, 0], pos: [0, 0.05, 0] }) },
    { t: 0.35, p: { pos: [0, -0.6, 0], root: [0.3, 0, 0], chest: [0.8, 0, 0], armR: [-0.4, 0, -0.1], foreR: [0, 0, 0], armL: [0.6, 0, 1.0], legL: [-1.6, 0, 0.3], shinL: [2.3, 0, 0], legR: [0.2, 0, -0.2], shinR: [2.4, 0, 0], head: [-0.4, 0, 0] }, e: 'inExpo' },
    { t: 1, p: { pos: [0, -0.6, 0], root: [0.3, 0, 0], chest: [0.8, 0, 0], armR: [-0.4, 0, -0.1], armL: [0.6, 0, 1.0], legL: [-1.6, 0, 0.3], shinL: [2.3, 0, 0], legR: [0.2, 0, -0.2], shinR: [2.4, 0, 0], head: [-0.4, 0, 0] } },
  ]),
  shadowClone: clip(0.7, [
    { t: 0, p: S },
    { t: 0.3, p: { pos: [0, -0.3, 0], chest: [0.1, 0, 0], head: [0.2, 0, 0], armL: [-1.2, 0, -0.5], foreL: [-1.9, 0, 0], armR: [-1.2, 0, 0.5], foreR: [-1.9, 0, 0], legL: [-0.8, 0, 0.3], shinL: [1.3, 0, 0], legR: [-0.8, 0, -0.3], shinR: [1.3, 0, 0] }, e: 'outExpo' },
    { t: 0.8, p: { pos: [0, -0.3, 0], chest: [0.1, 0, 0], head: [0.2, 0, 0], armL: [-1.25, 0, -0.5], foreL: [-1.9, 0, 0], armR: [-1.25, 0, 0.5], foreR: [-1.9, 0, 0], legL: [-0.8, 0, 0.3], shinL: [1.3, 0, 0], legR: [-0.8, 0, -0.3], shinR: [1.3, 0, 0] } },
    { t: 1, p: S },
  ]),
  executeSlashA: clip(0.16, [
    { t: 0, p: combine(S, { armL: [-2.2, 0, 0.9], foreL: [-0.8, 0, 0], armR: [0.5, 0, -0.9] }) },
    { t: 0.5, p: combine(S, { armL: [-0.8, 0, -0.6], foreL: [0, 0, 0], armR: [-1.6, 0, -1.2], foreR: [0, 0, 0], pos: [0, -0.1, 0.2], chest: [0.5, 0.4, 0] }), e: 'outExpo' },
    { t: 1, p: combine(S, { armL: [-0.8, 0, -0.6], foreL: [0, 0, 0], armR: [-1.6, 0, -1.2], foreR: [0, 0, 0], pos: [0, -0.1, 0.2], chest: [0.5, 0.4, 0] }) },
  ]),
  executeSlashB: clip(0.16, [
    { t: 0, p: combine(S, { armR: [-2.2, 0, -0.9], foreR: [-0.8, 0, 0], armL: [0.5, 0, 0.9] }) },
    { t: 0.5, p: combine(S, { armR: [-0.8, 0, 0.6], foreR: [0, 0, 0], armL: [-1.6, 0, 1.2], foreL: [0, 0, 0], pos: [0, -0.1, 0.2], chest: [0.5, -0.4, 0] }), e: 'outExpo' },
    { t: 1, p: combine(S, { armR: [-0.8, 0, 0.6], foreR: [0, 0, 0], armL: [-1.6, 0, 1.2], foreL: [0, 0, 0], pos: [0, -0.1, 0.2], chest: [0.5, -0.4, 0] }) },
  ]),
  executeFinish: clip(0.6, [
    { t: 0, p: { pos: [0, 0.3, 0], chest: [-0.4, 0, 0], armL: [-3.0, 0, 0.2], foreL: [-0.2, 0, 0], armR: [-3.0, 0, -0.2], foreR: [-0.2, 0, 0], legL: [-0.8, 0, 0], shinL: [1.4, 0, 0], legR: [0.2, 0, 0], shinR: [0.8, 0, 0] } },
    { t: 0.3, p: { pos: [0, -0.55, 0.25], chest: [0.9, 0, 0], armL: [-0.9, 0, -0.3], foreL: [0, 0, 0], armR: [-0.9, 0, 0.3], foreR: [0, 0, 0], legL: [-1.5, 0, 0.2], shinL: [2.0, 0, 0], legR: [0.3, 0, -0.2], shinR: [2.3, 0, 0], head: [-0.5, 0, 0] }, e: 'inExpo' },
    { t: 0.8, p: { pos: [0, -0.55, 0.25], chest: [0.85, 0, 0], armL: [-0.9, 0, -0.3], foreL: [0, 0, 0], armR: [-0.9, 0, 0.3], foreR: [0, 0, 0], legL: [-1.5, 0, 0.2], shinL: [2.0, 0, 0], legR: [0.3, 0, -0.2], shinR: [2.3, 0, 0], head: [-0.5, 0, 0] } },
    { t: 1, p: S },
  ]),
  realm: clip(1.0, [
    { t: 0, p: S },
    { t: 0.4, p: { pos: [0, 0.3, 0], chest: [-0.4, 0, 0], head: [-0.6, 0, 0], armL: [-2.8, 0, 0.8], foreL: [0, 0, 0], armR: [-2.8, 0, -0.8], foreR: [0, 0, 0], legL: [0.1, 0, 0.1], legR: [0.1, 0, -0.1], shinL: [0.3, 0, 0], shinR: [0.3, 0, 0] }, e: 'out' },
    { t: 0.65, p: { pos: [0, -0.3, 0], chest: [0.4, 0, 0], head: [-0.2, 0, 0], armL: [-1.3, 0, -0.7], foreL: [-1.3, 0, 0], armR: [-1.3, 0, 0.7], foreR: [-1.3, 0, 0], legL: [-1.0, 0, 0.3], shinL: [1.4, 0, 0], legR: [-0.4, 0, -0.3], shinR: [1.3, 0, 0] }, e: 'outExpo' },
    { t: 1, p: S },
  ]),
  realmFinisher: clip(0.8, [
    { t: 0, p: S },
    { t: 0.4, p: { pos: [0, -0.1, 0], chest: [0.1, 0, 0], head: [0.3, 0, 0], armL: [-0.2, 0, 0.3], foreL: [-1.9, 0, 0], armR: [-0.2, 0, -0.3], foreR: [-1.9, 0, 0], legL: [-0.2, 0, 0.1], legR: [0.1, 0, -0.1] }, e: 'out' },
    { t: 1, p: { pos: [0, -0.1, 0], chest: [0.1, 0, 0], head: [0.35, 0, 0], armL: [-0.2, 0, 0.3], foreL: [-1.9, 0, 0], armR: [-0.2, 0, -0.3], foreR: [-1.9, 0, 0], legL: [-0.2, 0, 0.1], legR: [0.1, 0, -0.1] } },
  ]),
};

// ================================================================= combo ==
const blade = (socket: 'handL' | 'handR', from: number, to: number) => ({ socket, color: 0xb070ff, from, to, width: 0.6 });

function slashFx(ctx: { attacker: Actor; world: World }, arcDeg: number, tilt = 0, radius = 2.2): void {
  const a = ctx.attacker;
  ctx.world.vfx.slash(a.position, a.facing, 0xb060ff, radius * a.scale, arcDeg, 0.2, tilt, 1.0 * a.scale, 0.55);
}

const combo = {
  resetTime: 0.5,
  ground: [
    { name: 'Shade Cut', anim: 'slashL', duration: 0.3, hits: [{ time: 0.11, range: 2.2, arc: 130, damage: 0.8, knockback: 2, hitstun: 0.3, stagger: 25, element: 'shadow' }], lunge: 1.1, lungeStart: 0, lungeEnd: 0.11, cancelTime: 0.16, swingSound: 'blade_swing', trail: [blade('handL', 0.02, 0.14)], onHitFrame: (ctx) => slashFx(ctx, 140, 0.2) },
    { name: 'Shade Cut', anim: 'slashR', duration: 0.3, hits: [{ time: 0.11, range: 2.2, arc: 130, damage: 0.8, knockback: 2, hitstun: 0.3, stagger: 25, element: 'shadow' }], lunge: 1.1, lungeStart: 0, lungeEnd: 0.11, cancelTime: 0.16, swingSound: 'blade_swing', trail: [blade('handR', 0.02, 0.14)], onHitFrame: (ctx) => slashFx(ctx, 140, -0.2) },
    { name: 'Whirling Edge', anim: 'spinSlash', duration: 0.4, hits: [
      { time: 0.13, range: 2.4, arc: 360, damage: 0.6, knockback: 1.5, hitstun: 0.3, stagger: 25, element: 'shadow' },
      { time: 0.27, range: 2.4, arc: 360, damage: 0.6, knockback: 3, hitstun: 0.3, stagger: 25, element: 'shadow' },
    ], cancelTime: 0.28, swingSound: 'blade_swing', trail: [blade('handL', 0.05, 0.3), blade('handR', 0.05, 0.3)], onHitFrame: (ctx) => slashFx(ctx, 360, 0, 2.4) },
    { name: 'Rising Fang', anim: 'risingSlash', duration: 0.42, hits: [{ time: 0.16, range: 2.3, arc: 100, damage: 1.1, knockback: 1, launch: 8, hitstun: 0.5, stagger: 45, element: 'shadow' }], lunge: 0.8, lungeStart: 0.02, lungeEnd: 0.16, cancelTime: 0.26, swingSound: 'blade_swing', trail: [blade('handR', 0.06, 0.22)], onHitFrame: (ctx) => slashFx(ctx, 120, 1.3) },
    { name: 'Nightfall Cross', anim: 'crossSlash', duration: 0.55, hits: [{ time: 0.27, range: 2.7, arc: 110, damage: 2.0, knockback: 9, hitstun: 0.5, stagger: 70, hitstop: 0.08, shake: 0.3, element: 'shadow', critBonus: 0.15 }], lunge: 1.4, lungeStart: 0.12, lungeEnd: 0.27, cancelTime: 0.4, swingSound: 'blade_swing', trail: [blade('handL', 0.15, 0.32), blade('handR', 0.15, 0.32)],
      onHitFrame(ctx) {
        const a = ctx.attacker;
        const p = a.position.clone().addScaledVector(a.forward(), 1.6).setY(a.position.y + 1.1 * a.scale);
        const side = new THREE.Vector3(-Math.cos(a.facing), 0, Math.sin(a.facing));
        const up = new THREE.Vector3(0, 1, 0);
        ctx.world.vfx.beam(p.clone().addScaledVector(side, 1.2).addScaledVector(up, 1), p.clone().addScaledVector(side, -1.2).addScaledVector(up, -1), 0xc080ff, 0.25, 0.3);
        ctx.world.vfx.beam(p.clone().addScaledVector(side, -1.2).addScaledVector(up, 1), p.clone().addScaledVector(side, 1.2).addScaledVector(up, -1), 0xc080ff, 0.25, 0.3);
        ShadowFX.puff(ctx.world.vfx, p, 0.5);
      } },
  ] as AttackStep[],
  air: {
    name: 'Night Wheel',
    anim: 'airSpin',
    duration: 0.45,
    hits: [
      { time: 0.14, range: 2.4, arc: 360, damage: 0.9, knockback: 2, hitstun: 0.35, stagger: 30, heightMin: -2.4, heightMax: 2, element: 'shadow' },
      { time: 0.32, range: 2.4, arc: 360, damage: 0.9, knockback: 5, hitstun: 0.35, stagger: 30, heightMin: -2.4, heightMax: 2, element: 'shadow' },
    ],
    cancelTime: 0.35,
    swingSound: 'blade_swing',
    trail: [blade('handL', 0.05, 0.4), blade('handR', 0.05, 0.4)],
    onStart(ctx) {
      ctx.attacker.velocity.y = Math.max(ctx.attacker.velocity.y, 3);
    },
  } as AttackStep,
};

// ============================================================ helpers ==
function isBehind(attacker: Actor, target: Actor): boolean {
  const f = target.forward();
  const to = attacker.position.clone().sub(target.position).setY(0).normalize();
  return f.dot(to) < -0.35;
}

let cloneDef: CharacterDefinition | null = null;

function spawnClone(w: World, owner: Actor, pos: THREE.Vector3, life: number, damageScale: number): Actor {
  if (!cloneDef) cloneDef = { ...Shadow, id: 'shadowClone', name: 'Shadow Clone', buildModel: buildCloneModel, hooks: { modifyOutgoing: Shadow.hooks.modifyOutgoing }, vfx: { ...Shadow.vfx, aura: undefined } };
  const c = new Actor(cloneDef, 'clone', 'player');
  c.stats.maxHealth = 160;
  c.health.max = 160;
  c.health.current = 160;
  c.owner = owner;
  c.position.copy(pos);
  c.facing = owner.facing;
  c.passThrough = true;
  c.controller = new CloneAI(owner, Shadow.combo.ground, damageScale, (clone, from, to, world) => {
    ShadowFX.puff(world.vfx, from.clone().setY(from.y + 1), 0.6);
    ShadowFX.puff(world.vfx, to.clone().setY(to.y + 1), 0.6);
    world.audio.play('shadow_blink', to, { volume: 0.5 });
  });
  w.addActor(c);
  ShadowFX.puff(w.vfx, pos.clone().setY(pos.y + 1), 1);
  c.effects.apply({
    id: 'cloneLife',
    duration: life,
    onExpire(t, e, world) {
      if (!t.alive || t.removed) return;
      ShadowFX.puff(world.vfx, t.center(), 1);
      world.removeActor(t);
    },
  }, w);
  return c;
}

// ============================================================= abilities ==
const shadowStep: AbilityDef = {
  id: 'shadowStep',
  name: 'Shadow Step',
  description: 'Melt into the shadows and reappear behind your target. Your next basic attack within 2.5s is a guaranteed critical hit.',
  cooldown: 5,
  damage: 0,
  anim: 'shadowStep',
  castInAir: true,
  tags: ['teleport', 'setup'],
  icon: { glyph: 'shadowStep', bg: ['#9a50ff', '#12041e'], fg: '#f0e0ff', glow: '#b070ff' },
  canCast(caster, world) {
    return enemiesByDistance(world, caster, 22).length > 0;
  },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const t = c.findTarget(22, 90) ?? enemiesByDistance(w, a, 22)[0];
    if (!t) return void c.end(0.05);
    const from = a.position.clone();
    const behind = t.position.clone().addScaledVector(t.forward(), -(t.radius + 1.1));
    const to = w.arena.safePoint(t.position, behind, a.radius);
    ShadowFX.puff(w.vfx, from.clone().setY(from.y + 1), 1.1);
    w.vfx.afterimage(a, 0x7a30d0, 0.4, 0.6);
    w.vfx.beam(from.clone().setY(from.y + 1), to.clone().setY(to.y + 1), 0x8040e0, 0.12, 0.25);
    a.position.copy(to);
    a.velocity.set(0, 0, 0);
    a.faceTowards(t.position);
    w.camera.alignTo(a.facing, 0.4);
    ShadowFX.puff(w.vfx, to.clone().setY(to.y + 1), 1.1);
    w.audio.play('shadow_blink', to);
    w.camera.kickFov(4);
    t.effects.apply(Effects.stun(0.35, 0xc080ff), w);
    a.effects.apply({ id: 'ambushReady', duration: 2.5, icon: 'mark' }, w);
    c.anim('shadowStep', { duration: 0.4 });
    c.invulnerable(0, 0.25);
    c.end(0.28);
  },
};

const darkBlades: AbilityDef = {
  id: 'darkBlades',
  name: 'Dark Blades',
  description: 'Fling a fan of five void blades that pierce through enemies. High critical chance.',
  cooldown: 4,
  damage: 38,
  anim: 'darkBlades',
  castInAir: true,
  tags: ['ranged', 'pierce'],
  icon: { glyph: 'blades', bg: ['#7a3ae0', '#0e0418'], fg: '#e8d0ff', glow: '#a060ff' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const aim = c.faceAim(30);
    c.anim('darkBlades', { duration: 0.5 });
    if (!a.grounded) a.noGravity = 0.4;
    for (let i = 0; i < 5; i++) {
      c.at(0.12 + i * 0.045, () => {
        const ang = (i - 2) * 0.14;
        const dir = aim.clone().applyAxisAngle(new THREE.Vector3(0, 1, 0), ang);
        const from = a.socketPos(i % 2 ? 'handL' : 'handR');
        const mesh = new THREE.Group();
        const bladeMesh = new THREE.Mesh(Geo.octa(0.35), new THREE.MeshBasicMaterial({ color: 0x9a50ff, transparent: true, opacity: 0.95, blending: THREE.AdditiveBlending, depthWrite: false }));
        bladeMesh.scale.set(1.6, 0.12, 0.5);
        const core = new THREE.Mesh(Geo.octa(0.2), new THREE.MeshBasicMaterial({ color: 0x1a0028 }));
        core.scale.set(1.8, 0.1, 0.4);
        mesh.add(bladeMesh, core);
        w.audio.play('blade_throw', from, { pitch: 0.9 + i * 0.05 });
        w.projectiles.spawn({
          owner: a,
          position: from,
          velocity: dir.multiplyScalar(42),
          radius: 0.45,
          lifetime: 0.8,
          pierce: 2,
          mesh,
          spin: new THREE.Vector3(0, 22, 0),
          onUpdate(p) {
            if (Math.random() < 0.6) ShadowFX.wisp(w.vfx, p.position, 1);
          },
          onHit(p, t) {
            w.combat.dealDamage(a, t, { amount: c.dmg(), element: 'shadow', knockback: 3, hitstun: 0.3, stagger: 30, isAbility: true, critBonus: 0.2, dir: p.velocity.clone().setY(0).normalize(), hitstop: 0.02 });
          },
          onImpact(p, pos) {
            ShadowFX.puff(w.vfx, pos, 0.35);
          },
          onExpire(p) {
            ShadowFX.puff(w.vfx, p.position, 0.3);
          },
        });
      });
    }
    c.end(0.42);
  },
};

const smokeVanish: AbilityDef = {
  id: 'smokeVanish',
  name: 'Smoke Vanish',
  description: 'Hurl a smoke bomb and vanish for 5s. Enemies lose track of you and those in the cloud are blinded. Your first strike from stealth deals double damage and always crits.',
  cooldown: 14,
  damage: 0,
  anim: 'smokeVanish',
  tags: ['stealth', 'escape'],
  icon: { glyph: 'smoke', bg: ['#5a4a70', '#0a0610'], fg: '#e0d8f0', glow: '#9a80c0' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    c.anim('smokeVanish', { duration: 0.4 });
    c.at(0.14, () => {
      const p = a.position.clone();
      w.audio.play('smoke', p);
      ShadowFX.puff(w.vfx, p.clone().setY(p.y + 0.8), 2.2);
      w.vfx.emit('smoke', p, 30, { speed: [2, 6], life: [1.5, 2.5], size: [2.5, 4], sizeEnd: 1.6, color: [0x3a3444, 0x2a2434, 0x4a4454], alpha: 0.75, drag: 2.2, disc: 2, gravity: -0.2 });
      w.zones.spawn({
        owner: a,
        position: p,
        radius: 6,
        height: 5,
        duration: 4,
        tickInterval: 0.3,
        harmful: true,
        onUpdate(z, dt) {
          if (Math.random() < dt * 14) w.vfx.emit('smoke', z.position, 1, { speed: [0.3, 1], life: [1.5, 2.2], size: [3, 4.5], sizeEnd: 1.3, color: [0x3a3444, 0x2e2838], alpha: 0.6 * z.fade, disc: 5, drag: 1, gravity: -0.1 });
          if (Math.random() < dt * 10) ShadowFX.wisp(w.vfx, z.position.clone().add(new THREE.Vector3(rand(-4, 4), rand(0.2, 2), rand(-4, 4))), 1);
        },
        onTick(z, targets) {
          for (const t of targets) {
            t.effects.apply({ id: 'blind', duration: 1.2, icon: 'blind', mods: { moveSpeed: 0.7, attackSpeed: 0.8 } }, w);
            t.userData.blindedBy = a;
          }
        },
      });
      a.effects.apply({
        id: 'stealth',
        duration: 5,
        icon: 'stealth',
        flags: { stealthed: true },
        mods: { moveSpeed: 1.3 },
        onUpdate(t, e, dt) {
          if (Math.random() < dt * 10) ShadowFX.wisp(w.vfx, t.center(), 1);
        },
        onExpire(t) {
          ShadowFX.puff(w.vfx, t.center(), 0.6);
        },
      }, w);
      a.iframes = Math.max(a.iframes, 0.4);
    });
    c.end(0.36);
  },
};

const shadowClone: AbilityDef = {
  id: 'shadowClone',
  name: 'Shadow Clone',
  description: 'Split off two shadow clones for 8s. They blink to enemies, slash with 45% of your damage and draw enemy attention.',
  cooldown: 15,
  damage: 0,
  anim: 'shadowClone',
  tags: ['summon', 'decoy'],
  icon: { glyph: 'clone', bg: ['#8a40f0', '#10041c'], fg: '#f0e0ff', glow: '#b070ff' },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    c.anim('shadowClone', { duration: 0.7 });
    c.at(0.3, () => {
      w.audio.play('clone', a.position);
      const right = new THREE.Vector3(-Math.cos(a.facing), 0, Math.sin(a.facing));
      for (const side of [1, -1]) {
        const p = w.arena.safePoint(a.position, a.position.clone().addScaledVector(right, side * 1.8), 0.5);
        spawnClone(w, a, p, 8, 0.45);
      }
    });
    c.end(0.6);
  },
};

const EXECUTE_THRESHOLD = 0.35;

const execution: AbilityDef = {
  id: 'execution',
  name: 'Execution',
  description: `Blink to a nearby enemy and unleash a six-strike flurry from every angle. Targets below ${EXECUTE_THRESHOLD * 100}% health are executed outright.`,
  cooldown: 10,
  damage: 36,
  anim: 'executeSlashA',
  tags: ['burst', 'execute'],
  icon: { glyph: 'execute', bg: ['#c040ff', '#1a0010'], fg: '#ffffff', glow: '#e080ff' },
  canCast(caster, world) {
    return enemiesByDistance(world, caster, 10).length > 0;
  },
  cast(c) {
    const a = c.caster;
    const w = c.world;
    const t = c.findTarget(10, 120) ?? enemiesByDistance(w, a, 10)[0];
    if (!t) return void c.end(0.05);
    c.uninterruptible = true;
    c.invulnerable(0, 1.4);
    const center = t.position.clone();
    const baseAng = yawFromDir(a.position.x - center.x, a.position.z - center.z);
    t.effects.apply(Effects.stun(1.25, 0xc080ff), w);
    w.audio.play('shadow_blink', a.position);
    const strikes = 6;
    for (let i = 0; i < strikes; i++) {
      c.at(0.05 + i * 0.13, () => {
        if (!t.alive && i > 0) return;
        const ang = baseAng + i * (TAU / strikes) * 1.37;
        const from = a.position.clone();
        const pos = w.arena.safePoint(t.position, t.position.clone().add(new THREE.Vector3(Math.sin(ang) * 1.4 * t.scale, 0, Math.cos(ang) * 1.4 * t.scale)), a.radius);
        w.vfx.afterimage(a, 0x8a3ae0, 0.35, 0.5);
        a.position.copy(pos);
        a.velocity.set(0, 0, 0);
        a.faceTowards(t.position);
        c.anim(i % 2 ? 'executeSlashB' : 'executeSlashA', { duration: 0.13 });
        const hitP = t.center();
        const dir = t.position.clone().sub(from).setY(0).normalize();
        ShadowFX.cut(w.vfx, hitP, dir, 2.2 * t.scale);
        w.audio.play('blade_hit', hitP, { pitch: 1 + i * 0.06 });
        if (t.alive) w.combat.dealDamage(a, t, { amount: c.dmg(), element: 'shadow', hitstun: 0.3, stagger: 30, isAbility: true, hitstop: 0.025, shake: 0.08, sound: null, noReaction: true });
      });
    }
    c.at(0.05 + strikes * 0.13 + 0.05, () => {
      if (!t.alive) return;
      c.anim('executeFinish', { duration: 0.6 });
      const behind = w.arena.safePoint(t.position, t.position.clone().addScaledVector(t.forward(), -(t.radius + 1)), a.radius);
      a.position.copy(behind);
      a.faceTowards(t.position);
    });
    c.at(0.05 + strikes * 0.13 + 0.2, () => {
      if (!t.alive) return;
      const p = t.center();
      const execute = t.health.ratio <= EXECUTE_THRESHOLD;
      if (execute) {
        w.slowMo(0.25, 0.5);
        w.ui.floatText(p.clone().setY(p.y + 1.5), 'EXECUTED', '#e080ff', 1.4);
        w.ui.screenFlash('#a040ff', 0.35, 0.3);
        w.combat.dealDamage(a, t, { amount: t.health.current * 4 + 300, element: 'shadow', knockback: 10, launch: 5, hitstun: 1, stagger: 300, isAbility: true, forceCrit: true, hitstop: 0.14, shake: 0.6, heavy: true, sound: 'execute', ignoreIFrames: true });
      } else {
        w.combat.dealDamage(a, t, { amount: c.dmg(95), element: 'shadow', knockback: 12, launch: 5, hitstun: 0.8, stagger: 200, isAbility: true, forceCrit: true, hitstop: 0.12, shake: 0.5, heavy: true, sound: 'execute' });
      }
      const side = new THREE.Vector3(-Math.cos(a.facing), 0, Math.sin(a.facing));
      w.vfx.beam(p.clone().addScaledVector(side, 2).setY(p.y + 1.5), p.clone().addScaledVector(side, -2).setY(p.y - 1), 0xe080ff, 0.35, 0.4);
      w.vfx.beam(p.clone().addScaledVector(side, 2).setY(p.y + 1.5), p.clone().addScaledVector(side, -2).setY(p.y - 1), 0xffffff, 0.1, 0.25);
      ShadowFX.puff(w.vfx, p, 1.5);
      w.vfx.flash(p, 0xa050ff, 40, 12, 0.3);
    });
    c.end(0.05 + strikes * 0.13 + 0.7);
  },
};

// ------------------------------------------------ Realm of Shadows ult ----
function realmOfShadows(): AbilityDef {
  return {
    id: 'realmOfShadows',
    name: 'Realm of Shadows',
    description: 'ULTIMATE — Drag nearby enemies into a dark realm for 8s. Shadow moves 80% faster, gains +30% crit and summons 4 clones. The realm ends in a cinematic assassination that shatters every trapped enemy.',
    cooldown: 0,
    damage: 260,
    ultimate: true,
    anim: 'realm',
    tags: ['ultimate', 'summon', 'execute'],
    icon: { glyph: 'realm', bg: ['#b050ff', '#05000a'], fg: '#ffffff', glow: '#d090ff' },
    cast(c) {
      const a = c.caster;
      const w = c.world;
      c.uninterruptible = true;
      c.invulnerable(0, 1.0);
      c.anim('realm', { duration: 1.0 });
      c.at(0, () => {
        w.ui.announce('REALM OF SHADOWS', undefined, '#d090ff');
        w.audio.play('realm', a.position);
        ShadowFX.puff(w.vfx, a.center(), 2);
      });
      c.during(0, 0.6, (dt, local, k) => {
        w.vfx.emit('dark', a.center(), 6, { speed: [2, 5], life: [0.6, 1], size: [1.5, 2.5], sizeEnd: 1.5, color: [0x140a1e, 0x0a0610], alpha: 0.8, ring: 8 - k * 6, radial: -8 });
      });
      c.at(0.6, () => openRealm(a, w, c.dmg()));
      c.end(1.0);
    },
  };
}

function openRealm(a: Actor, w: World, finisherDamage: number): void {
  const center = a.position.clone();
  const RADIUS = 26;
  const duration = 8;
  w.flags.realmActive = true;
  w.lighting.push('realm', { sunIntensity: 0.25, sunColor: new THREE.Color(0x8050c0), hemiIntensity: 0.7, hemiSky: new THREE.Color(0x6030a0), hemiGround: new THREE.Color(0x100418), fogColor: new THREE.Color(0x12051e), fogDensity: 0.02, skyTop: new THREE.Color(0x05000a), skyBottom: new THREE.Color(0x1a0630), exposure: 1.05 }, 60, 0.4, 1.0);
  w.ui.screenFlash('#6020a0', 0.6, 0.5);
  w.camera.addShake(0.5);
  w.lighting.flash(0.8, 0xa060ff);

  // Enemies outside are left behind in the normal world.
  const trapped: Actor[] = [];
  const outside: Actor[] = [];
  for (const e of w.aliveEnemies()) {
    if (distXZ(e.position, center) <= RADIUS + 4) trapped.push(e);
    else outside.push(e);
  }
  for (const e of outside) {
    e.hidden = true;
    e.root.visible = false;
    e.effects.apply({ id: 'outsideRealm', duration: 999, flags: { frozen: true, untargetable: true } }, w);
  }
  // Pull stragglers in.
  for (const e of trapped) {
    const d = distXZ(e.position, center);
    if (d > RADIUS * 0.7) {
      const to = center.clone().add(e.position.clone().sub(center).setY(0).normalize().multiplyScalar(rand(8, 14)));
      ShadowFX.puff(w.vfx, e.center(), 0.8);
      e.position.copy(w.arena.safePoint(center, to, e.radius));
      ShadowFX.puff(w.vfx, e.center(), 0.8);
    }
    e.effects.apply({ id: 'realmMark', duration: duration + 4, icon: 'mark' }, w);
    e.effects.apply(Effects.stun(0.6, 0xc080ff), w);
  }

  // Alternate arena: hide props, darken terrain, void dome + rune floor.
  w.arena.props.visible = false;
  w.arena.collidersEnabled = false;
  const terrainColor = w.arena.terrainMat.color.clone();
  w.arena.terrainMat.color.set(0x2a1a3a);
  const realm = new THREE.Group();
  const domeMat = w.vfx.animate(voidDomeMaterial());
  const dome = new THREE.Mesh(new THREE.SphereGeometry(RADIUS + 6, 40, 20), domeMat);
  dome.renderOrder = -1;
  realm.add(dome);
  const floorMat = new THREE.MeshBasicMaterial({ map: Textures.runes(), color: 0xa050ff, transparent: true, opacity: 0.8, blending: THREE.AdditiveBlending, depthWrite: false });
  const floor = new THREE.Mesh(new THREE.PlaneGeometry(RADIUS * 1.6, RADIUS * 1.6), floorMat);
  floor.rotation.x = -Math.PI / 2;
  floor.position.y = 0.15;
  realm.add(floor);
  const shardMat = new THREE.MeshStandardMaterial({ color: 0x1a0a2a, emissive: 0x5a1aa0, emissiveIntensity: 0.8, flatShading: true });
  const shards: THREE.Mesh[] = [];
  for (let i = 0; i < 18; i++) {
    const s = new THREE.Mesh(Geo.octa(rand(0.6, 1.8)), shardMat);
    const ang = (i / 18) * TAU;
    const r = rand(RADIUS * 0.75, RADIUS + 3);
    s.position.set(Math.cos(ang) * r, rand(2, 10), Math.sin(ang) * r);
    s.scale.y = rand(1.5, 3);
    s.userData.spin = rand(-1, 1);
    s.userData.bob = rand(0, TAU);
    realm.add(s);
    shards.push(s);
  }
  realm.position.copy(center);
  w.scene.add(realm);

  a.effects.apply({ id: 'realmHaste', duration, icon: 'realm', mods: { moveSpeed: 1.8, attackSpeed: 1.5, critChance: 0.3 } }, w);
  for (let i = 0; i < 4; i++) {
    const ang = (i / 4) * TAU;
    const p = w.arena.safePoint(a.position, a.position.clone().add(new THREE.Vector3(Math.cos(ang) * 2.5, 0, Math.sin(ang) * 2.5)), 0.5);
    spawnClone(w, a, p, duration, 0.5);
  }

  let t = 0;
  let phase: 'realm' | 'finale' | 'done' = 'realm';
  let finaleT = 0;
  const victims: Actor[] = [];
  let victimIdx = 0;
  let nextStrike = 0;
  const restore = () => {
    if (phase === 'done') return;
    phase = 'done';
    w.flags.realmActive = false;
    w.arena.props.visible = true;
    w.arena.collidersEnabled = true;
    w.arena.terrainMat.color.copy(terrainColor);
    w.lighting.release('realm');
    w.scene.remove(realm);
    w.vfx.release(domeMat);
    floorMat.dispose();
    for (const e of outside) {
      e.hidden = false;
      e.root.visible = true;
      e.effects.remove('outsideRealm', w, true);
    }
    if (a.state === 'cinematic') a.returnToLocomotion();
    a.effects.remove('realmFinale', w, true);
  };

  w.addTicker((dt) => {
    t += dt;
    if (phase === 'done') return true;
    if (!a.alive || a.removed) {
      restore();
      return true;
    }
    floor.rotation.z += dt * 0.25;
    for (const s of shards) {
      s.rotation.y += s.userData.spin * dt;
      s.position.y += Math.sin(t * 1.5 + s.userData.bob) * dt * 0.5;
    }
    if (Math.random() < dt * 30) {
      const ang = Math.random() * TAU;
      const r = Math.sqrt(Math.random()) * RADIUS;
      ShadowFX.wisp(w.vfx, center.clone().add(new THREE.Vector3(Math.cos(ang) * r, rand(0, 1), Math.sin(ang) * r)), 1);
    }
    if (phase === 'realm') {
      // Keep trapped enemies inside the realm.
      for (const e of trapped) {
        if (!e.alive) continue;
        const d = e.position.clone().sub(center).setY(0);
        if (d.length() > RADIUS - 1) e.position.copy(center.clone().add(d.setLength(RADIUS - 1)).setY(e.position.y));
      }
      if (t >= duration) {
        phase = 'finale';
        finaleT = 0;
        victims.push(...trapped.filter((e) => e.alive).slice(0, 10));
        if (!victims.length) {
          // Nothing left to assassinate: simply collapse the realm.
          w.audio.play('shatter', center);
          w.vfx.sphere(center.clone().setY(center.y + 1), 0xa050ff, RADIUS, 0.6, 0.4);
          restore();
          return true;
        }
        a.interruptActions(w);
        a.setState('cinematic');
        a.anim.play('realm', { restart: true, duration: 0.4 });
        a.effects.apply({ id: 'realmFinale', duration: 12, flags: { invulnerable: true } }, w);
        w.slowMo(0.3, 3);
        w.audio.play('realm', a.position, { pitch: 1.4 });
        const yaw0 = w.camera.yaw;
        w.camera.playCinematic({
          duration: 3,
          sample(ct, pos, look) {
            const ang = yaw0 + ct * 0.6;
            pos.set(center.x + Math.sin(ang) * 16, center.y + 7 - ct, center.z + Math.cos(ang) * 16);
            look.set(center.x, center.y + 1, center.z);
          },
        });
        for (const e of victims) e.effects.apply(Effects.stun(3, 0xc080ff), w);
      }
      return false;
    }
    // ---------------- finale: cinematic assassination --------------------
    finaleT += dt;
    if (victimIdx < victims.length && finaleT >= nextStrike) {
      const e = victims[victimIdx++];
      nextStrike = finaleT + 0.1;
      if (e.alive) {
        const from = a.position.clone();
        const ang = Math.random() * TAU;
        const to = e.position.clone().add(new THREE.Vector3(Math.sin(ang) * 1.3, 0, Math.cos(ang) * 1.3));
        w.vfx.beam(from.clone().setY(from.y + 1), to.clone().setY(to.y + 1), 0xa050ff, 0.2, 0.6);
        w.vfx.afterimage(a, 0x8a3ae0, 0.8, 0.6);
        a.position.copy(to);
        a.faceTowards(e.position);
        a.anim.play(victimIdx % 2 ? 'executeSlashA' : 'executeSlashB', { restart: true, duration: 0.08, fade: 0 });
        ShadowFX.cut(w.vfx, e.center(), e.position.clone().sub(from).setY(0).normalize(), 2.6);
        w.audio.play('blade_hit', e.position, { pitch: 1.2 });
      }
    }
    if (victimIdx >= victims.length && !a.userData.realmReturned && finaleT >= nextStrike + 0.05) {
      a.userData.realmReturned = true;
      ShadowFX.puff(w.vfx, a.center(), 1);
      a.position.copy(w.arena.safePoint(center, center, 0.5));
      a.anim.play('realmFinisher', { restart: true, duration: 0.25 });
      a.userData.finisherAt = finaleT + 0.2;
    }
    if (a.userData.realmReturned && finaleT >= (a.userData.finisherAt ?? 0)) {
      a.userData.realmReturned = false;
      a.userData.finisherAt = undefined;
      // Shatter.
      w.slowMo(1, 0);
      w.hitStop(0.1);
      w.audio.play('shatter', center);
      w.audio.play('execute', center);
      w.ui.screenFlash('#e0c0ff', 0.8, 0.5);
      w.lighting.flash(2, 0xd0a0ff);
      w.camera.stopCinematic();
      w.camera.addShake(0.9);
      for (const e of victims) {
        if (!e.alive) continue;
        const execute = e.health.ratio <= 0.4;
        w.combat.dealDamage(a, e, { amount: execute ? e.health.current * 4 + 300 : finisherDamage, element: 'shadow', knockback: 12, launch: 8, hitstun: 1, stagger: 300, isAbility: true, forceCrit: true, hitstop: 0, shake: 0, heavy: true, ignoreIFrames: true, ultGain: 0 });
        ShadowFX.puff(w.vfx, e.center(), 1.2);
        const side = new THREE.Vector3(rand(-1, 1), 0, rand(-1, 1)).normalize();
        const p = e.center();
        w.vfx.beam(p.clone().addScaledVector(side, 2.5).setY(p.y + 1.6), p.clone().addScaledVector(side, -2.5).setY(p.y - 1.2), 0xe0b0ff, 0.3, 0.5);
      }
      // Realm shards burst outward.
      for (const s of shards) w.vfx.spawnDebris(realm.position.clone().add(s.position), 2, 0x3a1a5a, { force: 14, size: 0.5, up: 10 });
      w.vfx.sphere(center.clone().setY(center.y + 1), 0xa050ff, RADIUS, 0.6, 0.5);
      w.vfx.ring(center, 0xc080ff, RADIUS + 6, 0.8);
      restore();
      return true;
    }
    if (finaleT > 6) {
      restore();
      return true;
    }
    return false;
  });
}

// ================================================================ define ==
export const Shadow: CharacterDefinition = {
  id: 'shadow',
  name: 'Shadow',
  title: 'The Unseen Blade',
  role: 'Assassin',
  description: 'A void-touched assassin who strikes from where you are not looking. Shadow teleports, vanishes and deletes weakened targets before they know the fight has started.',
  playstyle: 'Pick a victim, Shadow Step behind it and open with a guaranteed crit. Attacks from behind always crit for 250%. Use Smoke Vanish and clones to lose pursuers, then Execute anything below 35% health. Extremely fragile if caught.',
  difficulty: 3,
  element: 'shadow',
  theme: { primary: '#a050ff', secondary: '#e0c8ff', glow: '#c080ff', dark: '#0a0412' },
  stats,
  buildModel,
  animations,
  combo,
  abilities: [shadowStep, darkBlades, smokeVanish, shadowClone, execution, realmOfShadows()],
  passive: {
    name: 'Assassin’s Mark',
    description: 'Attacks from behind are guaranteed critical hits (250% damage). The first hit from stealth or after Shadow Step deals double damage and always crits. Shadow can double-jump.',
  },
  hooks: {
    modifyOutgoing(self, target, spec, world) {
      if (isBehind(self, target)) {
        spec.forceCrit = true;
        self.userData.backstab = true;
      }
      if (self.effects.has('stealth')) {
        spec.amount *= 2;
        spec.forceCrit = true;
        self.userData.ambush = true;
      }
      if (self.effects.has('ambushReady') && !spec.isAbility) {
        spec.forceCrit = true;
        spec.amount *= 1.5;
        self.userData.ambush = true;
      }
    },
    onDealDamage(self, target, result, spec, world) {
      const owner = self.owner ?? self;
      if (self.userData.ambush) {
        self.userData.ambush = false;
        world.ui.floatText(result.position.clone().setY(result.position.y + 1), 'AMBUSH', '#e0a0ff', 1);
        if (self.effects.has('stealth')) self.effects.remove('stealth', world);
        self.effects.remove('ambushReady', world, true);
      } else if (self.userData.backstab && result.crit && self.kind === 'player') {
        world.ui.floatText(result.position.clone().setY(result.position.y + 0.9), 'BACKSTAB', '#c080ff', 0.8);
      }
      self.userData.backstab = false;
      void owner;
    },
    onSpawn(self) {
      self.onDodgeFrame = (a, t, w) => {
        a.targetOpacity = t > 0.1 && t < 0.9 ? 0.02 : 1;
        if (Math.random() < 0.7) ShadowFX.wisp(w.vfx, a.center(), 2);
      };
    },
    onUpdate(self, dt) {
      // Cape + scarf sway from movement.
      const speed = Math.hypot(self.velocity.x, self.velocity.z);
      const cape = self.rig.extras.cape;
      const scarf = self.rig.extras.scarf;
      const t = self.worldTime;
      if (cape) cape.rotation.x = Math.min(1.2, speed * 0.07) + Math.sin(t * 3) * 0.04 + (self.grounded ? 0 : 0.4);
      if (scarf) scarf.rotation.x = Math.min(1.3, speed * 0.09) + Math.sin(t * 5) * 0.08 + 0.2;
    },
  },
  vfx: {
    hit(world, pos, dir, strength, crit) {
      ShadowFX.cut(world.vfx, pos, dir, 1.2 + strength);
      GenericFX.impact(world.vfx, pos, 0xb070ff, strength);
      if (crit) {
        ShadowFX.puff(world.vfx, pos, 0.4);
        world.vfx.flash(pos, 0xa050ff, 15, 8, 0.15);
      }
    },
    dodge(world, actor) {
      ShadowFX.puff(world.vfx, actor.center(), 0.9);
      world.vfx.afterimage(actor, 0x6a20c0, 0.4, 0.5);
    },
    land(world, actor, s) {
      EarthFX.dust(world.vfx, actor.position, 0.5 + s, Math.round(2 + s * 4));
      ShadowFX.wisp(world.vfx, actor.position, 2);
    },
    death(world, actor) {
      ShadowFX.puff(world.vfx, actor.center(), 2);
    },
    aura(world, actor, dt) {
      if (Math.random() < dt * 4) ShadowFX.wisp(world.vfx, actor.socketPos(Math.random() < 0.5 ? 'bladeL' : 'bladeR'), 1);
    },
  },
  sounds: {
    swing: 'blade_swing',
    heavySwing: 'blade_swing',
    hit: 'blade_hit',
    heavyHit: 'execute',
    dodge: 'shadow_blink',
    jump: 'jump',
    land: 'land',
    hurt: 'hurt',
    death: 'death',
    footstep: 'footstep',
  },
  threat: { mobility: 0.85, range: 0.45, durability: 0.2, stealth: 1.0, area: 0.35 },
  camera: { distance: 6.0, height: 1.45, shoulder: 0.55, fov: 64 },
  portrait: { glyph: 'realm', bg: ['#a050ff', '#0a0412'], fg: '#ffffff' },
  ratings: { power: 9, speed: 8, defense: 2, range: 5, control: 6 },
};

