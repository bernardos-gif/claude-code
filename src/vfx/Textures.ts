import * as THREE from 'three';
import { fbm2, seededRandom } from '../core/math';

/**
 * Procedurally generated canvas textures (no external image assets needed).
 * Everything is cached so each texture is generated once.
 */
const cache = new Map<string, THREE.Texture>();

function canvas(size: number): [HTMLCanvasElement, CanvasRenderingContext2D] {
  const c = document.createElement('canvas');
  c.width = c.height = size;
  const ctx = c.getContext('2d')!;
  return [c, ctx];
}

function make(key: string, size: number, draw: (ctx: CanvasRenderingContext2D, size: number) => void, opts: { repeat?: boolean; srgb?: boolean } = {}): THREE.Texture {
  const hit = cache.get(key);
  if (hit) return hit;
  const [c, ctx] = canvas(size);
  draw(ctx, size);
  const tex = new THREE.CanvasTexture(c);
  if (opts.repeat) {
    tex.wrapS = tex.wrapT = THREE.RepeatWrapping;
  }
  if (opts.srgb !== false) tex.colorSpace = THREE.SRGBColorSpace;
  tex.anisotropy = 4;
  tex.needsUpdate = true;
  cache.set(key, tex);
  return tex;
}

export const Textures = {
  /** Soft round particle. */
  soft(): THREE.Texture {
    return make('soft', 64, (ctx, s) => {
      const g = ctx.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
      g.addColorStop(0, 'rgba(255,255,255,1)');
      g.addColorStop(0.25, 'rgba(255,255,255,0.8)');
      g.addColorStop(0.6, 'rgba(255,255,255,0.25)');
      g.addColorStop(1, 'rgba(255,255,255,0)');
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, s, s);
    }, { srgb: false });
  },

  /** Sharp four-point spark. */
  spark(): THREE.Texture {
    return make('spark', 64, (ctx, s) => {
      const c = s / 2;
      const g = ctx.createRadialGradient(c, c, 0, c, c, c * 0.5);
      g.addColorStop(0, 'rgba(255,255,255,1)');
      g.addColorStop(1, 'rgba(255,255,255,0)');
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, s, s);
      ctx.globalCompositeOperation = 'lighter';
      for (const [w, h] of [
        [s, 3],
        [3, s],
      ]) {
        const lg = ctx.createLinearGradient(c - w / 2, c - h / 2, c + w / 2, c + h / 2);
        lg.addColorStop(0, 'rgba(255,255,255,0)');
        lg.addColorStop(0.5, 'rgba(255,255,255,1)');
        lg.addColorStop(1, 'rgba(255,255,255,0)');
        ctx.fillStyle = lg;
        ctx.fillRect(c - w / 2, c - h / 2, w, h);
      }
    }, { srgb: false });
  },

  /** Billowy smoke puff. */
  smoke(): THREE.Texture {
    return make('smoke', 128, (ctx, s) => {
      const rnd = seededRandom(7);
      for (let i = 0; i < 22; i++) {
        const x = s / 2 + (rnd() - 0.5) * s * 0.45;
        const y = s / 2 + (rnd() - 0.5) * s * 0.45;
        const r = s * (0.14 + rnd() * 0.2);
        const g = ctx.createRadialGradient(x, y, 0, x, y, r);
        g.addColorStop(0, 'rgba(255,255,255,0.35)');
        g.addColorStop(1, 'rgba(255,255,255,0)');
        ctx.fillStyle = g;
        ctx.fillRect(0, 0, s, s);
      }
      // Circular falloff mask.
      ctx.globalCompositeOperation = 'destination-in';
      const m = ctx.createRadialGradient(s / 2, s / 2, s * 0.2, s / 2, s / 2, s / 2);
      m.addColorStop(0, 'rgba(0,0,0,1)');
      m.addColorStop(1, 'rgba(0,0,0,0)');
      ctx.fillStyle = m;
      ctx.fillRect(0, 0, s, s);
    }, { srgb: false });
  },

  /** Flame tongue (for fire particles). */
  flame(): THREE.Texture {
    return make('flame', 64, (ctx, s) => {
      const g = ctx.createRadialGradient(s / 2, s * 0.62, 0, s / 2, s * 0.55, s * 0.48);
      g.addColorStop(0, 'rgba(255,255,255,1)');
      g.addColorStop(0.35, 'rgba(255,255,255,0.7)');
      g.addColorStop(1, 'rgba(255,255,255,0)');
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.moveTo(s / 2, s * 0.02);
      ctx.bezierCurveTo(s * 0.95, s * 0.5, s * 0.85, s * 0.98, s / 2, s * 0.98);
      ctx.bezierCurveTo(s * 0.15, s * 0.98, s * 0.05, s * 0.5, s / 2, s * 0.02);
      ctx.fill();
    }, { srgb: false });
  },

  /** Ring (shockwaves). */
  ring(): THREE.Texture {
    return make('ring', 256, (ctx, s) => {
      const g = ctx.createRadialGradient(s / 2, s / 2, s * 0.3, s / 2, s / 2, s / 2);
      g.addColorStop(0, 'rgba(255,255,255,0)');
      g.addColorStop(0.7, 'rgba(255,255,255,0.35)');
      g.addColorStop(0.88, 'rgba(255,255,255,1)');
      g.addColorStop(1, 'rgba(255,255,255,0)');
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, s, s);
    }, { srgb: false });
  },

  /** Ground scorch decal. */
  scorch(): THREE.Texture {
    return make('scorch', 256, (ctx, s) => {
      const rnd = seededRandom(11);
      for (let i = 0; i < 40; i++) {
        const a = rnd() * Math.PI * 2;
        const d = rnd() * s * 0.3;
        const x = s / 2 + Math.cos(a) * d;
        const y = s / 2 + Math.sin(a) * d;
        const r = s * (0.08 + rnd() * 0.18);
        const g = ctx.createRadialGradient(x, y, 0, x, y, r);
        g.addColorStop(0, 'rgba(30,20,14,0.28)');
        g.addColorStop(1, 'rgba(30,20,14,0)');
        ctx.fillStyle = g;
        ctx.fillRect(0, 0, s, s);
      }
    });
  },

  /** Radial ground cracks decal. */
  cracks(): THREE.Texture {
    return make('cracks', 512, (ctx, s) => {
      const rnd = seededRandom(3);
      ctx.strokeStyle = 'rgba(255,255,255,1)';
      ctx.lineCap = 'round';
      const branch = (x: number, y: number, a: number, len: number, w: number, depth: number) => {
        let cx = x;
        let cy = y;
        const segs = 6;
        ctx.lineWidth = w;
        ctx.beginPath();
        ctx.moveTo(cx, cy);
        for (let i = 0; i < segs; i++) {
          a += (rnd() - 0.5) * 0.7;
          cx += Math.cos(a) * (len / segs);
          cy += Math.sin(a) * (len / segs);
          ctx.lineTo(cx, cy);
          if (depth > 0 && rnd() < 0.3) {
            ctx.stroke();
            branch(cx, cy, a + (rnd() - 0.5) * 1.6, len * 0.45, w * 0.6, depth - 1);
            ctx.lineWidth = w;
            ctx.beginPath();
            ctx.moveTo(cx, cy);
          }
        }
        ctx.stroke();
      };
      for (let i = 0; i < 9; i++) branch(s / 2, s / 2, (i / 9) * Math.PI * 2 + rnd() * 0.4, s * (0.28 + rnd() * 0.18), 7, 2);
      const g = ctx.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s * 0.12);
      g.addColorStop(0, 'rgba(255,255,255,0.9)');
      g.addColorStop(1, 'rgba(255,255,255,0)');
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, s, s);
    }, { srgb: false });
  },

  /** Arcane rune circle (Shadow realm / enemy portals). */
  runes(): THREE.Texture {
    return make('runes', 512, (ctx, s) => {
      const c = s / 2;
      ctx.strokeStyle = 'rgba(255,255,255,1)';
      ctx.lineWidth = 6;
      for (const r of [0.47, 0.4, 0.22]) {
        ctx.beginPath();
        ctx.arc(c, c, s * r, 0, Math.PI * 2);
        ctx.stroke();
      }
      ctx.lineWidth = 3;
      const rnd = seededRandom(5);
      for (let i = 0; i < 24; i++) {
        const a = (i / 24) * Math.PI * 2;
        const x = c + Math.cos(a) * s * 0.435;
        const y = c + Math.sin(a) * s * 0.435;
        ctx.save();
        ctx.translate(x, y);
        ctx.rotate(a);
        ctx.beginPath();
        const k = Math.floor(rnd() * 4);
        if (k === 0) {
          ctx.moveTo(-8, -8);
          ctx.lineTo(8, 8);
          ctx.moveTo(8, -8);
          ctx.lineTo(-8, 8);
        } else if (k === 1) {
          ctx.moveTo(0, -10);
          ctx.lineTo(8, 8);
          ctx.lineTo(-8, 8);
          ctx.closePath();
        } else if (k === 2) {
          ctx.arc(0, 0, 7, 0, Math.PI * 1.5);
        } else {
          ctx.moveTo(-9, 0);
          ctx.lineTo(9, 0);
          ctx.moveTo(0, -9);
          ctx.lineTo(0, 9);
        }
        ctx.stroke();
        ctx.restore();
      }
      // Star.
      ctx.lineWidth = 4;
      ctx.beginPath();
      for (let i = 0; i <= 5; i++) {
        const a = (i * 2 * Math.PI * 2) / 5 - Math.PI / 2;
        const x = c + Math.cos(a) * s * 0.4;
        const y = c + Math.sin(a) * s * 0.4;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      }
      ctx.stroke();
    }, { srgb: false });
  },

  /** Tileable grass/dirt ground. */
  ground(): THREE.Texture {
    return make('ground', 512, (ctx, s) => {
      const img = ctx.createImageData(s, s);
      for (let y = 0; y < s; y++) {
        for (let x = 0; x < s; x++) {
          const n = fbm2(x / 40, y / 40, 4, 1);
          const n2 = fbm2(x / 8, y / 8, 2, 9);
          const dirt = Math.max(0, Math.min(1, (n - 0.45) * 4));
          const r = 70 + n2 * 30 + dirt * 55;
          const g = 92 + n2 * 38 - dirt * 10;
          const b = 48 + n2 * 16 + dirt * 20;
          const i = (y * s + x) * 4;
          img.data[i] = r;
          img.data[i + 1] = g;
          img.data[i + 2] = b;
          img.data[i + 3] = 255;
        }
      }
      ctx.putImageData(img, 0, 0);
      // Make tileable by blending mirrored copy at edges (cheap approach).
      const rnd = seededRandom(21);
      for (let i = 0; i < 900; i++) {
        ctx.fillStyle = `rgba(${40 + rnd() * 40},${70 + rnd() * 60},${30 + rnd() * 20},0.5)`;
        ctx.fillRect(rnd() * s, rnd() * s, 1 + rnd() * 2, 3 + rnd() * 5);
      }
    }, { repeat: true });
  },

  /** Tileable stone floor tiles. */
  stoneTiles(): THREE.Texture {
    return make('stoneTiles', 512, (ctx, s) => {
      ctx.fillStyle = '#6d6a64';
      ctx.fillRect(0, 0, s, s);
      const rnd = seededRandom(33);
      const n = 4;
      const t = s / n;
      for (let y = 0; y < n; y++) {
        for (let x = 0; x < n; x++) {
          const off = y % 2 ? t / 2 : 0;
          const shade = 90 + rnd() * 40;
          ctx.fillStyle = `rgb(${shade + 8},${shade + 4},${shade})`;
          ctx.fillRect(x * t + off + 3, y * t + 3, t - 6, t - 6);
          if (off) ctx.fillRect(-t / 2 + 3, y * t + 3, t - 6, t - 6);
          for (let k = 0; k < 60; k++) {
            ctx.fillStyle = `rgba(0,0,0,${rnd() * 0.12})`;
            ctx.fillRect(x * t + off + rnd() * t, y * t + rnd() * t, 2 + rnd() * 6, 2 + rnd() * 6);
          }
        }
      }
      ctx.strokeStyle = 'rgba(30,26,22,0.8)';
      ctx.lineWidth = 3;
      for (let y = 0; y <= n; y++) {
        ctx.beginPath();
        ctx.moveTo(0, y * t);
        ctx.lineTo(s, y * t);
        ctx.stroke();
      }
    }, { repeat: true });
  },

  /** Rough rock surface. */
  rock(): THREE.Texture {
    return make('rock', 256, (ctx, s) => {
      const img = ctx.createImageData(s, s);
      for (let y = 0; y < s; y++) {
        for (let x = 0; x < s; x++) {
          const n = fbm2(x / 24, y / 24, 5, 4);
          const v = 90 + n * 110;
          const i = (y * s + x) * 4;
          img.data[i] = v;
          img.data[i + 1] = v * 0.96;
          img.data[i + 2] = v * 0.9;
          img.data[i + 3] = 255;
        }
      }
      ctx.putImageData(img, 0, 0);
    }, { repeat: true });
  },

  /** Brick / masonry for ruins walls. */
  bricks(): THREE.Texture {
    return make('bricks', 256, (ctx, s) => {
      ctx.fillStyle = '#4a4540';
      ctx.fillRect(0, 0, s, s);
      const rnd = seededRandom(44);
      const rows = 8;
      const h = s / rows;
      for (let r = 0; r < rows; r++) {
        const w = s / 4;
        const off = r % 2 ? w / 2 : 0;
        for (let c = -1; c < 5; c++) {
          const shade = 110 + rnd() * 45;
          ctx.fillStyle = `rgb(${shade},${shade * 0.95},${shade * 0.86})`;
          ctx.fillRect(c * w + off + 2, r * h + 2, w - 4, h - 4);
        }
      }
      for (let k = 0; k < 400; k++) {
        ctx.fillStyle = `rgba(0,0,0,${rnd() * 0.15})`;
        ctx.fillRect(rnd() * s, rnd() * s, 2 + rnd() * 5, 2 + rnd() * 5);
      }
    }, { repeat: true });
  },

  /** Wood planks for crates. */
  wood(): THREE.Texture {
    return make('wood', 128, (ctx, s) => {
      ctx.fillStyle = '#7a5530';
      ctx.fillRect(0, 0, s, s);
      const rnd = seededRandom(55);
      for (let i = 0; i < 4; i++) {
        ctx.fillStyle = `rgb(${110 + rnd() * 30},${75 + rnd() * 20},${40 + rnd() * 10})`;
        ctx.fillRect(4, i * (s / 4) + 3, s - 8, s / 4 - 6);
      }
      ctx.strokeStyle = '#3d2a17';
      ctx.lineWidth = 6;
      ctx.strokeRect(3, 3, s - 6, s - 6);
      ctx.beginPath();
      ctx.moveTo(6, 6);
      ctx.lineTo(s - 6, s - 6);
      ctx.stroke();
    }, { repeat: false });
  },

  /** Noise texture for shaders. */
  noise(): THREE.Texture {
    return make('noise', 256, (ctx, s) => {
      const img = ctx.createImageData(s, s);
      for (let y = 0; y < s; y++) {
        for (let x = 0; x < s; x++) {
          // Tileable via periodic sampling on a torus.
          const a = (x / s) * Math.PI * 2;
          const b = (y / s) * Math.PI * 2;
          const n = fbm2(Math.cos(a) * 3 + Math.cos(b) * 1.3 + 10, Math.sin(a) * 3 + Math.sin(b) * 1.3 + 10, 5, 2);
          const v = Math.floor(n * 255);
          const i = (y * s + x) * 4;
          img.data[i] = v;
          img.data[i + 1] = Math.floor(fbm2(x / 20 + 50, y / 20, 3, 8) * 255);
          img.data[i + 2] = v;
          img.data[i + 3] = 255;
        }
      }
      ctx.putImageData(img, 0, 0);
    }, { repeat: true, srgb: false });
  },
};
