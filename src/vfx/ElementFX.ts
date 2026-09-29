import * as THREE from 'three';
import type { VFXManager } from './VFXManager';
import { Textures } from './Textures';
import { rand, TAU } from '../core/math';

/**
 * Element-specific effect recipes. Each fighter's visual identity is built
 * from its own family here (fire / lightning / earth / shadow), so no two
 * characters share the same look.
 */

const UP = new THREE.Vector3(0, 1, 0);

// ---------------------------------------------------------------- shaders --
const noiseTex = () => Textures.noise();

export function fireGroundMaterial(opacity = 1): THREE.ShaderMaterial {
  return new THREE.ShaderMaterial({
    uniforms: {
      uTime: { value: 0 },
      uNoise: { value: noiseTex() },
      uOpacity: { value: opacity },
      uSeed: { value: Math.random() * 10 },
    },
    transparent: true,
    depthWrite: false,
    blending: THREE.AdditiveBlending,
    vertexShader: /* glsl */ `
      varying vec2 vUv;
      void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
    fragmentShader: /* glsl */ `
      uniform float uTime; uniform sampler2D uNoise; uniform float uOpacity; uniform float uSeed;
      varying vec2 vUv;
      void main() {
        vec2 c = vUv - 0.5;
        float r = length(c) * 2.0;
        float n1 = texture2D(uNoise, vUv * 1.7 + vec2(uTime * 0.13, uTime * 0.21) + uSeed).r;
        float n2 = texture2D(uNoise, vUv * 3.1 - vec2(uTime * 0.27, uTime * 0.11) + uSeed).r;
        float n = n1 * 0.6 + n2 * 0.6;
        float edge = smoothstep(1.0, 0.55, r + (n - 0.6) * 0.5);
        float flame = smoothstep(0.35, 0.95, n) * edge;
        vec3 col = mix(vec3(0.9, 0.12, 0.0), vec3(1.0, 0.75, 0.2), smoothstep(0.5, 1.0, n));
        col += vec3(1.0, 0.95, 0.6) * smoothstep(0.85, 1.1, n);
        float a = (flame * 1.2 + edge * 0.18) * uOpacity;
        gl_FragColor = vec4(col * a, a);
      }`,
  });
}

export function tornadoMaterial(): THREE.ShaderMaterial {
  return new THREE.ShaderMaterial({
    uniforms: { uTime: { value: 0 }, uNoise: { value: noiseTex() }, uOpacity: { value: 1 } },
    transparent: true,
    depthWrite: false,
    side: THREE.DoubleSide,
    blending: THREE.AdditiveBlending,
    vertexShader: /* glsl */ `
      varying vec2 vUv;
      void main() { vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
    fragmentShader: /* glsl */ `
      uniform float uTime; uniform sampler2D uNoise; uniform float uOpacity;
      varying vec2 vUv;
      void main() {
        vec2 uv = vec2(vUv.x * 2.0 + uTime * 1.6 + vUv.y * 0.8, vUv.y * 1.2 - uTime * 1.2);
        float n = texture2D(uNoise, uv).r;
        float n2 = texture2D(uNoise, uv * 2.3 + 0.3).r;
        float f = smoothstep(0.45, 0.9, n * 0.7 + n2 * 0.5);
        float vfade = smoothstep(0.0, 0.15, vUv.y) * smoothstep(1.0, 0.6, vUv.y);
        vec3 col = mix(vec3(1.0, 0.25, 0.02), vec3(1.0, 0.85, 0.35), f);
        float a = f * vfade * uOpacity;
        gl_FragColor = vec4(col * a * 1.4, a);
      }`,
  });
}

export function energyDomeMaterial(color: THREE.Color, secondary: THREE.Color): THREE.ShaderMaterial {
  return new THREE.ShaderMaterial({
    uniforms: {
      uTime: { value: 0 },
      uNoise: { value: noiseTex() },
      uColor: { value: color },
      uColor2: { value: secondary },
      uOpacity: { value: 1 },
    },
    transparent: true,
    depthWrite: false,
    side: THREE.DoubleSide,
    blending: THREE.AdditiveBlending,
    vertexShader: /* glsl */ `
      varying vec2 vUv; varying vec3 vN; varying vec3 vV;
      void main() {
        vUv = uv;
        vec4 mv = modelViewMatrix * vec4(position, 1.0);
        vN = normalize(normalMatrix * normal);
        vV = normalize(-mv.xyz);
        gl_Position = projectionMatrix * mv;
      }`,
    fragmentShader: /* glsl */ `
      uniform float uTime; uniform sampler2D uNoise; uniform vec3 uColor; uniform vec3 uColor2; uniform float uOpacity;
      varying vec2 vUv; varying vec3 vN; varying vec3 vV;
      void main() {
        float fres = pow(1.0 - abs(dot(vN, vV)), 3.0);
        float n = texture2D(uNoise, vUv * vec2(3.0, 1.5) + vec2(uTime * 0.4, -uTime * 0.7)).r;
        float band = smoothstep(0.9, 0.2, vUv.y);
        float arcs = smoothstep(0.008, 0.0, abs(n - 0.55)) * 0.55 * band;
        vec3 col = uColor * fres * 1.1 + uColor2 * arcs;
        float a = (fres * 0.6 + arcs) * uOpacity;
        gl_FragColor = vec4(col * uOpacity, a);
      }`,
  });
}

export function voidDomeMaterial(): THREE.ShaderMaterial {
  return new THREE.ShaderMaterial({
    uniforms: { uTime: { value: 0 }, uNoise: { value: noiseTex() }, uOpacity: { value: 1 } },
    transparent: true,
    depthWrite: false,
    side: THREE.BackSide,
    fog: false,
    vertexShader: /* glsl */ `
      varying vec2 vUv; varying vec3 vP;
      void main() { vUv = uv; vP = position; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0); }`,
    fragmentShader: /* glsl */ `
      uniform float uTime; uniform sampler2D uNoise; uniform float uOpacity;
      varying vec2 vUv; varying vec3 vP;
      void main() {
        vec2 uv = vUv * vec2(3.0, 1.5);
        float n = texture2D(uNoise, uv + vec2(uTime * 0.05, uTime * 0.03)).r;
        float n2 = texture2D(uNoise, uv * 2.0 - vec2(uTime * 0.08, 0.0)).g;
        float swirl = smoothstep(0.45, 0.8, n * 0.7 + n2 * 0.5);
        vec3 base = mix(vec3(0.03, 0.0, 0.06), vec3(0.16, 0.02, 0.28), swirl);
        float h = normalize(vP).y;
        base += vec3(0.5, 0.1, 0.8) * smoothstep(0.02, 0.0, abs(n - 0.6)) * 0.8;
        base += vec3(0.25, 0.0, 0.4) * smoothstep(0.3, -0.1, h) * 0.6;
        gl_FragColor = vec4(base, uOpacity * 0.97);
      }`,
  });
}

// ------------------------------------------------------------------ Fire --
export const FireFX = {
  colors: [0xffd27a, 0xff9a2e, 0xff5a14],

  burst(vfx: VFXManager, pos: THREE.Vector3, scale = 1, dir?: THREE.Vector3): void {
    vfx.emit('flame', pos, 14 * scale, { speed: [2, 6 * scale], dir, spread: dir ? 0.5 : 1, life: [0.25, 0.5], size: [0.6 * scale, 1.2 * scale], sizeEnd: 0.3, color: this.colors, colorEnd: 0x8a1a00, drag: 3, gravity: -4 });
    vfx.emit('spark', pos, 10 * scale, { speed: [4, 10 * scale], dir, spread: 0.8, life: [0.3, 0.7], size: [0.15, 0.3], sizeEnd: 0.2, color: 0xffc060, colorEnd: 0xff3000, gravity: 6, drag: 1 });
    vfx.emit('smoke', pos, 3 * scale, { speed: [0.5, 1.5], life: [0.8, 1.3], size: [0.8 * scale, 1.2 * scale], sizeEnd: 2.2, color: 0x2a221e, alpha: 0.45, gravity: -1.5, drag: 1 });
  },

  explosion(vfx: VFXManager, pos: THREE.Vector3, radius: number): void {
    vfx.sphere(pos, 0xff8a2a, radius * 0.9, 0.35, 0.7);
    vfx.sphere(pos, 0xfff0b0, radius * 0.45, 0.2, 0.9);
    vfx.ring(pos.clone().setY(vfx.groundFn(pos.x, pos.z)), 0xff7a20, radius * 1.3, 0.5);
    vfx.emit('flame', pos, 40 + radius * 6, { speed: [radius * 1.5, radius * 4], life: [0.35, 0.7], size: [1, 2.2], sizeEnd: 0.4, color: this.colors, colorEnd: 0x7a1400, drag: 3.5, gravity: -3 });
    vfx.emit('spark', pos, 26 + radius * 3, { speed: [6, 18], life: [0.5, 1.2], size: [0.18, 0.35], sizeEnd: 0.2, color: 0xffd080, colorEnd: 0xff3000, gravity: 9, drag: 0.6 });
    vfx.emit('smoke', pos, 10 + radius * 1.5, { speed: [1, radius * 1.2], life: [1.2, 2.2], size: [1.5, 2.5], sizeEnd: 2.8, color: 0x2b2420, alpha: 0.55, gravity: -2, drag: 1.4, jitter: radius * 0.3 });
    vfx.flash(pos.clone().setY(pos.y + 1), 0xff7a2a, 40 + radius * 8, radius * 4, 0.45);
    vfx.decal(pos, radius * 0.9, Textures.scorch(), 0xffffff, 6, { opacity: 0.9 });
  },

  trailPuff(vfx: VFXManager, pos: THREE.Vector3): void {
    vfx.emit('flame', pos, 3, { speed: [0.5, 1.5], dir: UP, spread: 0.5, life: [0.3, 0.6], size: [0.5, 0.9], sizeEnd: 0.2, color: this.colors, colorEnd: 0x901800, gravity: -4, jitter: 0.25 });
    if (Math.random() < 0.4) vfx.emit('spark', pos, 1, { speed: [1, 3], dir: UP, spread: 0.6, life: [0.4, 0.9], size: 0.12, color: 0xffb040, gravity: -1 });
  },

  embers(vfx: VFXManager, pos: THREE.Vector3, count = 1, jitter = 0.4): void {
    vfx.emit('spark', pos, count, { speed: [0.4, 1.4], dir: UP, spread: 0.7, life: [0.6, 1.3], size: [0.08, 0.16], sizeEnd: 0.3, color: [0xffb040, 0xff7020], gravity: -1.5, jitter });
  },

  fireball(radius = 0.45): THREE.Object3D {
    const g = new THREE.Group();
    const core = new THREE.Mesh(new THREE.SphereGeometry(radius * 0.6, 12, 10), new THREE.MeshBasicMaterial({ color: 0xfff0a0 }));
    const shell = new THREE.Mesh(
      new THREE.SphereGeometry(radius, 14, 10),
      new THREE.MeshBasicMaterial({ color: 0xff6a10, transparent: true, opacity: 0.7, blending: THREE.AdditiveBlending, depthWrite: false }),
    );
    const halo = new THREE.Sprite(new THREE.SpriteMaterial({ map: Textures.soft(), color: 0xff7a20, blending: THREE.AdditiveBlending, depthWrite: false, transparent: true, opacity: 0.9 }));
    halo.scale.setScalar(radius * 5);
    g.add(core, shell, halo);
    return g;
  },

  /** Animated burning-ground patch (returns the mesh; caller owns lifetime). */
  groundPatch(vfx: VFXManager, radius: number, opacity = 1): THREE.Mesh {
    const mat = vfx.animate(fireGroundMaterial(opacity));
    const m = new THREE.Mesh(new THREE.PlaneGeometry(radius * 2, radius * 2), mat);
    m.rotation.x = -Math.PI / 2;
    m.renderOrder = 3;
    return m;
  },
};

// ------------------------------------------------------------- Lightning --
export const LightningFX = {
  colors: [0xbfe8ff, 0x6fc8ff, 0xffffff],

  sparks(vfx: VFXManager, pos: THREE.Vector3, count = 12, speed = 10, dir?: THREE.Vector3): void {
    vfx.emit('spark', pos, count, { speed: [speed * 0.4, speed], dir, spread: dir ? 0.6 : 1, life: [0.12, 0.35], size: [0.18, 0.35], sizeEnd: 0.1, color: this.colors, colorEnd: 0x2a7fff, drag: 4 });
    vfx.emit('glow', pos, Math.ceil(count / 3), { speed: [0.5, 2], life: [0.1, 0.25], size: [0.8, 1.4], sizeEnd: 0.3, color: 0x7fd0ff, colorEnd: 0x2050ff });
  },

  arcBurst(vfx: VFXManager, pos: THREE.Vector3, radius = 1.6, count = 4): void {
    for (let i = 0; i < count; i++) {
      const end = pos.clone().add(new THREE.Vector3(rand(-1, 1), rand(-0.6, 1), rand(-1, 1)).normalize().multiplyScalar(radius * rand(0.6, 1)));
      vfx.bolt(pos, end, 0x7fd0ff, { width: 0.06, jag: 0.45, dur: 0.12, branches: 0 });
    }
    this.sparks(vfx, pos, 8, 8);
  },

  strike(vfx: VFXManager, ground: THREE.Vector3, height = 30, radius = 3): void {
    const top = ground.clone().add(new THREE.Vector3(rand(-3, 3), height, rand(-3, 3)));
    vfx.bolt(top, ground, 0x9fdcff, { width: 0.35, jag: 0.18, dur: 0.3, branches: 4 });
    vfx.bolt(top, ground, 0xffffff, { width: 0.12, jag: 0.12, dur: 0.18, branches: 1 });
    vfx.ring(ground, 0x6fc8ff, radius * 1.4, 0.35);
    vfx.sphere(ground.clone().setY(ground.y + 0.5), 0xcfefff, radius * 0.7, 0.2, 0.9);
    this.sparks(vfx, ground.clone().setY(ground.y + 0.3), 26, 14, UP);
    vfx.emit('dust', ground, 8, { speed: [2, 5], life: [0.5, 0.9], size: [1, 1.6], sizeEnd: 2, color: 0x8a90a0, alpha: 0.4, drag: 2, radial: 3, disc: 0.5 });
    vfx.flash(ground.clone().setY(ground.y + 2), 0x9fd8ff, 70, 24, 0.3);
    vfx.decal(ground, radius * 0.7, Textures.scorch(), 0xffffff, 3, { opacity: 0.7 });
  },

  /** Spear-like projectile mesh. */
  spear(length = 2.4): THREE.Object3D {
    const g = new THREE.Group();
    const core = new THREE.Mesh(new THREE.OctahedronGeometry(0.22, 0), new THREE.MeshBasicMaterial({ color: 0xffffff }));
    core.scale.set(1, 1, length * 2.2);
    const glow = new THREE.Mesh(
      new THREE.OctahedronGeometry(0.4, 0),
      new THREE.MeshBasicMaterial({ color: 0x4fb0ff, transparent: true, opacity: 0.6, blending: THREE.AdditiveBlending, depthWrite: false }),
    );
    glow.scale.set(1, 1, length * 1.6);
    const halo = new THREE.Sprite(new THREE.SpriteMaterial({ map: Textures.soft(), color: 0x6fc8ff, blending: THREE.AdditiveBlending, depthWrite: false, transparent: true }));
    halo.scale.setScalar(2.6);
    g.add(core, glow, halo);
    return g;
  },
};

// ------------------------------------------------------------------ Earth --
export const EarthFX = {
  dust(vfx: VFXManager, pos: THREE.Vector3, radius = 2, count = 12): void {
    vfx.emit('dust', pos, count, { speed: [1, 3], life: [0.7, 1.4], size: [1.2, 2.2], sizeEnd: 2.2, color: [0x9c8a70, 0x8a7a64, 0xb0a088], alpha: 0.55, drag: 2, radial: radius * 1.5, disc: radius * 0.4, gravity: -0.4 });
  },

  impact(vfx: VFXManager, pos: THREE.Vector3, radius: number, debris = 10): void {
    const g = pos.clone().setY(vfx.groundFn(pos.x, pos.z));
    vfx.ring(g, 0xd8b890, radius * 1.3, 0.55, { blend: THREE.NormalBlending, opacity: 0.8 });
    vfx.ring(g, 0xffe0a0, radius, 0.3, { opacity: 0.5 });
    this.dust(vfx, g, radius, 14 + radius * 2);
    vfx.spawnDebris(g.clone().setY(g.y + 0.3), debris, 0x7d7064, { force: 5 + radius, size: 0.28 });
    vfx.decal(g, radius * 1.1, Textures.cracks(), 0x4a3a2c, 7, { opacity: 0.85 });
  },

  shockwaveRing(vfx: VFXManager, pos: THREE.Vector3, radius: number, dur: number): void {
    vfx.ring(pos, 0xc8a878, radius, dur, { blend: THREE.NormalBlending, opacity: 0.85, start: 1 });
    vfx.ring(pos, 0xfff0c0, radius, dur * 0.8, { opacity: 0.4, start: 1 });
  },

  /** A rock spike that erupts from the ground and sinks again. */
  spike(vfx: VFXManager, pos: THREE.Vector3, height = 2.5, dur = 1.1, tilt = 0.2): void {
    const mat = new THREE.MeshStandardMaterial({ color: 0x7a6d60, roughness: 0.95, flatShading: true });
    const m = new THREE.Mesh(new THREE.ConeGeometry(height * 0.28, height, 6), mat);
    m.castShadow = true;
    const g = vfx.groundFn(pos.x, pos.z);
    m.position.set(pos.x, g - height, pos.z);
    m.rotation.set(rand(-tilt, tilt), rand(0, TAU), rand(-tilt, tilt));
    vfx.addTimed(m, dur, (t) => {
      const up = t < 0.15 ? t / 0.15 : t > 0.75 ? 1 - (t - 0.75) / 0.25 : 1;
      const e = 1 - Math.pow(1 - up, 3);
      m.position.y = g - height * 0.5 + (e - 1) * height + height * 0.05;
    }, () => {
      m.geometry.dispose();
      mat.dispose();
    });
  },

  rock(size = 1.2): THREE.Mesh {
    const m = new THREE.Mesh(new THREE.DodecahedronGeometry(size, 1), new THREE.MeshStandardMaterial({ map: Textures.rock(), color: 0x9a8b7a, roughness: 0.95, flatShading: true }));
    const pos = m.geometry.attributes.position as THREE.BufferAttribute;
    for (let i = 0; i < pos.count; i++) {
      const k = 0.85 + Math.random() * 0.3;
      pos.setXYZ(i, pos.getX(i) * k, pos.getY(i) * k, pos.getZ(i) * k);
    }
    m.geometry.computeVertexNormals();
    m.castShadow = true;
    return m;
  },
};

// ----------------------------------------------------------------- Shadow --
export const ShadowFX = {
  colors: [0xb05cff, 0x7a2cff, 0xe0a0ff],

  puff(vfx: VFXManager, pos: THREE.Vector3, scale = 1): void {
    vfx.emit('dark', pos, 16 * scale, { speed: [1, 3.5 * scale], life: [0.5, 1], size: [0.9 * scale, 1.6 * scale], sizeEnd: 1.8, color: [0x140a1e, 0x1e0c2c, 0x0a0610], alpha: 0.85, drag: 2.5, gravity: -0.6, jitter: 0.3 * scale, jitterY: 0.6 * scale });
    vfx.emit('glow', pos, 10 * scale, { speed: [2, 5 * scale], life: [0.25, 0.5], size: [0.3, 0.6], sizeEnd: 0.1, color: this.colors, colorEnd: 0x3a0080, drag: 3, jitterY: 0.6 });
    vfx.emit('spark', pos, 6 * scale, { speed: [3, 7], life: [0.2, 0.45], size: [0.15, 0.25], color: 0xd9a0ff, colorEnd: 0x5a00c0, drag: 2 });
  },

  wisp(vfx: VFXManager, pos: THREE.Vector3, count = 1): void {
    vfx.emit('dark', pos, count, { speed: [0.2, 0.8], dir: UP, spread: 0.6, life: [0.5, 0.9], size: [0.4, 0.7], sizeEnd: 1.6, color: 0x160a22, alpha: 0.6, gravity: -1, jitter: 0.3 });
    vfx.emit('glow', pos, count, { speed: [0.2, 1], dir: UP, spread: 0.5, life: [0.3, 0.6], size: [0.15, 0.3], color: 0xa050ff, colorEnd: 0x300060, gravity: -1, jitter: 0.3 });
  },

  cut(vfx: VFXManager, pos: THREE.Vector3, dir: THREE.Vector3, len = 2.4, color = 0xc080ff): void {
    const side = new THREE.Vector3().crossVectors(dir, UP).normalize();
    const tilt = new THREE.Vector3(0, rand(-0.8, 0.8), 0);
    const a = pos.clone().addScaledVector(side, -len * 0.5).add(tilt);
    const b = pos.clone().addScaledVector(side, len * 0.5).sub(tilt);
    vfx.beam(a, b, color, 0.18, 0.2);
    vfx.beam(a, b, 0xffffff, 0.06, 0.12);
  },
};

// -------------------------------------------------------------- Generic --
export const GenericFX = {
  impact(vfx: VFXManager, pos: THREE.Vector3, color: number, strength = 1): void {
    vfx.emit('spark', pos, 6 + strength * 6, { speed: [3, 9 * strength], life: [0.12, 0.3], size: [0.15, 0.3], sizeEnd: 0.1, color: [0xffffff, color], colorEnd: color, drag: 4 });
    vfx.emit('glow', pos, 2, { speed: 0.2, life: 0.12, size: 1.2 * strength, sizeEnd: 1.6, color, colorEnd: color });
  },
};
