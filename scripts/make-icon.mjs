// Generates build/icon.png (1024×1024) — the desktop app icon — using a canvas in headless Chromium.
// node scripts/make-icon.mjs
import { chromium } from 'playwright';
import fs from 'fs';

const browser = await chromium.launch();
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => browser.close().finally(() => process.exit(1)));
const page = await browser.newPage();
const data = await page.evaluate(() => {
  const S = 1024;
  const c = document.createElement('canvas');
  c.width = c.height = S;
  const g = c.getContext('2d');
  const cx = S / 2;
  const cy = S / 2;
  // macOS icon grid: 824px rounded square with a soft drop shadow.
  const inset = 100;
  const size = S - inset * 2;
  g.save();
  g.shadowColor = 'rgba(0,0,0,0.45)';
  g.shadowBlur = 40;
  g.shadowOffsetY = 18;
  g.beginPath();
  g.roundRect(inset, inset, size, size, 186);
  const bg = g.createRadialGradient(cx, cy - 60, 40, cx, cy, size * 0.75);
  bg.addColorStop(0, '#2a1638');
  bg.addColorStop(0.55, '#120a1c');
  bg.addColorStop(1, '#05040a');
  g.fillStyle = bg;
  g.fill();
  g.restore();
  g.save();
  g.beginPath();
  g.roundRect(inset, inset, size, size, 186);
  g.clip();
  // Rune ring.
  g.strokeStyle = 'rgba(255,255,255,0.08)';
  g.lineWidth = 4;
  for (const r of [300, 330]) {
    g.beginPath();
    g.arc(cx, cy, r, 0, Math.PI * 2);
    g.stroke();
  }
  // Four elemental arcs.
  const elements = [
    ['#ff5a14', '#ffc04a', '#ff8a30'], // fire
    ['#2a80ff', '#bfe8ff', '#6fc8ff'], // lightning
    ['#8a5a2a', '#f0d0a0', '#d8a060'], // earth
    ['#5a1aa0', '#e0a0ff', '#a050ff'], // shadow
  ];
  const R = 262;
  elements.forEach(([a, b, glow], i) => {
    const start = -Math.PI / 2 + (i * Math.PI) / 2 + 0.14;
    const end = start + Math.PI / 2 - 0.28;
    const grad = g.createLinearGradient(cx + Math.cos(start) * R, cy + Math.sin(start) * R, cx + Math.cos(end) * R, cy + Math.sin(end) * R);
    grad.addColorStop(0, a);
    grad.addColorStop(1, b);
    g.save();
    g.shadowColor = glow;
    g.shadowBlur = 50;
    g.strokeStyle = grad;
    g.lineWidth = 46;
    g.lineCap = 'round';
    g.beginPath();
    g.arc(cx, cy, R, start, end);
    g.stroke();
    g.restore();
  });
  // Central four-pointed star, each point tinted by an element.
  const points = [
    [0, -1, elements[0]],
    [1, 0, elements[1]],
    [0, 1, elements[2]],
    [-1, 0, elements[3]],
  ];
  for (const [dx, dy, [a, b, glow]] of points) {
    const tipX = cx + dx * 215;
    const tipY = cy + dy * 215;
    const side = { x: -dy, y: dx };
    const grad = g.createLinearGradient(cx, cy, tipX, tipY);
    grad.addColorStop(0, '#ffffff');
    grad.addColorStop(0.45, b);
    grad.addColorStop(1, a);
    g.save();
    g.shadowColor = glow;
    g.shadowBlur = 40;
    g.fillStyle = grad;
    g.beginPath();
    g.moveTo(tipX, tipY);
    g.lineTo(cx + side.x * 58, cy + side.y * 58);
    g.lineTo(cx, cy);
    g.lineTo(cx - side.x * 58, cy - side.y * 58);
    g.closePath();
    g.fill();
    g.restore();
  }
  // Diagonal blades between the points.
  g.save();
  g.globalAlpha = 0.85;
  g.fillStyle = '#ffffff';
  for (let i = 0; i < 4; i++) {
    const ang = Math.PI / 4 + (i * Math.PI) / 2;
    const tip = { x: cx + Math.cos(ang) * 120, y: cy + Math.sin(ang) * 120 };
    const side = { x: -Math.sin(ang), y: Math.cos(ang) };
    g.beginPath();
    g.moveTo(tip.x, tip.y);
    g.lineTo(cx + side.x * 22, cy + side.y * 22);
    g.lineTo(cx - side.x * 22, cy - side.y * 22);
    g.closePath();
    g.fill();
  }
  g.restore();
  // Core glow.
  const core = g.createRadialGradient(cx, cy, 0, cx, cy, 90);
  core.addColorStop(0, 'rgba(255,255,255,1)');
  core.addColorStop(0.35, 'rgba(255,240,220,0.8)');
  core.addColorStop(1, 'rgba(255,200,160,0)');
  g.fillStyle = core;
  g.beginPath();
  g.arc(cx, cy, 90, 0, Math.PI * 2);
  g.fill();
  // Sparks.
  let seed = 7;
  const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  for (let i = 0; i < 60; i++) {
    const ang = rnd() * Math.PI * 2;
    const r = 120 + rnd() * 250;
    g.fillStyle = `rgba(255,255,255,${0.15 + rnd() * 0.5})`;
    g.beginPath();
    g.arc(cx + Math.cos(ang) * r, cy + Math.sin(ang) * r, 1.5 + rnd() * 3, 0, Math.PI * 2);
    g.fill();
  }
  // Top sheen.
  const sheen = g.createLinearGradient(0, inset, 0, inset + size * 0.5);
  sheen.addColorStop(0, 'rgba(255,255,255,0.10)');
  sheen.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = sheen;
  g.fillRect(inset, inset, size, size * 0.5);
  g.restore();
  return c.toDataURL('image/png').split(',')[1];
});
fs.mkdirSync('build', { recursive: true });
fs.writeFileSync('build/icon.png', Buffer.from(data, 'base64'));
console.log('wrote build/icon.png');
await browser.close();
