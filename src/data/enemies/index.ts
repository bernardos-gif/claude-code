import * as THREE from 'three';
import type { AIProfile, CharacterSounds, CharacterStats, CharacterVFX, EnemyAttack, EnemyDefinition } from '../types';
import { RigBuilder, Geo, stdMat, basicGlow, glowMat, Rig } from '../../characters/Rig';
import { AnimationSet, PoseSpec, clip, combine, gaitClip, idleClip } from '../../characters/AnimationClip';
import { EarthFX, GenericFX } from '../../vfx/ElementFX';
import { LYING_BACK, LYING_FACE } from '../characters/kit';

/**
 * Enemy roster: Ravager (melee fighter), Hexcaster (ranged) and Juggernaut
 * (heavy). Each defines its tactics plus per-character overrides so the AI
 * fights Titan, Volt, Blaze and Shadow differently.
 */

const RED = 0xff3040;

const enemySounds: CharacterSounds = {
  swing: 'enemy_swing',
  heavySwing: 'heavy_whoosh',
  hit: 'enemy_hit',
  heavyHit: 'punch_heavy',
  dodge: 'dodge_roll',
  jump: 'jump',
  land: 'land',
  hurt: 'hurt',
  death: 'enemy_death',
  footstep: 'footstep',
};

function enemyVfx(color: number): CharacterVFX {
  return {
    hit(world, pos, dir, strength) {
      GenericFX.impact(world.vfx, pos, color, strength);
      world.vfx.emit('dark', pos, 3, { speed: [1, 3], dir, spread: 0.5, life: 0.4, size: 0.5, sizeEnd: 1.5, color: 0x200808, alpha: 0.5 });
    },
    dodge(world, actor) {
      EarthFX.dust(world.vfx, actor.position, 0.8, 5);
    },
    land(world, actor, s) {
      EarthFX.dust(world.vfx, actor.position, 0.6 + s, Math.round(3 + s * 5));
    },
    death(world, actor) {
      const p = actor.center();
      world.vfx.emit('dark', p, 20, { speed: [1, 4], life: [0.8, 1.4], size: [0.8, 1.4], sizeEnd: 1.8, color: [0x1a0606, 0x2a0a0a], alpha: 0.7, gravity: -1, jitter: 0.4, jitterY: 0.8 });
      world.vfx.emit('glow', p, 14, { speed: [2, 6], life: [0.3, 0.6], size: [0.3, 0.5], color: RED, colorEnd: 0x400000 });
    },
  };
}

// ============================================================== FIGHTER ===
function fighterModel(): Rig {
  const b = new RigBuilder({
    hipHeight: 0.92,
    torso: 0.6,
    shoulderWidth: 0.25,
    hipWidth: 0.1,
    chestWidth: 0.26,
    chestDepth: 0.18,
    waistWidth: 0.17,
    upperArm: 0.3,
    foreArm: 0.28,
    armRadius: 0.07,
    foreArmRadius: 0.062,
    thighRadius: 0.088,
    shinRadius: 0.076,
    handSize: 0.11,
    footLength: 0.27,
    neck: 0.07,
    headRadius: 0.12,
    colors: { skin: 0x6a5a54, torso: 0x5a5e6a, arms: 0x44474f, legs: 0x3e4048, boots: 0x26262c, gloves: 0x5a5e6a, accent: RED, belt: 0x7a2228 },
    roughness: 0.5,
    metalness: 0.3,
  });
  const r = b.rig;
  const steel = stdMat(0x8a8e98, { metalness: 0.55, roughness: 0.35 });
  const dark = stdMat(0x2e3036, { metalness: 0.4, roughness: 0.45 });
  // Helmet with glowing visor slit.
  b.attach(r.bones.head, new THREE.SphereGeometry(0.14, 12, 10, 0, Math.PI * 2, 0, Math.PI * 0.62), steel, [0, 0.11, 0]);
  b.attach(r.bones.head, Geo.box(0.2, 0.1, 0.06), dark, [0, 0.07, 0.1]);
  b.attach(r.bones.head, Geo.box(0.15, 0.02, 0.02), basicGlow(RED), [0, 0.1, 0.132]);
  b.attach(r.bones.head, Geo.cone(0.03, 0.18, 4), stdMat(0x8a1a20), [0, 0.28, -0.02], [-0.3, 0, 0]);
  // Pauldrons + chest plate.
  for (const [bone, side] of [
    [r.bones.armL, 1],
    [r.bones.armR, -1],
  ] as const) b.attach(bone, Geo.box(0.16, 0.08, 0.18), steel, [side * 0.03, 0.02, 0], [0, 0, side * 0.35]);
  b.attach(r.bones.chest, Geo.box(0.34, 0.26, 0.06), steel, [0, 0.3, 0.16], [0.18, 0, 0]);
  b.attach(r.bones.chest, Geo.box(0.04, 0.2, 0.02), basicGlow(RED), [0, 0.3, 0.195], [0.18, 0, 0]);
  // Tabard.
  b.attach(r.bones.hips, Geo.box(0.2, 0.34, 0.02), stdMat(0x5a1a1e, { roughness: 0.9, side: THREE.DoubleSide }), [0, -0.16, 0.18]);
  // Curved sword.
  const sword = new THREE.Group();
  sword.position.set(0, -0.06, 0.02);
  sword.rotation.x = -Math.PI / 2;
  r.bones.handR.add(sword);
  b.attach(sword, Geo.cyl(0.02, 0.02, 0.18, 6), dark, [0, 0.02, 0]);
  b.attach(sword, Geo.box(0.16, 0.03, 0.05), steel, [0, -0.08, 0]);
  const blade = b.attach(sword, Geo.box(0.025, 0.85, 0.08), steel, [0, -0.52, 0.015], [0.08, 0, 0]);
  blade.castShadow = true;
  b.attach(sword, Geo.box(0.012, 0.8, 0.012), basicGlow(0xff5060), [0, -0.52, 0.06], [0.08, 0, 0]);
  const tip = new THREE.Object3D();
  tip.position.set(0, -0.95, 0.05);
  sword.add(tip);
  r.sockets.weapon = tip;
  // Buckler on left forearm.
  b.attach(r.bones.foreL, Geo.cyl(0.17, 0.17, 0.04, 14), steel, [0.07, -0.16, 0], [0, 0, Math.PI / 2]);
  b.attach(r.bones.foreL, Geo.sphere(0.04, 8, 6), basicGlow(RED), [0.1, -0.16, 0]);
  return r;
}

const F: PoseSpec = {
  pos: [0, -0.1, 0],
  hips: [0, 0.2, 0],
  chest: [0.15, -0.2, 0],
  head: [0, 0.15, 0],
  armR: [-0.7, 0, -0.25],
  foreR: [-0.9, 0, 0],
  armL: [-0.9, 0, 0.35],
  foreL: [-1.4, 0, 0],
  legL: [-0.45, 0, 0.1],
  shinL: [0.5, 0, 0],
  legR: [0.25, 0, -0.1],
  shinR: [0.45, 0, 0],
};

const fighterAnims: AnimationSet = {
  idle: idleClip({ base: F, breathe: 0.05, crouch: 0, speed: 0.9 }),
  walk: gaitClip(1.0, { stride: 0.5, knee: 0.6, armSwing: 0.1, elbow: -1.1, armOut: 0.3, armFwd: 0.8, bounce: 0.03, crouch: 0.08, lean: 0.12, sway: 0.05, twist: 0.1, headStabilize: 0.8 }),
  run: gaitClip(0.62, { stride: 0.9, knee: 1.3, armSwing: 0.6, elbow: -1.0, armOut: 0.15, bounce: 0.06, crouch: 0.08, lean: 0.35, sway: 0.04, twist: 0.3, headStabilize: 0.8 }),
  jump: clip(0.4, [{ t: 0, p: combine(F, { pos: [0, -0.2, 0] }) }, { t: 1, p: { armL: [-1.0, 0, 0.5], armR: [-1.0, 0, -0.5], legL: [-1.0, 0, 0], shinL: [1.4, 0, 0], legR: [-0.3, 0, 0], shinR: [0.9, 0, 0] }, e: 'out' }]),
  fall: clip(1, [{ t: 0, p: { armL: [-0.6, 0, 0.8], armR: [-0.6, 0, -0.8], legL: [-0.4, 0, 0], shinL: [0.6, 0, 0], legR: [0, 0, 0], shinR: [0.4, 0, 0] } }], true),
  land: clip(0.3, [{ t: 0, p: { pos: [0, -0.3, 0], chest: [0.4, 0, 0], legL: [-0.8, 0, 0.1], shinL: [1.3, 0, 0], legR: [-0.6, 0, -0.1], shinR: [1.2, 0, 0], armL: [-0.4, 0, 0.5], armR: [-0.4, 0, -0.5] } }, { t: 1, p: F }]),
  dodge: clip(0.4, [
    { t: 0, p: F },
    { t: 0.3, p: { root: [0.4, 0, 0.35], pos: [0, -0.35, 0], chest: [0.4, 0, 0], armL: [-1.2, 0, 0.2], foreL: [-1.6, 0, 0], armR: [-0.4, 0, -0.5], legL: [-1.0, 0, 0.3], shinL: [1.5, 0, 0], legR: [0.4, 0, -0.3], shinR: [0.9, 0, 0] } },
    { t: 1, p: F },
  ]),
  hit: clip(0.35, [{ t: 0, p: F }, { t: 0.25, p: combine(F, { chest: [-0.5, 0.3, 0], head: [-0.5, 0.2, 0], armR: [0.3, 0, -0.5], armL: [0.3, 0, 0.6], pos: [0, 0, -0.08] }), e: 'outExpo' }, { t: 1, p: F }]),
  stunned: clip(1.2, [{ t: 0, p: combine(F, { chest: [0.4, 0.2, 0.1], head: [0.5, 0.3, 0.2], armR: [0.2, 0, -0.3], armL: [0.2, 0, 0.3], foreL: [-0.3, 0, 0], foreR: [-0.3, 0, 0] }) }, { t: 0.5, p: combine(F, { chest: [0.4, -0.2, -0.1], head: [0.5, -0.3, -0.2], armR: [0.2, 0, -0.3], armL: [0.2, 0, 0.3], foreL: [-0.3, 0, 0], foreR: [-0.3, 0, 0] }) }], true),
  knockback: clip(0.7, [{ t: 0, p: { chest: [-0.5, 0, 0], armL: [-2.2, 0, 0.8], armR: [-2.2, 0, -0.8], legL: [-0.8, 0, 0], legR: [-0.3, 0, 0] } }, { t: 0.5, p: { root: [-0.9, 0.4, 0], armL: [-1.8, 0, 1.2], armR: [-2.6, 0, -1.0], legL: [-1.0, 0, 0.2], shinL: [1.0, 0, 0] } }, { t: 0.8, p: LYING_BACK, e: 'out' }, { t: 1, p: LYING_BACK }]),
  getup: clip(0.9, [{ t: 0, p: LYING_BACK }, { t: 0.4, p: { root: [-0.8, 0, 0], pos: [0, 0.1, 0], chest: [0.6, 0, 0], armL: [0.6, 0, 0.3], armR: [0.6, 0, -0.3], legL: [-1.5, 0, 0], shinL: [2.0, 0, 0], legR: [-0.4, 0, 0], shinR: [0.6, 0, 0] } }, { t: 0.7, p: { pos: [0, -0.45, 0], chest: [0.6, 0, 0], legL: [-1.4, 0, 0], shinL: [1.9, 0, 0], legR: [0.2, 0, 0], shinR: [2.1, 0, 0] } }, { t: 1, p: F }]),
  death: clip(1.2, [{ t: 0, p: combine(F, { chest: [-0.6, 0, 0], head: [-0.7, 0, 0] }) }, { t: 0.3, p: { pos: [0, -0.4, 0], chest: [-0.2, 0, 0], legL: [-1.2, 0, 0], shinL: [1.6, 0, 0], legR: [0.2, 0, 0], shinR: [2.0, 0, 0], armL: [0.2, 0, 0.4], armR: [0.3, 0, -0.4] } }, { t: 0.7, p: LYING_BACK, e: 'in' }, { t: 1, p: LYING_BACK }]),
  spawn: clip(1.1, [{ t: 0, p: combine(F, { pos: [0, -1.9, 0], chest: [0.8, 0, 0], head: [0.6, 0, 0] }) }, { t: 0.7, p: combine(F, { pos: [0, -0.3, 0], chest: [0.5, 0, 0] }), e: 'out' }, { t: 1, p: F }]),
  fSlash: clip(1.0, [
    { t: 0, p: F },
    { t: 0.45, p: combine(F, { armR: [-2.2, 0, -0.9], foreR: [-1.4, 0, 0], chest: [-0.1, -0.6, 0], hips: [0, -0.3, 0], pos: [0, 0.05, -0.05] }) },
    { t: 0.56, p: combine(F, { armR: [-0.9, 0, 0.6], foreR: [-0.2, 0, 0], chest: [0.35, 0.7, 0], hips: [0, 0.3, 0], pos: [0, -0.1, 0.15], legL: [-0.8, 0, 0.1], shinL: [0.8, 0, 0] }), e: 'outExpo' },
    { t: 0.8, p: combine(F, { armR: [-0.85, 0, 0.6], foreR: [-0.2, 0, 0], chest: [0.3, 0.65, 0], pos: [0, -0.1, 0.15] }) },
    { t: 1, p: F },
  ]),
  fCombo: clip(1.4, [
    { t: 0, p: F },
    { t: 0.3, p: combine(F, { armR: [-2.0, 0, -0.9], foreR: [-1.2, 0, 0], chest: [0, -0.5, 0] }) },
    { t: 0.38, p: combine(F, { armR: [-0.9, 0, 0.6], foreR: [-0.2, 0, 0], chest: [0.3, 0.6, 0], pos: [0, -0.1, 0.1] }), e: 'outExpo' },
    { t: 0.52, p: combine(F, { armR: [-1.9, 0, 0.9], foreR: [-1.0, 0, 0], chest: [0, 0.6, 0] }) },
    { t: 0.62, p: combine(F, { armR: [-0.9, 0, -0.9], foreR: [-0.2, 0, 0], chest: [0.3, -0.6, 0], pos: [0, -0.1, 0.15] }), e: 'outExpo' },
    { t: 0.85, p: combine(F, { armR: [-0.9, 0, -0.85], foreR: [-0.2, 0, 0], chest: [0.3, -0.55, 0] }) },
    { t: 1, p: F },
  ]),
  fLunge: clip(1.1, [
    { t: 0, p: F },
    { t: 0.3, p: combine(F, { pos: [0, -0.25, -0.05], armR: [0.4, 0, -0.3], foreR: [-1.2, 0, 0], chest: [0.3, -0.5, 0] }) },
    { t: 0.52, p: { pos: [0, -0.2, 0.3], root: [0.3, 0, 0], chest: [0.2, 0.3, 0], armR: [-1.6, 0, 0], foreR: [0, 0, 0], armL: [0.5, 0, 0.4], legL: [-1.1, 0, 0], shinL: [0.9, 0, 0], legR: [0.9, 0, 0], shinR: [0.3, 0, 0] }, e: 'outExpo' },
    { t: 0.8, p: { pos: [0, -0.2, 0.3], root: [0.25, 0, 0], chest: [0.2, 0.3, 0], armR: [-1.55, 0, 0], foreR: [0, 0, 0], armL: [0.5, 0, 0.4], legL: [-1.1, 0, 0], shinL: [0.9, 0, 0], legR: [0.9, 0, 0], shinR: [0.3, 0, 0] } },
    { t: 1, p: F },
  ]),
};

const fighterStats: CharacterStats = {
  maxHealth: 150, moveSpeed: 7.2, walkSpeed: 2.8, acceleration: 14, turnSpeed: 9, attackDamage: 20, defense: 12, attackSpeed: 1,
  dodgeDistance: 5, dodgeDuration: 0.35, dodgeCooldown: 2.2, dodgeIFrames: 0.2, abilityPower: 1, cooldownMultiplier: 1, critChance: 0.05, critMultiplier: 1.5,
  jumpVelocity: 10, airJumps: 0, gravityScale: 1, poise: 10, mass: 1, scale: 1, ultChargeRate: 0,
};

const fighterAttacks: EnemyAttack[] = [
  { name: 'Slash', anim: 'fSlash', duration: 1.0, hits: [{ time: 0.53, range: 2.3, arc: 110, damage: 1.0, knockback: 4, hitstun: 0.35, stagger: 40 }], cancelTime: 0.9, swingSound: 'enemy_swing', trail: [{ socket: 'weapon', color: 0xff4050, from: 0.45, to: 0.62, width: 0.5 }], minRange: 0, maxRange: 2.6, weight: 3, lunge: 0.6, lungeStart: 0.45, lungeEnd: 0.55 },
  { name: 'Double Cut', anim: 'fCombo', duration: 1.4, hits: [{ time: 0.52, range: 2.3, arc: 110, damage: 0.8, knockback: 2, hitstun: 0.3, stagger: 35 }, { time: 0.86, range: 2.3, arc: 110, damage: 0.9, knockback: 5, hitstun: 0.35, stagger: 40 }], cancelTime: 1.3, swingSound: 'enemy_swing', trail: [{ socket: 'weapon', color: 0xff4050, from: 0.4, to: 0.95, width: 0.5 }], minRange: 0, maxRange: 2.5, weight: 2, lunge: 0.9, lungeStart: 0.4, lungeEnd: 0.9 },
  { name: 'Lunge', anim: 'fLunge', duration: 1.1, hits: [{ time: 0.58, range: 2.2, arc: 70, damage: 1.25, knockback: 7, hitstun: 0.4, stagger: 50 }], cancelTime: 1.0, swingSound: 'enemy_swing', trail: [{ socket: 'weapon', color: 0xff4050, from: 0.45, to: 0.65, width: 0.4 }], minRange: 2.4, maxRange: 6.5, weight: 2, lunge: 4.2, lungeStart: 0.35, lungeEnd: 0.6 },
];

const fighterAI: AIProfile = { preferredRange: 2.0, attackRange: 2.5, retreatRange: 0, aggression: 0.7, attackCooldown: 1.7, strafe: 0.6, turnRate: 1, evasion: 0.15, avoidHazards: true, memory: 3, fleeSpeed: 1, panic: 0 };

export const FighterEnemy: EnemyDefinition = {
  id: 'fighter',
  name: 'Ravager',
  stats: fighterStats,
  buildModel: fighterModel,
  animations: fighterAnims,
  attacks: fighterAttacks,
  ai: fighterAI,
  vsCharacter: {
    // Titan is slow: keep out of reach and punish his long recoveries.
    titan: { preferredRange: 4.0, aggression: 0.45, strafe: 0.9, attackCooldown: 1.2 },
    // Volt is too quick to react to; fighters just swarm.
    volt: { evasion: 0.03, aggression: 0.85, strafe: 0.3 },
    // Shadow backstabs: turn much faster to guard the back.
    shadow: { turnRate: 2.4, memory: 1.5, strafe: 0.4 },
    // Blaze leaves fire everywhere: spread out and circle.
    blaze: { strafe: 0.85, preferredRange: 2.6 },
  },
  sounds: enemySounds,
  vfx: enemyVfx(RED),
  score: 100,
  healthBarOffset: 2.25,
};

// =============================================================== RANGED ===
function casterModel(): Rig {
  const b = new RigBuilder({
    hipHeight: 0.9,
    torso: 0.58,
    shoulderWidth: 0.2,
    hipWidth: 0.09,
    chestWidth: 0.21,
    chestDepth: 0.15,
    waistWidth: 0.14,
    upperArm: 0.29,
    foreArm: 0.28,
    armRadius: 0.055,
    foreArmRadius: 0.05,
    thighRadius: 0.075,
    shinRadius: 0.06,
    handSize: 0.09,
    footLength: 0.24,
    neck: 0.08,
    headRadius: 0.115,
    colors: { skin: 0x5a4a50, torso: 0x5a1e32, arms: 0x5a1e32, legs: 0x3a1422, boots: 0x201014, gloves: 0x3a1a24, accent: 0xff5070, belt: 0x8a3a4a },
    roughness: 0.85,
  });
  const r = b.rig;
  const robe = stdMat(0x5a1e32, { roughness: 0.9, side: THREE.DoubleSide });
  // Robe skirt.
  b.attach(r.bones.hips, Geo.cyl(0.16, 0.34, 0.75, 10), robe, [0, -0.36, 0]);
  // Hood.
  b.attach(r.bones.head, new THREE.SphereGeometry(0.14, 12, 10, 0, Math.PI * 2, 0, Math.PI * 0.65), robe, [0, 0.12, -0.015], [-0.2, 0, 0]);
  b.attach(r.bones.head, Geo.cone(0.06, 0.22, 5), robe, [0, 0.28, -0.1], [-1.0, 0, 0]);
  b.attach(r.bones.head, Geo.box(0.16, 0.07, 0.05), stdMat(0x0a0608), [0, 0.06, 0.08]);
  b.eyes(0xff5070, 0.02, 0.04, 0.03, 'round');
  // Floating runes on the chest.
  b.attach(r.bones.chest, Geo.octa(0.05), basicGlow(0xff5070), [0, 0.28, 0.17]);
  // Staff with orb.
  const staff = new THREE.Group();
  staff.position.set(0, -0.05, 0.02);
  r.bones.handR.add(staff);
  b.attach(staff, Geo.cyl(0.022, 0.026, 1.7, 6), stdMat(0x3a2418, { roughness: 0.8 }), [0, 0.15, 0]);
  b.attach(staff, Geo.torus(0.1, 0.02, 6, 12), stdMat(0x8a6a3a, { metalness: 0.7, roughness: 0.3 }), [0, 1.0, 0]);
  b.attach(staff, Geo.sphere(0.09, 12, 10), glowMat(0xff3050, 2.2), [0, 1.0, 0]);
  const orb = new THREE.Object3D();
  orb.position.set(0, 1.0, 0);
  staff.add(orb);
  r.sockets.weapon = orb;
  return r;
}

const R: PoseSpec = {
  pos: [0, -0.04, 0],
  chest: [0.08, 0, 0],
  head: [0.05, 0, 0],
  armR: [-0.35, 0, -0.2],
  foreR: [-0.9, 0, 0],
  armL: [-0.5, 0, 0.3],
  foreL: [-1.2, 0, 0],
  legL: [-0.15, 0, 0.06],
  shinL: [0.2, 0, 0],
  legR: [0.1, 0, -0.06],
  shinR: [0.15, 0, 0],
};

const casterAnims: AnimationSet = {
  idle: idleClip({ base: R, breathe: 0.04, crouch: 0, speed: 0.7, bob: 0.02, bobSpeed: 1 }),
  walk: gaitClip(1.1, { stride: 0.35, knee: 0.4, armSwing: 0.15, elbow: -0.9, armOut: 0.2, armFwd: 0.3, bounce: 0.02, crouch: 0.03, lean: 0.08, sway: 0.03, twist: 0.08, headStabilize: 0.8 }),
  run: gaitClip(0.66, { stride: 0.75, knee: 1.0, armSwing: 0.4, elbow: -1.0, armOut: 0.15, bounce: 0.05, crouch: 0.06, lean: 0.3, sway: 0.03, twist: 0.2, headStabilize: 0.8 }),
  jump: clip(0.4, [{ t: 0, p: R }, { t: 1, p: { armL: [-1.0, 0, 0.6], armR: [-1.0, 0, -0.6], legL: [-0.8, 0, 0], shinL: [1.2, 0, 0] } }]),
  fall: clip(1, [{ t: 0, p: { armL: [-0.6, 0, 0.9], armR: [-0.6, 0, -0.9], legL: [-0.3, 0, 0], shinL: [0.5, 0, 0] } }], true),
  land: clip(0.3, [{ t: 0, p: { pos: [0, -0.25, 0], chest: [0.3, 0, 0], legL: [-0.7, 0, 0], shinL: [1.1, 0, 0], legR: [-0.5, 0, 0], shinR: [1.0, 0, 0] } }, { t: 1, p: R }]),
  dodge: clip(0.4, [{ t: 0, p: R }, { t: 0.3, p: { root: [-0.3, 0, -0.4], pos: [0, 0.15, 0], armL: [-1.4, 0, 1.0], armR: [-1.4, 0, -1.0], legL: [-0.8, 0, 0.3], shinL: [1.2, 0, 0], legR: [-0.2, 0, -0.2], shinR: [0.8, 0, 0] } }, { t: 1, p: R }]),
  hit: clip(0.35, [{ t: 0, p: R }, { t: 0.25, p: combine(R, { chest: [-0.5, -0.2, 0], head: [-0.6, 0, 0], armL: [0.4, 0, 0.7], armR: [0.2, 0, -0.4] }), e: 'outExpo' }, { t: 1, p: R }]),
  stunned: clip(1.2, [{ t: 0, p: combine(R, { chest: [0.5, 0.2, 0], head: [0.6, 0.3, 0.2], armL: [0.2, 0, 0.2] }) }, { t: 0.5, p: combine(R, { chest: [0.5, -0.2, 0], head: [0.6, -0.3, -0.2], armL: [0.2, 0, 0.2] }) }], true),
  knockback: clip(0.7, [{ t: 0, p: { chest: [-0.5, 0, 0], armL: [-2.4, 0, 0.8], armR: [-2.4, 0, -0.8] } }, { t: 0.5, p: { root: [-1.0, -0.4, 0], armL: [-2.0, 0, 1.2], armR: [-2.4, 0, -1.2], legL: [-0.9, 0, 0] } }, { t: 0.8, p: LYING_BACK }, { t: 1, p: LYING_BACK }]),
  getup: clip(0.9, [{ t: 0, p: LYING_BACK }, { t: 0.45, p: { root: [-0.8, 0, 0], chest: [0.6, 0, 0], armL: [0.5, 0, 0.3], armR: [0.5, 0, -0.3], legL: [-1.3, 0, 0], shinL: [1.9, 0, 0] } }, { t: 1, p: R }]),
  death: clip(1.3, [{ t: 0, p: combine(R, { chest: [-0.5, 0, 0] }) }, { t: 0.4, p: { pos: [0, -0.45, 0], chest: [0.5, 0, 0], head: [0.6, 0, 0], legL: [-1.4, 0, 0], shinL: [1.8, 0, 0], legR: [-1.4, 0, 0], shinR: [1.8, 0, 0], armL: [0.3, 0, 0.3], armR: [0.3, 0, -0.3] } }, { t: 0.8, p: LYING_FACE, e: 'in' }, { t: 1, p: LYING_FACE }]),
  spawn: clip(1.1, [{ t: 0, p: combine(R, { pos: [0, -1.9, 0], armL: [-2.8, 0, 0.3], armR: [-2.8, 0, -0.3] }) }, { t: 0.7, p: combine(R, { pos: [0, 0.1, 0], armL: [-2.6, 0, 0.6], armR: [-2.6, 0, -0.6] }), e: 'out' }, { t: 1, p: R }]),
  rCast: clip(1.0, [
    { t: 0, p: R },
    { t: 0.45, p: combine(R, { armR: [-2.4, 0, -0.3], foreR: [-0.4, 0, 0], armL: [-1.2, 0, 0.5], foreL: [-0.6, 0, 0], chest: [-0.15, -0.3, 0], head: [-0.1, 0, 0] }) },
    { t: 0.58, p: combine(R, { armR: [-1.4, 0, 0], foreR: [-0.1, 0, 0], armL: [-1.4, 0, 0.1], foreL: [0, 0, 0], chest: [0.25, 0.2, 0], pos: [0, 0, 0.1] }), e: 'outExpo' },
    { t: 1, p: R },
  ]),
  rVolley: clip(1.3, [
    { t: 0, p: R },
    { t: 0.5, p: combine(R, { armR: [-2.8, 0, -0.4], foreR: [-0.2, 0, 0], armL: [-2.8, 0, 0.4], foreL: [-0.2, 0, 0], chest: [-0.3, 0, 0], head: [-0.4, 0, 0], pos: [0, 0.08, 0] }) },
    { t: 0.6, p: combine(R, { armR: [-1.5, 0, -0.3], foreR: [0, 0, 0], armL: [-1.5, 0, 0.3], foreL: [0, 0, 0], chest: [0.3, 0, 0], pos: [0, 0, 0.1] }), e: 'outExpo' },
    { t: 1, p: R },
  ]),
  rPush: clip(0.8, [
    { t: 0, p: R },
    { t: 0.35, p: combine(R, { armR: [-1.3, 0, 1.2], foreR: [-0.6, 0, 0], chest: [0.1, 0.6, 0] }) },
    { t: 0.48, p: combine(R, { armR: [-1.2, 0, -1.0], foreR: [-0.2, 0, 0], chest: [0.2, -0.7, 0] }), e: 'outExpo' },
    { t: 1, p: R },
  ]),
};

const casterStats: CharacterStats = {
  maxHealth: 95, moveSpeed: 6.6, walkSpeed: 2.6, acceleration: 14, turnSpeed: 8, attackDamage: 20, defense: 5, attackSpeed: 1,
  dodgeDistance: 6, dodgeDuration: 0.35, dodgeCooldown: 2.0, dodgeIFrames: 0.25, abilityPower: 1, cooldownMultiplier: 1, critChance: 0.05, critMultiplier: 1.5,
  jumpVelocity: 10, airJumps: 0, gravityScale: 1, poise: 0, mass: 0.8, scale: 1, ultChargeRate: 0,
};

const casterAttacks: EnemyAttack[] = [
  { name: 'Hex Bolt', anim: 'rCast', duration: 1.0, hits: [], cancelTime: 0.95, swingSound: 'charge_up', minRange: 3.5, maxRange: 28, weight: 3, projectile: { speed: 22, damage: 1.0, radius: 0.4, color: 0xff3050, time: 0.56 } },
  { name: 'Hex Volley', anim: 'rVolley', duration: 1.3, hits: [], cancelTime: 1.2, swingSound: 'charge_up', minRange: 5, maxRange: 24, weight: 2, projectile: { speed: 19, damage: 0.9, radius: 0.35, color: 0xff5070, time: 0.6, count: 3, spread: 0.24 } },
  { name: 'Repel', anim: 'rPush', duration: 0.8, hits: [{ time: 0.4, range: 2.6, arc: 160, damage: 0.6, knockback: 13, hitstun: 0.4, stagger: 60 }], cancelTime: 0.75, swingSound: 'enemy_swing', trail: [{ socket: 'weapon', color: 0xff5070, from: 0.3, to: 0.5, width: 0.5 }], minRange: 0, maxRange: 2.8, weight: 5 },
];

const casterAI: AIProfile = { preferredRange: 15, attackRange: 26, retreatRange: 8, aggression: 0.65, attackCooldown: 2.1, strafe: 0.8, turnRate: 1, evasion: 0.35, avoidHazards: true, memory: 3, fleeSpeed: 1.15, panic: 0.15 };

export const RangedEnemy: EnemyDefinition = {
  id: 'ranged',
  name: 'Hexcaster',
  stats: casterStats,
  buildModel: casterModel,
  animations: casterAnims,
  attacks: casterAttacks,
  ai: casterAI,
  vsCharacter: {
    // Titan is slow: kite him from far away and keep shooting.
    titan: { preferredRange: 20, retreatRange: 13, fleeSpeed: 1.25, aggression: 0.8, attackCooldown: 1.7, panic: 0 },
    // Volt closes gaps instantly: casters panic and try (and fail) to escape.
    volt: { retreatRange: 15, panic: 0.6, evasion: 0.1, fleeSpeed: 1.3, aggression: 0.5 },
    // Shadow vanishes: forget quickly, stay near allies.
    shadow: { memory: 1.2, retreatRange: 10, strafe: 1.0 },
    // Blaze's fire zones: keep extra distance.
    blaze: { preferredRange: 18, retreatRange: 10 },
  },
  sounds: enemySounds,
  vfx: enemyVfx(0xff5070),
  score: 120,
  healthBarOffset: 2.2,
};

// ================================================================ HEAVY ===
function heavyModel(): Rig {
  const b = new RigBuilder({
    hipHeight: 0.85,
    torso: 0.72,
    shoulderWidth: 0.34,
    hipWidth: 0.14,
    chestWidth: 0.38,
    chestDepth: 0.28,
    waistWidth: 0.28,
    upperArm: 0.32,
    foreArm: 0.3,
    armRadius: 0.11,
    foreArmRadius: 0.1,
    thighRadius: 0.13,
    shinRadius: 0.115,
    handSize: 0.17,
    footLength: 0.32,
    neck: 0.05,
    headRadius: 0.12,
    colors: { skin: 0x6a5a50, torso: 0x4a4c54, arms: 0x5a5058, legs: 0x3a3c44, boots: 0x222228, gloves: 0x4a4c54, accent: 0xff4020, belt: 0x7a2a14 },
    roughness: 0.5,
    metalness: 0.35,
  });
  const r = b.rig;
  const plate = stdMat(0x70747e, { metalness: 0.6, roughness: 0.38 });
  const hot = basicGlow(0xff4020);
  b.attach(r.bones.head, Geo.box(0.26, 0.24, 0.26), plate, [0, 0.11, 0]);
  b.attach(r.bones.head, Geo.box(0.2, 0.025, 0.02), hot, [0, 0.12, 0.135]);
  for (const side of [1, -1]) b.attach(r.bones.head, Geo.cone(0.05, 0.3, 6), stdMat(0xd8d0c0, { roughness: 0.5 }), [side * 0.16, 0.26, 0], [0, 0, -side * 0.7]);
  for (const [bone, side] of [
    [r.bones.armL, 1],
    [r.bones.armR, -1],
  ] as const) {
    b.attach(bone, Geo.box(0.3, 0.14, 0.3), plate, [side * 0.05, 0.04, 0], [0, 0, side * 0.3]);
    b.attach(bone, Geo.cone(0.05, 0.18, 5), hot, [side * 0.12, 0.14, 0], [0, 0, -side * 0.5]);
  }
  b.attach(r.bones.chest, Geo.box(0.62, 0.42, 0.14), plate, [0, 0.36, 0.22], [0.1, 0, 0]);
  b.attach(r.bones.chest, Geo.sphere(0.07, 10, 8), hot, [0, 0.38, 0.3]);
  b.attach(r.bones.hips, Geo.box(0.5, 0.24, 0.4), plate, [0, -0.08, 0]);
  // Great hammer.
  const hammer = new THREE.Group();
  hammer.position.set(0, -0.05, 0.02);
  hammer.rotation.x = -Math.PI / 2;
  r.bones.handR.add(hammer);
  b.attach(hammer, Geo.cyl(0.04, 0.04, 1.6, 8), stdMat(0x3a2a1e, { roughness: 0.8 }), [0, -0.45, 0]);
  const head = b.attach(hammer, Geo.box(0.5, 0.36, 0.36), plate, [0, -1.2, 0]);
  head.castShadow = true;
  b.attach(hammer, Geo.box(0.52, 0.06, 0.38), hot, [0, -1.2, 0]);
  const tip = new THREE.Object3D();
  tip.position.set(0, -1.2, 0);
  hammer.add(tip);
  r.sockets.weapon = tip;
  return r;
}

const H: PoseSpec = {
  pos: [0, -0.06, 0],
  chest: [0.2, 0.2, 0],
  head: [-0.1, -0.1, 0],
  armR: [-0.3, 0, -0.35],
  foreR: [-1.0, 0, 0],
  armL: [-0.6, 0, 0.2],
  foreL: [-1.3, 0, 0],
  legL: [-0.2, 0, 0.15],
  shinL: [0.25, 0, 0],
  legR: [-0.05, 0, -0.15],
  shinR: [0.2, 0, 0],
};

const heavyAnims: AnimationSet = {
  idle: idleClip({ base: H, breathe: 0.08, crouch: 0, speed: 0.5 }),
  walk: gaitClip(1.4, { stride: 0.4, knee: 0.45, armSwing: 0.1, elbow: -1.0, armOut: 0.3, armFwd: 0.4, bounce: 0.03, crouch: 0.06, lean: 0.2, sway: 0.12, twist: 0.1, headStabilize: 0.6, stomp: 0.06 }),
  run: gaitClip(0.95, { stride: 0.65, knee: 0.9, armSwing: 0.2, elbow: -1.0, armOut: 0.3, armFwd: 0.4, bounce: 0.06, crouch: 0.1, lean: 0.35, sway: 0.1, twist: 0.2, headStabilize: 0.6, stomp: 0.1 }),
  jump: clip(0.4, [{ t: 0, p: H }, { t: 1, p: combine(H, { legL: [-0.6, 0, 0.15], shinL: [1.0, 0, 0] }) }]),
  fall: clip(1, [{ t: 0, p: combine(H, { armL: [-0.8, 0, 0.8] }) }], true),
  land: clip(0.5, [{ t: 0, p: combine(H, { pos: [0, -0.3, 0], chest: [0.5, 0, 0], legL: [-0.8, 0, 0.2], shinL: [1.3, 0, 0], legR: [-0.8, 0, -0.2], shinR: [1.3, 0, 0] }) }, { t: 1, p: H }]),
  dodge: clip(0.5, [{ t: 0, p: H }, { t: 0.4, p: combine(H, { root: [0.3, 0, 0.3], pos: [0, -0.3, 0], legL: [-0.9, 0, 0.3], shinL: [1.3, 0, 0] }) }, { t: 1, p: H }]),
  hit: clip(0.35, [{ t: 0, p: H }, { t: 0.3, p: combine(H, { chest: [-0.25, 0.1, 0], head: [-0.3, 0.1, 0] }), e: 'out' }, { t: 1, p: H }]),
  stunned: clip(1.4, [{ t: 0, p: combine(H, { chest: [0.5, 0.2, 0.1], head: [0.5, 0.2, 0.2], armL: [0.2, 0, 0.3] }) }, { t: 0.5, p: combine(H, { chest: [0.5, -0.2, -0.1], head: [0.5, -0.2, -0.2], armL: [0.2, 0, 0.3] }) }], true),
  knockback: clip(0.9, [{ t: 0, p: combine(H, { chest: [-0.4, 0, 0] }) }, { t: 0.6, p: { root: [-0.9, 0, 0], armL: [-1.8, 0, 1.0], armR: [-1.8, 0, -1.0] }, e: 'in' }, { t: 0.85, p: LYING_BACK, e: 'in' }, { t: 1, p: LYING_BACK }]),
  getup: clip(1.1, [{ t: 0, p: LYING_BACK }, { t: 0.45, p: { root: [-0.9, 0, 0], chest: [0.6, 0, 0], armL: [0.5, 0, 0.3], armR: [0.5, 0, -0.3], legL: [-1.5, 0, 0.2], shinL: [2.0, 0, 0] } }, { t: 0.75, p: { pos: [0, -0.45, 0], chest: [0.6, 0, 0], legL: [-1.4, 0, 0.1], shinL: [1.9, 0, 0], legR: [0.2, 0, 0], shinR: [2.2, 0, 0] } }, { t: 1, p: H }]),
  death: clip(1.6, [{ t: 0, p: combine(H, { chest: [-0.3, 0, 0] }) }, { t: 0.4, p: { pos: [0, -0.42, 0], chest: [0.4, 0, 0], head: [0.4, 0, 0], legL: [-1.5, 0, 0.1], shinL: [1.7, 0, 0], legR: [-1.5, 0, -0.1], shinR: [1.7, 0, 0], armL: [-0.2, 0, 0.5], armR: [-0.2, 0, -0.5] } }, { t: 0.8, p: LYING_FACE, e: 'in' }, { t: 1, p: LYING_FACE }]),
  spawn: clip(1.3, [{ t: 0, p: combine(H, { pos: [0, -2.4, 0], chest: [0.6, 0, 0] }) }, { t: 0.7, p: combine(H, { pos: [0, -0.2, 0], chest: [-0.3, 0, 0], head: [-0.5, 0, 0], armL: [-0.6, 0, 1.2] }), e: 'out' }, { t: 1, p: H }]),
  hSwing: clip(1.6, [
    { t: 0, p: H },
    { t: 0.5, p: combine(H, { armR: [-0.5, 0, -1.3], foreR: [-0.6, 0, 0], armL: [-0.9, 0, -0.4], foreL: [-1.4, 0, 0], chest: [0.1, -1.0, 0], hips: [0, -0.4, 0], pos: [0, -0.1, -0.05] }) },
    { t: 0.56, p: combine(H, { armR: [-1.2, 0, 0.5], foreR: [-0.3, 0, 0], armL: [-1.3, 0, 0.8], foreL: [-0.6, 0, 0], chest: [0.3, 0.9, 0], hips: [0, 0.4, 0], pos: [0, -0.15, 0.15] }), e: 'outExpo' },
    { t: 0.8, p: combine(H, { armR: [-1.15, 0, 0.5], foreR: [-0.3, 0, 0], armL: [-1.25, 0, 0.8], foreL: [-0.6, 0, 0], chest: [0.3, 0.85, 0], pos: [0, -0.15, 0.15] }) },
    { t: 1, p: H },
  ]),
  hSlam: clip(2.1, [
    { t: 0, p: H },
    { t: 0.5, p: { pos: [0, 0.05, -0.05], chest: [-0.45, 0, 0], head: [-0.4, 0, 0], armR: [-3.0, 0, 0.2], foreR: [-0.5, 0, 0], armL: [-3.0, 0, -0.2], foreL: [-0.5, 0, 0], legL: [-0.2, 0, 0.2], legR: [0.1, 0, -0.2] } },
    { t: 0.55, p: { pos: [0, -0.5, 0.15], chest: [1.0, 0, 0], head: [-0.6, 0, 0], armR: [-1.1, 0, 0.1], foreR: [0, 0, 0], armL: [-1.1, 0, -0.1], foreL: [0, 0, 0], legL: [-1.2, 0, 0.3], shinL: [1.5, 0, 0], legR: [0.2, 0, -0.3], shinR: [1.2, 0, 0] }, e: 'inExpo' },
    { t: 0.8, p: { pos: [0, -0.48, 0.15], chest: [0.95, 0, 0], head: [-0.6, 0, 0], armR: [-1.1, 0, 0.1], foreR: [0, 0, 0], armL: [-1.1, 0, -0.1], foreL: [0, 0, 0], legL: [-1.2, 0, 0.3], shinL: [1.5, 0, 0], legR: [0.2, 0, -0.3], shinR: [1.2, 0, 0] } },
    { t: 1, p: H },
  ]),
  hCharge: {
    ...gaitClip(0.7, { stride: 0.8, knee: 1.1, armSwing: 0.1, elbow: -1.2, armOut: 0.3, armFwd: 0.6, bounce: 0.07, crouch: 0.15, lean: 0.75, sway: 0.06, twist: 0.1, headStabilize: 0.9, stomp: 0.12 }),
  },
};

const heavyStats: CharacterStats = {
  maxHealth: 560, moveSpeed: 4.6, walkSpeed: 2.2, acceleration: 8, turnSpeed: 4, attackDamage: 44, defense: 45, attackSpeed: 1,
  dodgeDistance: 3, dodgeDuration: 0.5, dodgeCooldown: 6, dodgeIFrames: 0.1, abilityPower: 1, cooldownMultiplier: 1, critChance: 0.05, critMultiplier: 1.5,
  jumpVelocity: 8, airJumps: 0, gravityScale: 1.2, poise: 70, mass: 3.5, scale: 1.5, ultChargeRate: 0,
};

const heavyAttacks: EnemyAttack[] = [
  { name: 'Hammer Swing', anim: 'hSwing', duration: 1.6, hits: [{ time: 0.88, range: 3.3, arc: 150, damage: 1.0, knockback: 14, launch: 5, hitstun: 0.6, stagger: 100, hitstop: 0.08, shake: 0.35 }], cancelTime: 1.5, swingSound: 'heavy_whoosh', superArmor: true, trail: [{ socket: 'weapon', color: 0xff5020, from: 0.78, to: 0.95, width: 0.9 }], minRange: 0, maxRange: 3.6, weight: 3, lunge: 1.2, lungeStart: 0.8, lungeEnd: 0.9 },
  {
    name: 'Ground Slam', anim: 'hSlam', duration: 2.1, hits: [{ time: 1.16, range: 5.2, arc: 360, damage: 1.35, knockback: 10, launch: 9, hitstun: 0.8, stagger: 130, hitstop: 0.1, shake: 0.55 }], cancelTime: 2.0, swingSound: 'heavy_whoosh', superArmor: true, minRange: 0, maxRange: 5, weight: 2, telegraph: 5.2,
    onHitFrame(ctx) {
      const a = ctx.attacker;
      EarthFX.impact(ctx.world.vfx, a.position.clone().addScaledVector(a.forward(), 1.2), 5, 12);
      ctx.world.vfx.ring(a.position, 0xff5020, 6, 0.4);
      ctx.world.audio.play('heavy_slam', a.position);
    },
  },
  {
    name: 'Rampage', anim: 'hCharge', duration: 1.8, hitOnce: true,
    hits: [0.6, 0.8, 1.0, 1.2, 1.4].map((time) => ({ time, range: 2.4, arc: 130, damage: 1.1, knockback: 16, launch: 6, hitstun: 0.6, stagger: 120, hitstop: 0.06, shake: 0.3 })),
    cancelTime: 1.7, swingSound: 'heavy_whoosh', superArmor: true, minRange: 7, maxRange: 18, weight: 2, lunge: 12, lungeStart: 0.5, lungeEnd: 1.45,
    onStart(ctx) {
      ctx.world.audio.play('roar', ctx.attacker.position, { pitch: 1.5, volume: 0.5 });
    },
  },
];

const heavyAI: AIProfile = { preferredRange: 2.8, attackRange: 3.4, retreatRange: 0, aggression: 0.8, attackCooldown: 2.4, strafe: 0, turnRate: 0.6, evasion: 0, avoidHazards: false, memory: 4, fleeSpeed: 1, panic: 0 };

export const HeavyEnemy: EnemyDefinition = {
  id: 'heavy',
  name: 'Juggernaut',
  stats: heavyStats,
  buildModel: heavyModel,
  animations: heavyAnims,
  attacks: heavyAttacks,
  ai: heavyAI,
  vsCharacter: {
    // Titan is its rival: straight-up brawl, faster attack cadence.
    titan: { aggression: 1.0, attackCooldown: 1.8, preferredRange: 2.2 },
    // Volt is too fast for swings: favour area slams.
    volt: { attackCooldown: 2.0, turnRate: 0.9 },
    // Shadow gets behind it easily; it compensates with slams.
    shadow: { turnRate: 0.45 },
    blaze: { avoidHazards: true },
  },
  sounds: { ...enemySounds, footstep: 'giant_step', death: 'destroy_stone' },
  vfx: enemyVfx(0xff5020),
  score: 350,
  healthBarOffset: 3.3,
};

export const ENEMIES = { fighter: FighterEnemy, ranged: RangedEnemy, heavy: HeavyEnemy };
export type EnemyId = keyof typeof ENEMIES;

