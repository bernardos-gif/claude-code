import * as THREE from 'three';

/**
 * Fully procedural audio: every sound effect is synthesized with WebAudio
 * (oscillators + filtered noise + envelopes), so the game needs no audio files.
 * Recipes are registered by id; characters reference them by name, and new
 * characters can register their own with AudioManager.register().
 */
export interface PlayOpts {
  volume?: number;
  pitch?: number;
}

type Recipe = (a: Synth, t: number, p: { pitch: number; out: AudioNode }) => number | void;

class Synth {
  constructor(public ctx: AudioContext, public noiseBuf: AudioBuffer) {}

  env(g: GainNode, t: number, attack: number, peak: number, decay: number, curve: 'exp' | 'lin' = 'exp'): void {
    g.gain.setValueAtTime(0.0001, t);
    g.gain.linearRampToValueAtTime(peak, t + attack);
    if (curve === 'exp') g.gain.exponentialRampToValueAtTime(0.0001, t + attack + decay);
    else g.gain.linearRampToValueAtTime(0.0001, t + attack + decay);
  }

  noise(out: AudioNode, t: number, o: { dur: number; type?: BiquadFilterType; f0: number; f1?: number; q?: number; gain: number; attack?: number; rate?: number }): void {
    const src = this.ctx.createBufferSource();
    src.buffer = this.noiseBuf;
    src.playbackRate.value = o.rate ?? 1;
    src.loop = true;
    const f = this.ctx.createBiquadFilter();
    f.type = o.type ?? 'lowpass';
    f.frequency.setValueAtTime(Math.max(20, o.f0), t);
    if (o.f1 !== undefined) f.frequency.exponentialRampToValueAtTime(Math.max(20, o.f1), t + o.dur);
    f.Q.value = o.q ?? 0.8;
    const g = this.ctx.createGain();
    this.env(g, t, o.attack ?? 0.005, o.gain, o.dur);
    src.connect(f).connect(g).connect(out);
    src.start(t, Math.random() * 1.5);
    src.stop(t + (o.attack ?? 0.005) + o.dur + 0.05);
  }

  tone(out: AudioNode, t: number, o: { dur: number; wave?: OscillatorType; f0: number; f1?: number; gain: number; attack?: number; detune?: number; filter?: number }): void {
    const osc = this.ctx.createOscillator();
    osc.type = o.wave ?? 'sine';
    osc.frequency.setValueAtTime(Math.max(1, o.f0), t);
    if (o.f1 !== undefined) osc.frequency.exponentialRampToValueAtTime(Math.max(1, o.f1), t + o.dur);
    if (o.detune) osc.detune.value = o.detune;
    const g = this.ctx.createGain();
    this.env(g, t, o.attack ?? 0.005, o.gain, o.dur);
    let node: AudioNode = osc;
    if (o.filter) {
      const f = this.ctx.createBiquadFilter();
      f.type = 'lowpass';
      f.frequency.value = o.filter;
      osc.connect(f);
      node = f;
    }
    node.connect(g).connect(out);
    osc.start(t);
    osc.stop(t + (o.attack ?? 0.005) + o.dur + 0.05);
  }

  /** Rapid random frequency jumps: electric crackle. */
  crackle(out: AudioNode, t: number, dur: number, gain: number, base = 800): void {
    const osc = this.ctx.createOscillator();
    osc.type = 'square';
    const steps = Math.floor(dur / 0.012);
    for (let i = 0; i < steps; i++) osc.frequency.setValueAtTime(base * (0.4 + Math.random() * 2.2), t + i * 0.012);
    const f = this.ctx.createBiquadFilter();
    f.type = 'highpass';
    f.frequency.value = 900;
    const g = this.ctx.createGain();
    this.env(g, t, 0.003, gain, dur);
    osc.connect(f).connect(g).connect(out);
    osc.start(t);
    osc.stop(t + dur + 0.05);
  }
}

const R: Record<string, Recipe> = {};
const reg = (id: string, r: Recipe) => (R[id] = r);

// ----------------------------------------------------------------- common --
reg('ui_hover', (s, t, p) => s.tone(p.out, t, { dur: 0.05, wave: 'triangle', f0: 900 * p.pitch, f1: 1200, gain: 0.08 }));
reg('ui_click', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.08, wave: 'triangle', f0: 600 * p.pitch, f1: 300, gain: 0.18 });
  s.noise(p.out, t, { dur: 0.04, type: 'highpass', f0: 3000, gain: 0.08 });
});
reg('ui_select', (s, t, p) => {
  [523, 659, 784, 1046].forEach((f, i) => s.tone(p.out, t + i * 0.05, { dur: 0.25, wave: 'triangle', f0: f * p.pitch, gain: 0.14 }));
});
reg('error', (s, t, p) => s.tone(p.out, t, { dur: 0.12, wave: 'square', f0: 180, f1: 140, gain: 0.07, filter: 900 }));
reg('crit', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.18, wave: 'triangle', f0: 1800, f1: 2600, gain: 0.1 });
  s.tone(p.out, t + 0.02, { dur: 0.22, wave: 'sine', f0: 2400, gain: 0.06 });
});
reg('perfect_dodge', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.35, wave: 'sine', f0: 1200, f1: 2400, gain: 0.12 });
  s.noise(p.out, t, { dur: 0.3, type: 'bandpass', f0: 5000, f1: 1500, q: 3, gain: 0.1 });
});
reg('ult_ready', (s, t, p) => {
  [392, 523, 659, 784].forEach((f, i) => s.tone(p.out, t + i * 0.07, { dur: 0.5, wave: 'triangle', f0: f, gain: 0.12 }));
  s.noise(p.out, t, { dur: 0.6, type: 'highpass', f0: 6000, gain: 0.05, attack: 0.2 });
});
reg('wave_start', (s, t, p) => {
  s.tone(p.out, t, { dur: 1.1, wave: 'sawtooth', f0: 110, f1: 104, gain: 0.16, attack: 0.08, filter: 700 });
  s.tone(p.out, t, { dur: 1.1, wave: 'sawtooth', f0: 165, f1: 156, gain: 0.1, attack: 0.08, filter: 800 });
  s.tone(p.out, t, { dur: 0.3, wave: 'sine', f0: 90, f1: 40, gain: 0.4 });
  s.noise(p.out, t, { dur: 0.8, type: 'lowpass', f0: 400, gain: 0.2 });
});
reg('wave_clear', (s, t, p) => {
  [523, 659, 784, 1046, 1318].forEach((f, i) => s.tone(p.out, t + i * 0.08, { dur: 0.6, wave: 'triangle', f0: f, gain: 0.12 }));
});
reg('game_over', (s, t, p) => {
  [392, 330, 262, 196].forEach((f, i) => s.tone(p.out, t + i * 0.25, { dur: 0.8, wave: 'sawtooth', f0: f, gain: 0.08, filter: 900 }));
});
reg('body_fall', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.18, wave: 'sine', f0: 120 * p.pitch, f1: 45, gain: 0.35 });
  s.noise(p.out, t, { dur: 0.2, type: 'lowpass', f0: 800, f1: 200, gain: 0.25 });
});
reg('footstep', (s, t, p) => s.noise(p.out, t, { dur: 0.06, type: 'lowpass', f0: 500 * p.pitch, f1: 200, gain: 0.08 }));
reg('jump', (s, t, p) => s.noise(p.out, t, { dur: 0.12, type: 'bandpass', f0: 600 * p.pitch, f1: 1400, q: 1.5, gain: 0.12 }));
reg('land', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.12, type: 'lowpass', f0: 600, f1: 150, gain: 0.25 });
  s.tone(p.out, t, { dur: 0.1, wave: 'sine', f0: 90 * p.pitch, f1: 50, gain: 0.2 });
});
reg('dodge_roll', (s, t, p) => s.noise(p.out, t, { dur: 0.22, type: 'bandpass', f0: 400 * p.pitch, f1: 1600, q: 1.2, gain: 0.2, attack: 0.03 }));
reg('whoosh', (s, t, p) => s.noise(p.out, t, { dur: 0.16, type: 'bandpass', f0: 500 * p.pitch, f1: 2200, q: 1.4, gain: 0.18, attack: 0.02 }));
reg('heavy_whoosh', (s, t, p) => s.noise(p.out, t, { dur: 0.32, type: 'bandpass', f0: 180 * p.pitch, f1: 700, q: 1.1, gain: 0.3, attack: 0.08 }));
reg('punch', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.08, wave: 'sine', f0: 180 * p.pitch, f1: 60, gain: 0.45 });
  s.noise(p.out, t, { dur: 0.07, type: 'lowpass', f0: 2500, f1: 400, gain: 0.3 });
});
reg('punch_heavy', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.18, wave: 'sine', f0: 140 * p.pitch, f1: 38, gain: 0.7 });
  s.noise(p.out, t, { dur: 0.16, type: 'lowpass', f0: 3000, f1: 250, gain: 0.45 });
});
reg('hurt', (s, t, p) => s.tone(p.out, t, { dur: 0.16, wave: 'sawtooth', f0: 260 * p.pitch, f1: 170, gain: 0.08, filter: 1200 }));
reg('death', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.6, wave: 'sawtooth', f0: 220 * p.pitch, f1: 70, gain: 0.12, filter: 900 });
  s.noise(p.out, t, { dur: 0.5, type: 'lowpass', f0: 900, f1: 100, gain: 0.2 });
});
reg('destroy_stone', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.7, type: 'lowpass', f0: 1400, f1: 120, gain: 0.5 });
  s.tone(p.out, t, { dur: 0.3, wave: 'sine', f0: 80, f1: 35, gain: 0.5 });
  for (let i = 0; i < 5; i++) s.noise(p.out, t + 0.05 + Math.random() * 0.4, { dur: 0.06, type: 'bandpass', f0: 1500 + Math.random() * 2000, q: 3, gain: 0.15 });
});
reg('destroy_wood', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.3, type: 'bandpass', f0: 900, f1: 400, q: 2, gain: 0.4 });
  for (let i = 0; i < 4; i++) s.tone(p.out, t + i * 0.03, { dur: 0.05, wave: 'square', f0: 300 + Math.random() * 400, gain: 0.05, filter: 1500 });
});
reg('enemy_spawn', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.7, wave: 'sawtooth', f0: 60, f1: 220, gain: 0.08, attack: 0.2, filter: 600 });
  s.noise(p.out, t, { dur: 0.7, type: 'bandpass', f0: 200, f1: 1200, q: 4, gain: 0.12, attack: 0.3 });
});
reg('enemy_swing', (s, t, p) => s.noise(p.out, t, { dur: 0.18, type: 'bandpass', f0: 350 * p.pitch, f1: 1300, q: 1.6, gain: 0.16, attack: 0.03 }));
reg('enemy_hit', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.08, wave: 'sine', f0: 160 * p.pitch, f1: 70, gain: 0.35 });
  s.noise(p.out, t, { dur: 0.06, type: 'bandpass', f0: 2500, q: 1, gain: 0.2 });
});
reg('enemy_bolt', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.25, wave: 'sawtooth', f0: 700 * p.pitch, f1: 200, gain: 0.06, filter: 2000 });
  s.noise(p.out, t, { dur: 0.2, type: 'bandpass', f0: 1800, f1: 600, q: 3, gain: 0.1 });
});
reg('enemy_death', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.5, wave: 'square', f0: 240 * p.pitch, f1: 50, gain: 0.07, filter: 800 });
  s.noise(p.out, t, { dur: 0.45, type: 'lowpass', f0: 1500, f1: 100, gain: 0.25 });
});
reg('heavy_slam', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.5, wave: 'sine', f0: 90, f1: 30, gain: 0.8 });
  s.noise(p.out, t, { dur: 0.6, type: 'lowpass', f0: 1200, f1: 80, gain: 0.55 });
});
reg('charge_up', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.6, wave: 'sawtooth', f0: 120 * p.pitch, f1: 480, gain: 0.07, attack: 0.3, filter: 1400 });
  s.noise(p.out, t, { dur: 0.6, type: 'bandpass', f0: 300, f1: 2000, q: 3, gain: 0.1, attack: 0.4 });
});

// ------------------------------------------------------------------ fire --
reg('fire_swing', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.2, type: 'bandpass', f0: 400 * p.pitch, f1: 1600, q: 1, gain: 0.2, attack: 0.02 });
  s.noise(p.out, t, { dur: 0.25, type: 'lowpass', f0: 600, gain: 0.08 });
});
reg('fire_hit', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.1, wave: 'sine', f0: 170 * p.pitch, f1: 60, gain: 0.45 });
  s.noise(p.out, t, { dur: 0.25, type: 'lowpass', f0: 3500, f1: 500, gain: 0.3 });
  s.noise(p.out, t + 0.02, { dur: 0.18, type: 'highpass', f0: 4000, gain: 0.07, rate: 0.5 });
});
reg('fire_heavy_hit', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.25, wave: 'sine', f0: 130 * p.pitch, f1: 35, gain: 0.75 });
  s.noise(p.out, t, { dur: 0.5, type: 'lowpass', f0: 4000, f1: 300, gain: 0.5 });
});
reg('fire_whoosh', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.45, type: 'bandpass', f0: 200 * p.pitch, f1: 1400, q: 0.8, gain: 0.45, attack: 0.04 });
  s.noise(p.out, t, { dur: 0.5, type: 'lowpass', f0: 500, gain: 0.25 });
});
reg('fire_burst', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.4, type: 'lowpass', f0: 2500 * p.pitch, f1: 300, gain: 0.45 });
  s.tone(p.out, t, { dur: 0.2, wave: 'sine', f0: 110, f1: 45, gain: 0.35 });
});
reg('fireball', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.3, type: 'bandpass', f0: 800 * p.pitch, f1: 300, q: 1.2, gain: 0.25, attack: 0.02 });
  s.tone(p.out, t, { dur: 0.2, wave: 'triangle', f0: 300 * p.pitch, f1: 120, gain: 0.08 });
});
reg('explosion', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.6, wave: 'sine', f0: 100 * p.pitch, f1: 28, gain: 0.8 });
  s.noise(p.out, t, { dur: 0.9, type: 'lowpass', f0: 3200, f1: 120, gain: 0.6 });
  s.noise(p.out, t + 0.05, { dur: 0.7, type: 'highpass', f0: 2500, gain: 0.08, rate: 0.6 });
});
reg('big_explosion', (s, t, p) => {
  s.tone(p.out, t, { dur: 1.4, wave: 'sine', f0: 80 * p.pitch, f1: 20, gain: 1.0 });
  s.noise(p.out, t, { dur: 2.2, type: 'lowpass', f0: 2600, f1: 60, gain: 0.8 });
  s.noise(p.out, t + 0.1, { dur: 1.8, type: 'bandpass', f0: 600, f1: 150, q: 0.7, gain: 0.4 });
  for (let i = 0; i < 8; i++) s.noise(p.out, t + 0.2 + Math.random() * 1.2, { dur: 0.08, type: 'highpass', f0: 3000, gain: 0.08 });
});
reg('tornado', (s, t, p) => {
  s.noise(p.out, t, { dur: 2.5, type: 'bandpass', f0: 250, f1: 700, q: 2, gain: 0.35, attack: 0.3 });
  s.noise(p.out, t, { dur: 2.5, type: 'lowpass', f0: 300, gain: 0.3, attack: 0.3 });
});
reg('crackle', (s, t, p) => {
  for (let i = 0; i < 6; i++) s.noise(p.out, t + Math.random() * 0.3, { dur: 0.03, type: 'highpass', f0: 2500 + Math.random() * 3000, gain: 0.06 });
});
reg('meteor_fall', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.6, type: 'bandpass', f0: 2500, f1: 300, q: 1.5, gain: 0.35, attack: 0.1 });
  s.tone(p.out, t, { dur: 0.6, wave: 'sawtooth', f0: 900, f1: 120, gain: 0.05, filter: 1500 });
});

// ------------------------------------------------------------- lightning --
reg('zap_swing', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.1, type: 'bandpass', f0: 1200 * p.pitch, f1: 3500, q: 2, gain: 0.15 });
  s.crackle(p.out, t, 0.06, 0.03, 1200);
});
reg('zap_hit', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.06, wave: 'sine', f0: 200 * p.pitch, f1: 80, gain: 0.3 });
  s.crackle(p.out, t, 0.12, 0.07, 900 * p.pitch);
  s.noise(p.out, t, { dur: 0.08, type: 'highpass', f0: 3000, gain: 0.12 });
});
reg('zap_heavy', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.15, wave: 'sine', f0: 160, f1: 45, gain: 0.5 });
  s.crackle(p.out, t, 0.3, 0.1, 700);
  s.noise(p.out, t, { dur: 0.3, type: 'highpass', f0: 2000, gain: 0.2 });
});
reg('blink', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.15, wave: 'sine', f0: 600 * p.pitch, f1: 3000, gain: 0.12 });
  s.crackle(p.out, t, 0.12, 0.05, 1500);
  s.noise(p.out, t, { dur: 0.15, type: 'bandpass', f0: 4000, f1: 1000, q: 2, gain: 0.1 });
});
reg('thunder', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.08, type: 'highpass', f0: 2500, gain: 0.5 });
  s.crackle(p.out, t, 0.15, 0.12, 600);
  s.noise(p.out, t + 0.03, { dur: 1.4, type: 'lowpass', f0: 900 * p.pitch, f1: 60, gain: 0.6 });
  s.tone(p.out, t, { dur: 0.5, wave: 'sine', f0: 70, f1: 30, gain: 0.5 });
});
reg('chain_zap', (s, t, p) => {
  s.crackle(p.out, t, 0.22, 0.09, 1100 * p.pitch);
  s.tone(p.out, t, { dur: 0.2, wave: 'sawtooth', f0: 1500 * p.pitch, f1: 400, gain: 0.05, filter: 3000 });
});
reg('static_field', (s, t, p) => {
  s.tone(p.out, t, { dur: 1.2, wave: 'sawtooth', f0: 60, f1: 62, gain: 0.08, attack: 0.1, filter: 500 });
  s.crackle(p.out, t, 0.5, 0.06, 900);
  s.tone(p.out, t, { dur: 0.4, wave: 'sine', f0: 300, f1: 1200, gain: 0.1 });
});
reg('spear_charge', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.35, wave: 'sawtooth', f0: 200, f1: 1800, gain: 0.07, attack: 0.1, filter: 4000 });
  s.crackle(p.out, t, 0.35, 0.04, 1200);
});
reg('spear_fire', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.3, type: 'bandpass', f0: 3000, f1: 800, q: 1.5, gain: 0.3 });
  s.tone(p.out, t, { dur: 0.25, wave: 'square', f0: 1400, f1: 200, gain: 0.06, filter: 3000 });
  s.crackle(p.out, t, 0.2, 0.08, 1000);
});
reg('storm', (s, t, p) => {
  s.noise(p.out, t, { dur: 3, type: 'lowpass', f0: 400, gain: 0.35, attack: 0.8 });
  s.tone(p.out, t, { dur: 2.5, wave: 'sawtooth', f0: 55, f1: 50, gain: 0.08, attack: 0.5, filter: 300 });
});

// ------------------------------------------------------------------ earth --
reg('stone_swing', (s, t, p) => s.noise(p.out, t, { dur: 0.35, type: 'bandpass', f0: 150 * p.pitch, f1: 500, q: 1, gain: 0.38, attack: 0.1 }));
reg('stone_hit', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.2, wave: 'sine', f0: 110 * p.pitch, f1: 40, gain: 0.75 });
  s.noise(p.out, t, { dur: 0.25, type: 'lowpass', f0: 1800, f1: 200, gain: 0.5 });
  s.noise(p.out, t, { dur: 0.05, type: 'bandpass', f0: 2200, q: 2, gain: 0.2 });
});
reg('stone_heavy', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.4, wave: 'sine', f0: 90 * p.pitch, f1: 28, gain: 1 });
  s.noise(p.out, t, { dur: 0.5, type: 'lowpass', f0: 2000, f1: 90, gain: 0.7 });
});
reg('quake', (s, t, p) => {
  s.tone(p.out, t, { dur: 1.5, wave: 'sine', f0: 55, f1: 25, gain: 1 });
  s.noise(p.out, t, { dur: 1.8, type: 'lowpass', f0: 600, f1: 60, gain: 0.8 });
  for (let i = 0; i < 10; i++) s.noise(p.out, t + Math.random() * 1.2, { dur: 0.08, type: 'bandpass', f0: 800 + Math.random() * 1500, q: 2, gain: 0.12 });
});
reg('rock_rip', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.7, type: 'lowpass', f0: 300, f1: 1400, gain: 0.5, attack: 0.3 });
  s.tone(p.out, t, { dur: 0.7, wave: 'sine', f0: 50, f1: 70, gain: 0.4, attack: 0.3 });
});
reg('rock_throw', (s, t, p) => s.noise(p.out, t, { dur: 0.4, type: 'bandpass', f0: 180, f1: 800, q: 1, gain: 0.5, attack: 0.05 }));
reg('iron_skin', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.6, type: 'bandpass', f0: 400, f1: 150, q: 3, gain: 0.35 });
  s.tone(p.out, t, { dur: 0.8, wave: 'triangle', f0: 180, f1: 170, gain: 0.2 });
  s.tone(p.out, t, { dur: 0.8, wave: 'triangle', f0: 270, gain: 0.1 });
});
reg('roar', (s, t, p) => {
  s.tone(p.out, t, { dur: 1.2, wave: 'sawtooth', f0: 90 * p.pitch, f1: 60, gain: 0.25, attack: 0.1, filter: 600 });
  s.tone(p.out, t, { dur: 1.2, wave: 'sawtooth', f0: 93 * p.pitch, f1: 62, gain: 0.2, attack: 0.1, filter: 500 });
  s.noise(p.out, t, { dur: 1.2, type: 'bandpass', f0: 300, f1: 200, q: 1, gain: 0.35, attack: 0.1 });
});
reg('giant_step', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.35, wave: 'sine', f0: 65 * p.pitch, f1: 28, gain: 0.9 });
  s.noise(p.out, t, { dur: 0.3, type: 'lowpass', f0: 500, f1: 80, gain: 0.5 });
});

// ----------------------------------------------------------------- shadow --
reg('blade_swing', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.12, type: 'bandpass', f0: 2000 * p.pitch, f1: 5000, q: 3, gain: 0.16, attack: 0.02 });
  s.tone(p.out, t, { dur: 0.12, wave: 'sine', f0: 2600 * p.pitch, f1: 1800, gain: 0.03 });
});
reg('blade_hit', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.1, type: 'bandpass', f0: 3500 * p.pitch, q: 2, gain: 0.25 });
  s.tone(p.out, t, { dur: 0.07, wave: 'sine', f0: 190, f1: 70, gain: 0.3 });
  s.tone(p.out, t, { dur: 0.15, wave: 'triangle', f0: 3200 * p.pitch, f1: 2900, gain: 0.04 });
});
reg('shadow_blink', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.3, type: 'bandpass', f0: 3000, f1: 300, q: 2, gain: 0.2 });
  s.tone(p.out, t, { dur: 0.3, wave: 'sine', f0: 900 * p.pitch, f1: 150, gain: 0.1 });
});
reg('blade_throw', (s, t, p) => s.noise(p.out, t, { dur: 0.18, type: 'bandpass', f0: 1500 * p.pitch, f1: 4500, q: 4, gain: 0.14 }));
reg('smoke', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.9, type: 'lowpass', f0: 1800, f1: 200, gain: 0.35, attack: 0.02 });
  s.noise(p.out, t, { dur: 0.6, type: 'highpass', f0: 3000, gain: 0.08 });
});
reg('clone', (s, t, p) => {
  s.tone(p.out, t, { dur: 0.4, wave: 'sine', f0: 300 * p.pitch, f1: 900, gain: 0.08 });
  s.tone(p.out, t + 0.05, { dur: 0.4, wave: 'sine', f0: 450 * p.pitch, f1: 1350, gain: 0.06 });
  s.noise(p.out, t, { dur: 0.4, type: 'bandpass', f0: 800, f1: 2400, q: 3, gain: 0.1 });
});
reg('execute', (s, t, p) => {
  s.noise(p.out, t, { dur: 0.08, type: 'highpass', f0: 4000, gain: 0.3 });
  s.tone(p.out, t, { dur: 0.35, wave: 'sine', f0: 220, f1: 40, gain: 0.6 });
  s.tone(p.out, t, { dur: 0.4, wave: 'triangle', f0: 3000, f1: 2600, gain: 0.06 });
});
reg('realm', (s, t, p) => {
  s.tone(p.out, t, { dur: 2.2, wave: 'sawtooth', f0: 55, f1: 41, gain: 0.2, attack: 0.3, filter: 400 });
  s.tone(p.out, t, { dur: 2.2, wave: 'sawtooth', f0: 82, f1: 61, gain: 0.12, attack: 0.3, filter: 500 });
  s.noise(p.out, t, { dur: 2, type: 'bandpass', f0: 2000, f1: 200, q: 2, gain: 0.2, attack: 0.5 });
});
reg('shatter', (s, t, p) => {
  s.noise(p.out, t, { dur: 1.1, type: 'highpass', f0: 2500, gain: 0.35 });
  for (let i = 0; i < 12; i++) s.tone(p.out, t + Math.random() * 0.5, { dur: 0.3, wave: 'triangle', f0: 1500 + Math.random() * 3000, gain: 0.04 });
  s.tone(p.out, t, { dur: 0.8, wave: 'sine', f0: 90, f1: 30, gain: 0.6 });
});

export class AudioManager {
  ctx: AudioContext | null = null;
  private master!: GainNode;
  private sfx!: GainNode;
  private music!: GainNode;
  private synth!: Synth;
  private recent = new Map<string, number[]>();
  readonly listener = { position: new THREE.Vector3(), right: new THREE.Vector3(1, 0, 0) };
  muted = false;
  sfxVolume = 0.8;
  musicVolume = 0.35;
  private musicOn = false;
  private musicIntensity = 0;
  private musicTarget = 0;
  private nextStep = 0;
  private step = 0;

  /** Must be called from a user gesture (browser autoplay policy). */
  unlock(): void {
    if (!this.ctx) {
      const Ctx = window.AudioContext ?? (window as any).webkitAudioContext;
      if (!Ctx) return;
      this.ctx = new Ctx();
      const ctx = this.ctx!;
      const buf = ctx.createBuffer(1, ctx.sampleRate * 2, ctx.sampleRate);
      const d = buf.getChannelData(0);
      for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
      this.synth = new Synth(ctx, buf);
      const comp = ctx.createDynamicsCompressor();
      comp.threshold.value = -14;
      comp.ratio.value = 5;
      this.master = ctx.createGain();
      this.master.gain.value = this.muted ? 0 : 1;
      this.sfx = ctx.createGain();
      this.sfx.gain.value = this.sfxVolume;
      this.music = ctx.createGain();
      this.music.gain.value = this.musicVolume * 0.5;
      this.sfx.connect(this.master);
      this.music.connect(this.master);
      this.master.connect(comp).connect(ctx.destination);
    }
    if (this.ctx.state === 'suspended') this.ctx.resume().catch(() => {});
  }

  static register(id: string, recipe: Recipe): void {
    R[id] = recipe;
  }

  has(id: string): boolean {
    return !!R[id];
  }

  setMuted(m: boolean): void {
    this.muted = m;
    if (this.master) this.master.gain.value = m ? 0 : 1;
  }

  setVolumes(sfx: number, music: number): void {
    this.sfxVolume = sfx;
    this.musicVolume = music;
    if (this.sfx) this.sfx.gain.value = sfx;
    if (this.music) this.music.gain.value = music * 0.5;
  }

  play(id: string, pos?: THREE.Vector3 | null, opts: PlayOpts = {}): void {
    const ctx = this.ctx;
    if (!ctx || this.muted || ctx.state !== 'running') return;
    const recipe = R[id];
    if (!recipe) return;
    const now = ctx.currentTime;
    // Throttle identical sounds (many simultaneous hits).
    const list = this.recent.get(id) ?? [];
    while (list.length && now - list[0] > 0.06) list.shift();
    if (list.length >= 3) return;
    list.push(now);
    this.recent.set(id, list);

    let vol = opts.volume ?? 1;
    const out = ctx.createGain();
    let node: AudioNode = out;
    if (pos) {
      const d = pos.distanceTo(this.listener.position);
      vol *= 1 / (1 + Math.max(0, d - 6) / 14);
      if (vol < 0.03) return;
      const pan = ctx.createStereoPanner();
      const dx = pos.clone().sub(this.listener.position);
      const len = dx.length() || 1;
      pan.pan.value = Math.max(-0.8, Math.min(0.8, dx.dot(this.listener.right) / len)) * Math.min(1, len / 6);
      out.connect(pan);
      node = pan;
    }
    out.gain.value = vol;
    node.connect(this.sfx);
    recipe(this.synth, now + 0.005, { pitch: opts.pitch ?? 1, out });
    setTimeout(() => {
      try {
        out.disconnect();
        node.disconnect();
      } catch {
        /* already gone */
      }
    }, 4000);
  }

  // ------------------------------------------------------------- music --
  startMusic(): void {
    this.musicOn = true;
    if (this.ctx) this.nextStep = this.ctx.currentTime + 0.1;
  }

  stopMusic(): void {
    this.musicOn = false;
  }

  /** 0 = calm (menus), 1 = full combat. */
  setIntensity(v: number): void {
    this.musicTarget = v;
  }

  update(dt: number): void {
    if (!this.ctx || !this.musicOn || this.ctx.state !== 'running') return;
    this.musicIntensity += (this.musicTarget - this.musicIntensity) * Math.min(1, dt * 0.8);
    const bpm = 126;
    const stepDur = 60 / bpm / 4;
    const ahead = this.ctx.currentTime + 0.15;
    if (this.nextStep < this.ctx.currentTime - 0.5) this.nextStep = this.ctx.currentTime + 0.05;
    while (this.nextStep < ahead) {
      this.scheduleStep(this.step, this.nextStep, stepDur);
      this.step = (this.step + 1) % 64;
      this.nextStep += stepDur;
    }
  }

  private scheduleStep(step: number, t: number, sd: number): void {
    const s = this.synth;
    const out = this.music;
    const I = this.musicIntensity;
    const bar = Math.floor(step / 16);
    const i = step % 16;
    // A minor: Am - F - C - G
    const roots = [55, 43.65, 65.41, 49];
    const chords = [
      [220, 261.6, 329.6],
      [174.6, 220, 261.6],
      [261.6, 329.6, 392],
      [196, 246.9, 293.7],
    ];
    const root = roots[bar];
    if (i === 0) for (const f of chords[bar]) s.tone(out, t, { dur: sd * 16, wave: 'triangle', f0: f, gain: 0.03 + 0.01 * (1 - I), attack: 0.4, filter: 1500 });
    if (I > 0.2) {
      if (i % 4 === 0) s.tone(out, t, { dur: 0.25, wave: 'sine', f0: 110, f1: 40, gain: 0.5 * I });
      if (i === 4 || i === 12) s.noise(out, t, { dur: 0.15, type: 'bandpass', f0: 1800, q: 0.8, gain: 0.18 * I });
      if (i % 2 === 1) s.noise(out, t, { dur: 0.04, type: 'highpass', f0: 7000, gain: 0.06 * I });
      if ([0, 3, 6, 8, 11, 14].includes(i)) s.tone(out, t, { dur: sd * 1.5, wave: 'sawtooth', f0: root * (i === 14 ? 1.5 : 1), gain: 0.12 * I, filter: 380 + 300 * I });
    }
    if (i % 2 === 0) {
      const ch = chords[bar];
      const n = ch[(i / 2) % 3] * 2;
      s.tone(out, t, { dur: sd * 1.2, wave: 'square', f0: n, gain: 0.018 + 0.02 * I, filter: 2200 });
    }
  }
}
