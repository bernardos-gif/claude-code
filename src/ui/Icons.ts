import type { IconGlyph, IconSpec } from '../data/types';

/**
 * Procedural vector icons for abilities and portraits (canvas → data URL).
 * Each glyph is drawn from primitive paths so no image files are needed.
 */
type Draw = (c: CanvasRenderingContext2D, s: number) => void;

const person = (c: CanvasRenderingContext2D, x: number, y: number, h: number) => {
  c.beginPath();
  c.arc(x, y - h * 0.38, h * 0.13, 0, Math.PI * 2);
  c.fill();
  c.beginPath();
  c.moveTo(x - h * 0.2, y + h * 0.5);
  c.quadraticCurveTo(x - h * 0.22, y - h * 0.2, x, y - h * 0.22);
  c.quadraticCurveTo(x + h * 0.22, y - h * 0.2, x + h * 0.2, y + h * 0.5);
  c.closePath();
  c.fill();
};

const bolt = (c: CanvasRenderingContext2D, x: number, y: number, h: number, w = h * 0.45) => {
  c.beginPath();
  c.moveTo(x + w * 0.2, y - h / 2);
  c.lineTo(x - w * 0.5, y + h * 0.05);
  c.lineTo(x - w * 0.02, y + h * 0.05);
  c.lineTo(x - w * 0.25, y + h / 2);
  c.lineTo(x + w * 0.5, y - h * 0.08);
  c.lineTo(x + w * 0.02, y - h * 0.08);
  c.closePath();
  c.fill();
};

const fist = (c: CanvasRenderingContext2D, x: number, y: number, r: number) => {
  c.beginPath();
  c.roundRect(x - r, y - r * 0.8, r * 2, r * 1.6, r * 0.35);
  c.fill();
  c.save();
  c.globalCompositeOperation = 'destination-out';
  c.lineWidth = r * 0.12;
  for (let i = 1; i < 4; i++) {
    c.beginPath();
    c.moveTo(x - r + (i * r * 2) / 4, y - r * 0.8);
    c.lineTo(x - r + (i * r * 2) / 4, y - r * 0.1);
    c.stroke();
  }
  c.beginPath();
  c.moveTo(x - r * 0.9, y + r * 0.05);
  c.lineTo(x + r * 0.4, y + r * 0.05);
  c.stroke();
  c.restore();
};

const rays = (c: CanvasRenderingContext2D, x: number, y: number, r0: number, r1: number, n: number, rot = 0) => {
  c.beginPath();
  for (let i = 0; i < n; i++) {
    const a = rot + (i / n) * Math.PI * 2;
    c.moveTo(x + Math.cos(a) * r0, y + Math.sin(a) * r0);
    c.lineTo(x + Math.cos(a) * r1, y + Math.sin(a) * r1);
  }
  c.stroke();
};

const G: Record<IconGlyph, Draw> = {
  dash(c, s) {
    c.lineWidth = s * 0.05;
    c.lineCap = 'round';
    for (let i = 0; i < 4; i++) {
      c.beginPath();
      c.moveTo(s * 0.12, s * (0.3 + i * 0.13));
      c.lineTo(s * (0.4 + (i % 2) * 0.08), s * (0.3 + i * 0.13));
      c.stroke();
    }
    c.beginPath();
    c.moveTo(s * 0.45, s * 0.2);
    c.lineTo(s * 0.85, s * 0.5);
    c.lineTo(s * 0.45, s * 0.8);
    c.lineTo(s * 0.58, s * 0.5);
    c.closePath();
    c.fill();
  },
  fist(c, s) {
    fist(c, s * 0.46, s * 0.52, s * 0.22);
    c.lineWidth = s * 0.04;
    rays(c, s * 0.46, s * 0.52, s * 0.3, s * 0.42, 9, 0.2);
  },
  fireballs(c, s) {
    for (const [x, y, r] of [
      [0.3, 0.35, 0.1],
      [0.62, 0.3, 0.08],
      [0.55, 0.65, 0.12],
    ]) {
      c.beginPath();
      c.arc(s * x, s * y, s * r, 0, Math.PI * 2);
      c.fill();
      c.beginPath();
      c.moveTo(s * (x - r * 0.9), s * (y - r * 0.4));
      c.lineTo(s * (x - r * 3), s * (y + r * 1.8));
      c.lineTo(s * (x + r * 0.2), s * (y + r * 0.9));
      c.closePath();
      c.globalAlpha = 0.6;
      c.fill();
      c.globalAlpha = 1;
    }
  },
  tornado(c, s) {
    c.lineWidth = s * 0.055;
    c.lineCap = 'round';
    for (let i = 0; i < 6; i++) {
      const w = s * (0.36 - i * 0.052);
      const y = s * (0.2 + i * 0.12);
      const x = s * (0.5 + Math.sin(i * 0.9) * 0.05);
      c.beginPath();
      c.ellipse(x, y, w, s * 0.035, 0, 0, Math.PI * 2);
      c.stroke();
    }
  },
  meteor(c, s) {
    c.beginPath();
    c.moveTo(s * 0.12, s * 0.12);
    c.lineTo(s * 0.62, s * 0.52);
    c.lineTo(s * 0.5, s * 0.66);
    c.closePath();
    c.globalAlpha = 0.55;
    c.fill();
    c.globalAlpha = 1;
    c.beginPath();
    c.arc(s * 0.64, s * 0.64, s * 0.17, 0, Math.PI * 2);
    c.fill();
    c.lineWidth = s * 0.04;
    c.beginPath();
    c.moveTo(s * 0.35, s * 0.9);
    c.lineTo(s * 0.92, s * 0.9);
    c.stroke();
  },
  nova(c, s) {
    c.lineWidth = s * 0.05;
    c.lineCap = 'round';
    rays(c, s / 2, s / 2, s * 0.2, s * 0.44, 12);
    c.beginPath();
    c.arc(s / 2, s / 2, s * 0.15, 0, Math.PI * 2);
    c.fill();
  },
  blink(c, s) {
    c.globalAlpha = 0.35;
    person(c, s * 0.3, s * 0.55, s * 0.55);
    c.globalAlpha = 1;
    person(c, s * 0.72, s * 0.55, s * 0.55);
    bolt(c, s * 0.5, s * 0.5, s * 0.5, s * 0.22);
  },
  thunderFist(c, s) {
    fist(c, s * 0.42, s * 0.56, s * 0.2);
    bolt(c, s * 0.74, s * 0.34, s * 0.42, s * 0.24);
  },
  chain(c, s) {
    const pts = [
      [0.18, 0.72],
      [0.42, 0.3],
      [0.62, 0.62],
      [0.84, 0.25],
    ];
    c.lineWidth = s * 0.05;
    c.lineJoin = 'round';
    c.beginPath();
    pts.forEach(([x, y], i) => (i ? c.lineTo(s * x, s * y) : c.moveTo(s * x, s * y)));
    c.stroke();
    for (const [x, y] of pts) {
      c.beginPath();
      c.arc(s * x, s * y, s * 0.07, 0, Math.PI * 2);
      c.fill();
    }
  },
  field(c, s) {
    c.lineWidth = s * 0.05;
    c.beginPath();
    c.arc(s / 2, s * 0.72, s * 0.36, Math.PI, 0);
    c.stroke();
    c.beginPath();
    c.moveTo(s * 0.1, s * 0.72);
    c.lineTo(s * 0.9, s * 0.72);
    c.stroke();
    bolt(c, s * 0.38, s * 0.55, s * 0.3, s * 0.16);
    bolt(c, s * 0.62, s * 0.52, s * 0.32, s * 0.16);
  },
  spear(c, s) {
    c.lineWidth = s * 0.06;
    c.lineCap = 'round';
    c.beginPath();
    c.moveTo(s * 0.15, s * 0.85);
    c.lineTo(s * 0.7, s * 0.3);
    c.stroke();
    c.beginPath();
    c.moveTo(s * 0.88, s * 0.12);
    c.lineTo(s * 0.62, s * 0.24);
    c.lineTo(s * 0.76, s * 0.38);
    c.closePath();
    c.fill();
    c.lineWidth = s * 0.03;
    rays(c, s * 0.8, s * 0.2, s * 0.14, s * 0.2, 6, 0.5);
  },
  storm(c, s) {
    c.beginPath();
    c.arc(s * 0.35, s * 0.35, s * 0.14, 0, Math.PI * 2);
    c.arc(s * 0.55, s * 0.28, s * 0.17, 0, Math.PI * 2);
    c.arc(s * 0.72, s * 0.38, s * 0.12, 0, Math.PI * 2);
    c.rect(s * 0.22, s * 0.38, s * 0.58, s * 0.12);
    c.fill();
    bolt(c, s * 0.4, s * 0.7, s * 0.34, s * 0.18);
    bolt(c, s * 0.66, s * 0.72, s * 0.3, s * 0.16);
  },
  quake(c, s) {
    c.lineWidth = s * 0.05;
    c.lineCap = 'round';
    for (let i = 0; i < 3; i++) {
      c.beginPath();
      c.arc(s / 2, s * 0.62, s * (0.14 + i * 0.12), Math.PI * 1.1, Math.PI * 1.9);
      c.stroke();
    }
    c.beginPath();
    c.moveTo(s * 0.08, s * 0.72);
    c.lineTo(s * 0.92, s * 0.72);
    c.stroke();
    c.lineWidth = s * 0.035;
    c.beginPath();
    c.moveTo(s * 0.5, s * 0.72);
    c.lineTo(s * 0.44, s * 0.82);
    c.lineTo(s * 0.52, s * 0.9);
    c.moveTo(s * 0.3, s * 0.72);
    c.lineTo(s * 0.24, s * 0.86);
    c.moveTo(s * 0.7, s * 0.72);
    c.lineTo(s * 0.78, s * 0.84);
    c.stroke();
  },
  rock(c, s) {
    c.beginPath();
    const pts = [
      [0.35, 0.22],
      [0.62, 0.18],
      [0.82, 0.38],
      [0.78, 0.66],
      [0.52, 0.8],
      [0.26, 0.7],
      [0.18, 0.45],
    ];
    pts.forEach(([x, y], i) => (i ? c.lineTo(s * x, s * y) : c.moveTo(s * x, s * y)));
    c.closePath();
    c.fill();
    c.save();
    c.globalCompositeOperation = 'destination-out';
    c.lineWidth = s * 0.03;
    c.beginPath();
    c.moveTo(s * 0.4, s * 0.3);
    c.lineTo(s * 0.5, s * 0.5);
    c.lineTo(s * 0.68, s * 0.55);
    c.stroke();
    c.restore();
    c.lineWidth = s * 0.035;
    c.lineCap = 'round';
    for (let i = 0; i < 3; i++) {
      c.beginPath();
      c.moveTo(s * 0.05, s * (0.72 + i * 0.08));
      c.lineTo(s * 0.2, s * (0.66 + i * 0.08));
      c.stroke();
    }
  },
  charge(c, s) {
    c.beginPath();
    c.moveTo(s * 0.12, s * 0.3);
    c.lineTo(s * 0.55, s * 0.3);
    c.lineTo(s * 0.55, s * 0.15);
    c.lineTo(s * 0.9, s * 0.5);
    c.lineTo(s * 0.55, s * 0.85);
    c.lineTo(s * 0.55, s * 0.7);
    c.lineTo(s * 0.12, s * 0.7);
    c.closePath();
    c.fill();
  },
  shield(c, s) {
    c.beginPath();
    c.moveTo(s / 2, s * 0.12);
    c.lineTo(s * 0.82, s * 0.24);
    c.quadraticCurveTo(s * 0.8, s * 0.7, s / 2, s * 0.9);
    c.quadraticCurveTo(s * 0.2, s * 0.7, s * 0.18, s * 0.24);
    c.closePath();
    c.fill();
    c.save();
    c.globalCompositeOperation = 'destination-out';
    c.lineWidth = s * 0.03;
    c.beginPath();
    c.moveTo(s * 0.3, s * 0.35);
    c.lineTo(s * 0.5, s * 0.5);
    c.lineTo(s * 0.7, s * 0.38);
    c.moveTo(s * 0.5, s * 0.5);
    c.lineTo(s * 0.48, s * 0.75);
    c.stroke();
    c.restore();
  },
  cracks(c, s) {
    fist(c, s * 0.5, s * 0.26, s * 0.14);
    c.lineWidth = s * 0.045;
    c.lineCap = 'round';
    for (let i = 0; i < 5; i++) {
      const a = Math.PI / 2 + (i - 2) * 0.35;
      c.beginPath();
      c.moveTo(s / 2, s * 0.5);
      c.lineTo(s / 2 + Math.cos(a) * s * 0.2, s * 0.5 + Math.sin(a) * s * 0.2);
      c.lineTo(s / 2 + Math.cos(a + 0.15) * s * 0.42, s * 0.5 + Math.sin(a + 0.15) * s * 0.42);
      c.stroke();
    }
  },
  giant(c, s) {
    person(c, s * 0.42, s * 0.52, s * 0.8);
    c.globalAlpha = 0.6;
    person(c, s * 0.82, s * 0.74, s * 0.34);
    c.globalAlpha = 1;
    c.lineWidth = s * 0.04;
    c.beginPath();
    c.moveTo(s * 0.82, s * 0.2);
    c.lineTo(s * 0.82, s * 0.44);
    c.moveTo(s * 0.74, s * 0.28);
    c.lineTo(s * 0.82, s * 0.2);
    c.lineTo(s * 0.9, s * 0.28);
    c.stroke();
  },
  shadowStep(c, s) {
    person(c, s * 0.62, s * 0.56, s * 0.66);
    c.lineWidth = s * 0.05;
    c.lineCap = 'round';
    c.beginPath();
    c.arc(s * 0.5, s * 0.55, s * 0.36, Math.PI * 0.75, Math.PI * 1.55);
    c.stroke();
    c.beginPath();
    c.moveTo(s * 0.38, s * 0.14);
    c.lineTo(s * 0.52, s * 0.2);
    c.lineTo(s * 0.4, s * 0.3);
    c.stroke();
  },
  blades(c, s) {
    for (let i = -1; i <= 1; i++) {
      c.save();
      c.translate(s * 0.5, s * 0.82);
      c.rotate(i * 0.45);
      c.beginPath();
      c.moveTo(0, -s * 0.68);
      c.lineTo(s * 0.06, -s * 0.2);
      c.lineTo(0, -s * 0.12);
      c.lineTo(-s * 0.06, -s * 0.2);
      c.closePath();
      c.fill();
      c.restore();
    }
  },
  smoke(c, s) {
    for (const [x, y, r] of [
      [0.32, 0.6, 0.18],
      [0.55, 0.5, 0.22],
      [0.72, 0.64, 0.15],
      [0.45, 0.72, 0.15],
    ]) {
      c.beginPath();
      c.arc(s * x, s * y, s * r, 0, Math.PI * 2);
      c.fill();
    }
    c.save();
    c.globalCompositeOperation = 'destination-out';
    c.beginPath();
    c.ellipse(s * 0.52, s * 0.56, s * 0.12, s * 0.05, 0, 0, Math.PI * 2);
    c.fill();
    c.restore();
  },
  clone(c, s) {
    c.globalAlpha = 0.4;
    person(c, s * 0.26, s * 0.6, s * 0.56);
    person(c, s * 0.74, s * 0.6, s * 0.56);
    c.globalAlpha = 1;
    person(c, s * 0.5, s * 0.56, s * 0.66);
  },
  execute(c, s) {
    c.lineWidth = s * 0.05;
    c.beginPath();
    c.arc(s / 2, s / 2, s * 0.3, 0, Math.PI * 2);
    c.stroke();
    c.lineWidth = s * 0.08;
    c.lineCap = 'round';
    c.beginPath();
    c.moveTo(s * 0.18, s * 0.2);
    c.lineTo(s * 0.82, s * 0.8);
    c.moveTo(s * 0.82, s * 0.2);
    c.lineTo(s * 0.18, s * 0.8);
    c.stroke();
  },
  realm(c, s) {
    c.lineWidth = s * 0.04;
    c.beginPath();
    c.arc(s / 2, s / 2, s * 0.38, 0, Math.PI * 2);
    c.stroke();
    c.beginPath();
    c.ellipse(s / 2, s / 2, s * 0.28, s * 0.15, 0, 0, Math.PI * 2);
    c.fill();
    c.save();
    c.globalCompositeOperation = 'destination-out';
    c.beginPath();
    c.arc(s / 2, s / 2, s * 0.08, 0, Math.PI * 2);
    c.fill();
    c.restore();
    c.lineWidth = s * 0.03;
    rays(c, s / 2, s / 2, s * 0.4, s * 0.47, 16);
  },
  star(c, s) {
    c.beginPath();
    for (let i = 0; i < 10; i++) {
      const r = i % 2 ? s * 0.16 : s * 0.38;
      const a = -Math.PI / 2 + (i / 10) * Math.PI * 2;
      c.lineTo(s / 2 + Math.cos(a) * r, s / 2 + Math.sin(a) * r);
    }
    c.closePath();
    c.fill();
  },
  swirl(c, s) {
    c.lineWidth = s * 0.05;
    c.beginPath();
    for (let i = 0; i < 60; i++) {
      const a = i * 0.2;
      const r = s * 0.02 + i * s * 0.006;
      c.lineTo(s / 2 + Math.cos(a) * r, s / 2 + Math.sin(a) * r);
    }
    c.stroke();
  },
};

const cache = new Map<string, string>();

export function iconDataURL(spec: IconSpec, size = 128): string {
  const key = `${spec.glyph}|${spec.bg.join()}|${spec.fg}|${size}`;
  const hit = cache.get(key);
  if (hit) return hit;
  const cv = document.createElement('canvas');
  cv.width = cv.height = size;
  const c = cv.getContext('2d')!;
  const g = c.createRadialGradient(size * 0.5, size * 0.4, size * 0.05, size * 0.5, size * 0.5, size * 0.75);
  g.addColorStop(0, spec.bg[0]);
  g.addColorStop(1, spec.bg[1]);
  c.fillStyle = g;
  c.beginPath();
  c.roundRect(0, 0, size, size, size * 0.16);
  c.fill();
  // Subtle diagonal sheen.
  const sh = c.createLinearGradient(0, 0, size, size);
  sh.addColorStop(0, 'rgba(255,255,255,0.22)');
  sh.addColorStop(0.5, 'rgba(255,255,255,0)');
  c.fillStyle = sh;
  c.fillRect(0, 0, size, size);
  c.save();
  const pad = size * 0.1;
  c.translate(pad, pad);
  const inner = size - pad * 2;
  c.fillStyle = spec.fg;
  c.strokeStyle = spec.fg;
  c.shadowColor = spec.glow ?? spec.fg;
  c.shadowBlur = size * 0.12;
  (G[spec.glyph] ?? G.star)(c, inner);
  c.restore();
  const url = cv.toDataURL('image/png');
  cache.set(key, url);
  return url;
}
