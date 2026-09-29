import { Ease, EaseName, clamp01, lerp } from '../core/math';

/**
 * Procedural animation data model.
 *
 * A pose is a flat Float32Array holding an Euler rotation for the root and every
 * bone plus a root position offset. Clips are either keyframed (KeyDef[]) or a
 * pure function of normalized time. Real skeletal assets can replace these later:
 * see AnimationController.IAnimator and README "Replacing placeholder animations".
 */
export const BONES = [
  'hips',
  'spine',
  'chest',
  'neck',
  'head',
  'armL',
  'foreL',
  'handL',
  'armR',
  'foreR',
  'handR',
  'legL',
  'shinL',
  'footL',
  'legR',
  'shinR',
  'footR',
] as const;

export type BoneName = (typeof BONES)[number];
export type PoseKey = BoneName | 'root';
export type V3 = [number, number, number];
export type PoseSpec = { [K in PoseKey]?: V3 } & { pos?: V3 };

export const POSE_KEYS: PoseKey[] = ['root', ...BONES];
const KEY_INDEX: Record<string, number> = {};
POSE_KEYS.forEach((k, i) => (KEY_INDEX[k] = i * 3));
export const POS_OFFSET = POSE_KEYS.length * 3;
export const POSE_LEN = POS_OFFSET + 3;

export const keyOffset = (k: PoseKey) => KEY_INDEX[k];

export function newPose(): Float32Array {
  return new Float32Array(POSE_LEN);
}

export function specToPose(spec: PoseSpec, out = newPose()): Float32Array {
  out.fill(0);
  addSpec(out, spec, 1);
  return out;
}

export function addSpec(out: Float32Array, spec: PoseSpec, w = 1): Float32Array {
  for (const k in spec) {
    if (k === 'pos') {
      const p = spec.pos!;
      out[POS_OFFSET] += p[0] * w;
      out[POS_OFFSET + 1] += p[1] * w;
      out[POS_OFFSET + 2] += p[2] * w;
      continue;
    }
    const o = KEY_INDEX[k];
    if (o === undefined) continue;
    const v = spec[k as PoseKey]!;
    out[o] += v[0] * w;
    out[o + 1] += v[1] * w;
    out[o + 2] += v[2] * w;
  }
  return out;
}

export function lerpPose(a: Float32Array, b: Float32Array, t: number, out: Float32Array): Float32Array {
  for (let i = 0; i < POSE_LEN; i++) out[i] = a[i] + (b[i] - a[i]) * t;
  return out;
}

/** Writes a rotation into a pose buffer (used by functional clips). */
export function setRot(out: Float32Array, k: PoseKey, x: number, y = 0, z = 0): void {
  const o = KEY_INDEX[k];
  out[o] = x;
  out[o + 1] = y;
  out[o + 2] = z;
}

export function addRot(out: Float32Array, k: PoseKey, x: number, y = 0, z = 0): void {
  const o = KEY_INDEX[k];
  out[o] += x;
  out[o + 1] += y;
  out[o + 2] += z;
}

export function setPos(out: Float32Array, x: number, y: number, z: number): void {
  out[POS_OFFSET] = x;
  out[POS_OFFSET + 1] = y;
  out[POS_OFFSET + 2] = z;
}

/** Mirrors a pose spec left↔right (swaps L/R bones, negates Y/Z rotations). */
export function mirrorSpec(spec: PoseSpec): PoseSpec {
  const out: PoseSpec = {};
  for (const k in spec) {
    if (k === 'pos') {
      const p = spec.pos!;
      out.pos = [-p[0], p[1], p[2]];
      continue;
    }
    const v = spec[k as PoseKey]!;
    let target = k;
    if (k.endsWith('L')) target = k.slice(0, -1) + 'R';
    else if (k.endsWith('R')) target = k.slice(0, -1) + 'L';
    (out as any)[target] = [v[0], -v[1], -v[2]];
  }
  return out;
}

/** Shallow combine: later specs add onto earlier ones. */
export function combine(...specs: PoseSpec[]): PoseSpec {
  const out: PoseSpec = {};
  for (const s of specs) {
    for (const k in s) {
      const v = (s as any)[k] as V3;
      const cur = (out as any)[k] as V3 | undefined;
      (out as any)[k] = cur ? [cur[0] + v[0], cur[1] + v[1], cur[2] + v[2]] : [v[0], v[1], v[2]];
    }
  }
  return out;
}

export interface KeyDef {
  /** Normalized time 0..1. */
  t: number;
  p: PoseSpec;
  /** Easing used when interpolating INTO this key. */
  e?: EaseName;
}

export interface ClipDef {
  /** Natural length in seconds. */
  duration: number;
  loop?: boolean;
  keys?: KeyDef[];
  /** Fully procedural clip: writes a pose for normalized time t (0..1). */
  fn?: (t: number, out: Float32Array, timeSeconds: number) => void;
  /** Optional additive layer applied on top of keys/fn (e.g. trembling). */
  layer?: (t: number, out: Float32Array, timeSeconds: number) => void;
}

export type AnimationSet = Record<string, ClipDef>;

/** Required clip names every playable character must provide. */
export const REQUIRED_CLIPS = [
  'idle',
  'walk',
  'run',
  'jump',
  'fall',
  'land',
  'dodge',
  'hit',
  'knockback',
  'getup',
  'death',
] as const;

export function clip(duration: number, keys: KeyDef[], loop = false): ClipDef {
  return { duration, keys, loop };
}

/** Compiled clip: key poses pre-converted to Float32Arrays for fast sampling. */
export class CompiledClip {
  readonly duration: number;
  readonly loop: boolean;
  private times: number[] = [];
  private poses: Float32Array[] = [];
  private eases: ((t: number) => number)[] = [];
  private fn?: ClipDef['fn'];
  private layer?: ClipDef['layer'];

  constructor(public readonly name: string, def: ClipDef) {
    this.duration = Math.max(0.001, def.duration);
    this.loop = !!def.loop;
    this.fn = def.fn;
    this.layer = def.layer;
    if (def.keys && def.keys.length) {
      const keys = [...def.keys].sort((a, b) => a.t - b.t);
      for (const k of keys) {
        this.times.push(k.t);
        this.poses.push(specToPose(k.p));
        this.eases.push(Ease[k.e ?? 'inOut']);
      }
    }
  }

  /** Samples the clip at `time` seconds into out. */
  sample(time: number, out: Float32Array): void {
    let t = time / this.duration;
    if (this.loop) t = t - Math.floor(t);
    else t = clamp01(t);

    if (this.fn) {
      out.fill(0);
      this.fn(t, out, time);
    } else if (this.poses.length === 0) {
      out.fill(0);
    } else if (this.poses.length === 1 || t <= this.times[0]) {
      out.set(this.poses[0]);
    } else if (t >= this.times[this.times.length - 1]) {
      if (this.loop) {
        // Wrap back towards the first key for seamless loops.
        const last = this.times.length - 1;
        const span = 1 - this.times[last] + this.times[0];
        const local = span > 0 ? (t - this.times[last]) / span : 0;
        lerpPose(this.poses[last], this.poses[0], this.eases[0](clamp01(local)), out);
      } else {
        out.set(this.poses[this.poses.length - 1]);
      }
    } else {
      let i = 1;
      while (i < this.times.length && this.times[i] < t) i++;
      const t0 = this.times[i - 1];
      const t1 = this.times[i];
      const local = t1 > t0 ? (t - t0) / (t1 - t0) : 1;
      lerpPose(this.poses[i - 1], this.poses[i], this.eases[i](clamp01(local)), out);
    }
    if (this.layer) this.layer(t, out, time);
  }
}

// ------------------------------------------------ procedural locomotion ----
export interface GaitStyle {
  /** Thigh swing amplitude (radians). */
  stride: number;
  /** Extra knee bend on the recovering leg. */
  knee: number;
  /** Arm swing amplitude. */
  armSwing: number;
  /** Constant elbow bend (negative = forearm forward). */
  elbow: number;
  /** Arm abduction (outward). */
  armOut: number;
  /** Vertical bounce amplitude. */
  bounce: number;
  /** Constant crouch (negative root y). */
  crouch: number;
  /** Forward lean of the torso (radians, positive = forward). */
  lean: number;
  /** Hip side sway. */
  sway: number;
  /** Counter-twist of chest vs hips. */
  twist: number;
  /** Head counter-rotation / stabilization (0..1). */
  headStabilize: number;
  /** Arms held back (ninja run) instead of swinging. */
  armsBack?: number;
  /** Extra stomp: sharp downward accent at foot contact. */
  stomp?: number;
  /** Constant forward raise of the upper arms (guard stances). */
  armFwd?: number;
}

export function gaitClip(duration: number, s: GaitStyle): ClipDef {
  return {
    duration,
    loop: true,
    fn: (t, out) => {
      const ph = t * Math.PI * 2;
      const sw = Math.sin(ph);
      const cw = Math.cos(ph);
      // Legs: negative X swings forward.
      setRot(out, 'legL', -sw * s.stride - s.crouch * 0.6, 0, 0.02);
      setRot(out, 'legR', sw * s.stride - s.crouch * 0.6, 0, -0.02);
      // Knee bends while the leg recovers (swinging forward).
      const kL = Math.max(0, cw) * s.knee + s.crouch * 1.1 + 0.05;
      const kR = Math.max(0, -cw) * s.knee + s.crouch * 1.1 + 0.05;
      setRot(out, 'shinL', kL, 0, 0);
      setRot(out, 'shinR', kR, 0, 0);
      setRot(out, 'footL', -kL * 0.4 + sw * 0.15, 0, 0);
      setRot(out, 'footR', -kR * 0.4 - sw * 0.15, 0, 0);
      // Arms swing opposite to legs.
      const back = s.armsBack ?? 0;
      const fwd = s.armFwd ?? 0;
      setRot(out, 'armL', sw * s.armSwing * (1 - back) + back * 0.9 - fwd, 0, s.armOut);
      setRot(out, 'armR', -sw * s.armSwing * (1 - back) + back * 0.9 - fwd, 0, -s.armOut);
      setRot(out, 'foreL', s.elbow - Math.max(0, sw) * 0.2 * (1 - back), 0, 0);
      setRot(out, 'foreR', s.elbow - Math.max(0, -sw) * 0.2 * (1 - back), 0, 0);
      // Torso.
      const bounce = Math.abs(Math.sin(ph)) * s.bounce;
      const stomp = s.stomp ? Math.pow(1 - Math.abs(Math.sin(ph)), 6) * s.stomp : 0;
      setPos(out, 0, -s.crouch + bounce - s.bounce * 0.5 - stomp, 0);
      setRot(out, 'hips', 0, sw * s.twist * 0.6, cw * s.sway);
      setRot(out, 'spine', s.lean * 0.5, -sw * s.twist * 0.4, -cw * s.sway * 0.5);
      setRot(out, 'chest', s.lean * 0.5, -sw * s.twist * 0.6, 0);
      setRot(out, 'head', -s.lean * s.headStabilize, sw * s.twist * s.headStabilize, 0);
    },
  };
}

export interface IdleStyle {
  breathe: number;
  crouch: number;
  /** Base pose sampled underneath the breathing. */
  base: PoseSpec;
  speed: number;
  /** Side-to-side weight shift (boxer bounce, etc.). */
  bob?: number;
  bobSpeed?: number;
}

export function idleClip(s: IdleStyle): ClipDef {
  const base = specToPose(s.base);
  return {
    duration: 1 / s.speed,
    loop: true,
    fn: (t, out) => {
      out.set(base);
      const ph = t * Math.PI * 2;
      const br = Math.sin(ph) * s.breathe;
      addRot(out, 'chest', -br * 0.5, 0, 0);
      addRot(out, 'armL', br * 0.2, 0, br * 0.3);
      addRot(out, 'armR', br * 0.2, 0, -br * 0.3);
      addRot(out, 'head', br * 0.3, 0, 0);
      out[POS_OFFSET + 1] += -s.crouch + br * 0.02;
      if (s.bob) {
        const bph = t * Math.PI * 2 * (s.bobSpeed ?? 2);
        out[POS_OFFSET + 1] += Math.abs(Math.sin(bph)) * s.bob;
        out[POS_OFFSET] += Math.sin(bph * 0.5) * s.bob * 0.5;
      }
    },
  };
}

/**
 * Somersault clip rotating the body around its hips (not the feet).
 * dir = 1 front flip, -1 back flip. `axis` 'x' flips, 'z' cartwheels.
 */
export function flipClip(duration: number, hipHeight: number, tuck: PoseSpec, dir = 1, axis: 'x' | 'z' = 'x', turns = 1): ClipDef {
  const tuckPose = specToPose(tuck);
  const ro = KEY_INDEX['root'];
  return {
    duration,
    fn: (t, out) => {
      const e = t < 1 ? 1 - Math.pow(1 - t, 2) : 1;
      const ang = e * Math.PI * 2 * dir * turns;
      // Tuck in the middle of the flip, open at the ends.
      const k = Math.sin(Math.min(1, t * 1.1) * Math.PI);
      for (let i = 0; i < POSE_LEN; i++) out[i] = tuckPose[i] * k;
      const h = hipHeight;
      if (axis === 'x') {
        out[ro] = ang;
        out[POS_OFFSET + 1] += h - h * Math.cos(ang);
        out[POS_OFFSET + 2] += -h * Math.sin(ang);
      } else {
        out[ro + 2] = ang;
        out[POS_OFFSET] += h * Math.sin(ang);
        out[POS_OFFSET + 1] += h - h * Math.cos(ang);
      }
    },
  };
}

/** Linear interpolation helper for clip authoring. */
export const L = lerp;
