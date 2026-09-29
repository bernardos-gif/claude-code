import { AnimationSet, CompiledClip, POSE_KEYS, POS_OFFSET, keyOffset, newPose } from './AnimationClip';
import type { Rig } from './Rig';
import { damp, dampFactor } from '../core/math';

export interface PlayOptions {
  /** Cross-fade time in seconds. */
  fade?: number;
  /** Playback rate multiplier. */
  speed?: number;
  /** Stretch/squash the clip to last exactly this many seconds. */
  duration?: number;
  /** Restart even if the clip is already playing. */
  restart?: boolean;
}

/**
 * Animator contract used by gameplay code. The procedural implementation below
 * can be swapped for a skeletal (THREE.AnimationMixer/glTF) implementation that
 * maps the same clip names — gameplay never touches bones directly.
 */
export interface IAnimator {
  readonly current: string;
  readonly time: number;
  readonly normalizedTime: number;
  play(name: string, opts?: PlayOptions): void;
  has(name: string): boolean;
  clipDuration(name: string): number;
  isFinished(): boolean;
  update(dt: number): void;
  flinch(localX: number, localZ: number, strength: number): void;
  setLean(forward: number, side: number): void;
  setSpeed(speed: number): void;
}

export class AnimationController implements IAnimator {
  private clips = new Map<string, CompiledClip>();
  private cur: CompiledClip;
  private curName = '';
  private curTime = 0;
  private speed = 1;
  private fadeFrom = newPose();
  private fadeT = 1;
  private fadeDur = 0;
  private sampled = newPose();
  private out = newPose();
  private flinchX = 0;
  private flinchZ = 0;
  private flinchVX = 0;
  private flinchVZ = 0;
  private leanF = 0;
  private leanS = 0;
  private targetLeanF = 0;
  private targetLeanS = 0;
  private warned = new Set<string>();
  /** Optional per-frame additive tweak (e.g. electric jitter while buffed). */
  extraLayer: ((out: Float32Array, dt: number) => void) | null = null;

  constructor(private rig: Rig, set: AnimationSet) {
    for (const [name, def] of Object.entries(set)) this.clips.set(name, new CompiledClip(name, def));
    const idle = this.clips.get('idle') ?? [...this.clips.values()][0];
    this.cur = idle;
    this.curName = idle?.name ?? '';
    this.cur?.sample(0, this.out);
    this.apply();
  }

  get current(): string {
    return this.curName;
  }
  get time(): number {
    return this.curTime;
  }
  get normalizedTime(): number {
    return this.cur ? Math.min(1, this.curTime / this.cur.duration) : 1;
  }

  has(name: string): boolean {
    return this.clips.has(name);
  }

  clipDuration(name: string): number {
    return this.clips.get(name)?.duration ?? 0;
  }

  play(name: string, opts: PlayOptions = {}): void {
    let clip = this.clips.get(name);
    if (!clip) {
      if (!this.warned.has(name)) {
        this.warned.add(name);
        console.warn(`[anim] missing clip "${name}", falling back to idle`);
      }
      clip = this.clips.get('idle');
      if (!clip) return;
    }
    const speed = opts.duration ? clip.duration / Math.max(0.01, opts.duration) : (opts.speed ?? 1);
    if (clip === this.cur && !opts.restart) {
      this.speed = speed;
      return;
    }
    this.fadeFrom.set(this.out);
    // Wrap rotations so a clip ending at 2π (spins) does not unwind during the blend.
    for (let i = 0; i < POS_OFFSET; i++) {
      const v = this.fadeFrom[i];
      if (v > Math.PI || v < -Math.PI) this.fadeFrom[i] = Math.atan2(Math.sin(v), Math.cos(v));
    }
    this.fadeDur = opts.fade ?? 0.12;
    this.fadeT = this.fadeDur > 0 ? 0 : 1;
    this.cur = clip;
    this.curName = clip.name;
    this.curTime = 0;
    this.speed = speed;
  }

  setSpeed(speed: number): void {
    this.speed = speed;
  }

  isFinished(): boolean {
    return !this.cur.loop && this.curTime >= this.cur.duration;
  }

  flinch(localX: number, localZ: number, strength: number): void {
    // Impulse on a spring: body recoils away from the hit then settles.
    this.flinchVX += localX * strength * 14;
    this.flinchVZ += localZ * strength * 14;
  }

  setLean(forward: number, side: number): void {
    this.targetLeanF = forward;
    this.targetLeanS = side;
  }

  update(dt: number): void {
    if (!this.cur) return;
    this.curTime += dt * this.speed;
    this.cur.sample(this.curTime, this.sampled);

    if (this.fadeT < 1) {
      this.fadeT = Math.min(1, this.fadeT + dt / Math.max(0.0001, this.fadeDur));
      const w = this.fadeT * this.fadeT * (3 - 2 * this.fadeT);
      for (let i = 0; i < this.out.length; i++) this.out[i] = this.fadeFrom[i] + (this.sampled[i] - this.fadeFrom[i]) * w;
    } else {
      this.out.set(this.sampled);
    }

    // Flinch spring.
    const k = 180;
    const c = 16;
    this.flinchVX += (-k * this.flinchX - c * this.flinchVX) * dt;
    this.flinchVZ += (-k * this.flinchZ - c * this.flinchVZ) * dt;
    this.flinchX += this.flinchVX * dt;
    this.flinchZ += this.flinchVZ * dt;
    const sp = keyOffset('spine');
    const ch = keyOffset('chest');
    const hd = keyOffset('head');
    // Hit from front (localZ>0) bends torso back (negative x).
    this.out[sp] -= this.flinchZ * 0.5;
    this.out[ch] -= this.flinchZ * 0.7;
    this.out[hd] -= this.flinchZ * 0.6;
    this.out[sp + 2] += this.flinchX * 0.5;
    this.out[ch + 2] += this.flinchX * 0.6;

    // Lean.
    this.leanF = damp(this.leanF, this.targetLeanF, 8, dt);
    this.leanS = damp(this.leanS, this.targetLeanS, 8, dt);
    const r = keyOffset('root');
    this.out[r] += this.leanF;
    this.out[r + 2] += this.leanS;

    if (this.extraLayer) this.extraLayer(this.out, dt);
    this.apply();
  }

  private apply(): void {
    const rig = this.rig;
    const o = this.out;
    rig.body.rotation.set(o[0], o[1], o[2]);
    rig.body.position.set(o[POS_OFFSET], o[POS_OFFSET + 1], o[POS_OFFSET + 2]);
    for (let i = 1; i < POSE_KEYS.length; i++) {
      const bone = rig.bones[POSE_KEYS[i] as keyof Rig['bones']];
      const off = i * 3;
      bone.rotation.set(o[off], o[off + 1], o[off + 2]);
    }
  }
}

export { dampFactor };
