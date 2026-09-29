import * as THREE from 'three';
import { damp } from '../core/math';

export interface Mood {
  sunIntensity: number;
  sunColor: THREE.Color;
  hemiIntensity: number;
  hemiSky: THREE.Color;
  hemiGround: THREE.Color;
  fogColor: THREE.Color;
  fogDensity: number;
  skyTop: THREE.Color;
  skyBottom: THREE.Color;
  exposure: number;
}

interface MoodLayer {
  id: string;
  mood: Partial<Mood>;
  weight: number;
  target: number;
  fadeIn: number;
  fadeOut: number;
  until: number;
}

const col = (hex: number) => new THREE.Color(hex);

/**
 * Owns the arena lights, fog and sky colours. Ultimates push temporary
 * "moods" (World Burner turns everything orange, Storm God darkens the sky,
 * Realm of Shadows goes purple) which blend in and out smoothly.
 */
export class Lighting {
  readonly sun: THREE.DirectionalLight;
  readonly hemi: THREE.HemisphereLight;
  readonly fog: THREE.FogExp2;
  readonly base: Mood;
  private layers: MoodLayer[] = [];
  private flashAmt = 0;
  private flashColor = new THREE.Color(1, 1, 1);
  private cur: Mood;
  skyUniforms: { top: { value: THREE.Color }; bottom: { value: THREE.Color } } | null = null;
  time = 0;

  constructor(private scene: THREE.Scene, private renderer: THREE.WebGLRenderer, shadowQuality: number) {
    this.base = {
      sunIntensity: 2.7,
      sunColor: col(0xffe0b5),
      hemiIntensity: 1.05,
      hemiSky: col(0xb9d3ff),
      hemiGround: col(0x5b4a3c),
      fogColor: col(0xc9b8a8),
      fogDensity: 0.0055,
      skyTop: col(0x3f6fb5),
      skyBottom: col(0xf2c9a0),
      exposure: 1.0,
    };
    this.cur = cloneMood(this.base);
    this.hemi = new THREE.HemisphereLight(this.base.hemiSky, this.base.hemiGround, this.base.hemiIntensity);
    scene.add(this.hemi);
    this.sun = new THREE.DirectionalLight(this.base.sunColor, this.base.sunIntensity);
    this.sun.position.set(40, 70, 30);
    this.sun.castShadow = shadowQuality > 0;
    const size = shadowQuality >= 2 ? 2048 : 1024;
    this.sun.shadow.mapSize.set(size, size);
    const cam = this.sun.shadow.camera;
    cam.left = -45;
    cam.right = 45;
    cam.top = 45;
    cam.bottom = -45;
    cam.near = 1;
    cam.far = 200;
    this.sun.shadow.bias = -0.0005;
    this.sun.shadow.normalBias = 0.04;
    scene.add(this.sun);
    scene.add(this.sun.target);
    this.fog = new THREE.FogExp2(this.base.fogColor.getHex(), this.base.fogDensity);
    scene.fog = this.fog;
  }

  /** Keeps the shadow frustum centred on the action. */
  follow(p: THREE.Vector3): void {
    this.sun.target.position.set(Math.round(p.x), 0, Math.round(p.z));
    this.sun.position.set(this.sun.target.position.x + 40, 70, this.sun.target.position.z + 30);
  }

  push(id: string, mood: Partial<Mood>, duration: number, fadeIn = 0.4, fadeOut = 0.8): void {
    this.layers = this.layers.filter((l) => l.id !== id);
    this.layers.push({ id, mood, weight: 0, target: 1, fadeIn, fadeOut, until: this.time + duration });
  }

  release(id: string): void {
    for (const l of this.layers) if (l.id === id) l.until = this.time;
  }

  flash(strength: number, color = 0xffffff): void {
    this.flashAmt = Math.max(this.flashAmt, strength);
    this.flashColor.set(color);
  }

  clear(): void {
    this.layers = [];
    this.flashAmt = 0;
  }

  update(dt: number): void {
    this.time += dt;
    const m = this.cur;
    copyMood(m, this.base);
    for (let i = this.layers.length - 1; i >= 0; i--) {
      const l = this.layers[i];
      l.target = this.time < l.until ? 1 : 0;
      const rate = l.target > l.weight ? 1 / Math.max(0.01, l.fadeIn) : 1 / Math.max(0.01, l.fadeOut);
      l.weight = l.target > l.weight ? Math.min(1, l.weight + dt * rate) : Math.max(0, l.weight - dt * rate);
      if (l.target === 0 && l.weight <= 0) {
        this.layers.splice(i, 1);
      }
    }
    for (const l of this.layers) blendMood(m, l.mood, l.weight);

    this.flashAmt = damp(this.flashAmt, 0, 9, dt);
    this.sun.intensity = m.sunIntensity;
    this.sun.color.copy(m.sunColor);
    this.hemi.intensity = m.hemiIntensity + this.flashAmt * 4;
    this.hemi.color.copy(m.hemiSky).lerp(this.flashColor, Math.min(1, this.flashAmt));
    this.hemi.groundColor.copy(m.hemiGround);
    this.fog.color.copy(m.fogColor);
    this.fog.density = m.fogDensity;
    this.renderer.toneMappingExposure = m.exposure + this.flashAmt * 0.6;
    if (this.skyUniforms) {
      this.skyUniforms.top.value.copy(m.skyTop).lerp(this.flashColor, Math.min(0.8, this.flashAmt * 0.5));
      this.skyUniforms.bottom.value.copy(m.skyBottom);
    }
  }
}

function cloneMood(m: Mood): Mood {
  return {
    sunIntensity: m.sunIntensity,
    sunColor: m.sunColor.clone(),
    hemiIntensity: m.hemiIntensity,
    hemiSky: m.hemiSky.clone(),
    hemiGround: m.hemiGround.clone(),
    fogColor: m.fogColor.clone(),
    fogDensity: m.fogDensity,
    skyTop: m.skyTop.clone(),
    skyBottom: m.skyBottom.clone(),
    exposure: m.exposure,
  };
}

function copyMood(dst: Mood, src: Mood): void {
  dst.sunIntensity = src.sunIntensity;
  dst.sunColor.copy(src.sunColor);
  dst.hemiIntensity = src.hemiIntensity;
  dst.hemiSky.copy(src.hemiSky);
  dst.hemiGround.copy(src.hemiGround);
  dst.fogColor.copy(src.fogColor);
  dst.fogDensity = src.fogDensity;
  dst.skyTop.copy(src.skyTop);
  dst.skyBottom.copy(src.skyBottom);
  dst.exposure = src.exposure;
}

function blendMood(dst: Mood, m: Partial<Mood>, w: number): void {
  if (w <= 0) return;
  const lerpN = (a: number, b: number | undefined) => (b === undefined ? a : a + (b - a) * w);
  dst.sunIntensity = lerpN(dst.sunIntensity, m.sunIntensity);
  dst.hemiIntensity = lerpN(dst.hemiIntensity, m.hemiIntensity);
  dst.fogDensity = lerpN(dst.fogDensity, m.fogDensity);
  dst.exposure = lerpN(dst.exposure, m.exposure);
  if (m.sunColor) dst.sunColor.lerp(m.sunColor, w);
  if (m.hemiSky) dst.hemiSky.lerp(m.hemiSky, w);
  if (m.hemiGround) dst.hemiGround.lerp(m.hemiGround, w);
  if (m.fogColor) dst.fogColor.lerp(m.fogColor, w);
  if (m.skyTop) dst.skyTop.lerp(m.skyTop, w);
  if (m.skyBottom) dst.skyBottom.lerp(m.skyBottom, w);
}

export const moodColor = col;
