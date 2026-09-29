// Renders a grid of poses: node scripts/poses.mjs out.png clip:t clip:t ...
import { chromium } from 'playwright';
const [out, ...specs] = process.argv.slice(2);
const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => browser.close().finally(() => process.exit(1)));
const page = await browser.newPage({ viewport: { width: 400, height: 400 } });
page.on('pageerror', (e) => console.log('[pageerror]', e.message));
await page.goto(process.env.URL ?? 'http://localhost:5173/');
await page.waitForTimeout(4000);
const shots = [];
for (const s of specs) {
  const [name, t, yawOff = '3.14'] = s.split(':');
  await page.evaluate(([n, t, y]) => { const d = window.__dbg; d.pose(n, Number(t)); d.cam.yaw = d.p.facing + Number(y); d.cam.pitch = -0.08; d.cam.zoom = 0.55; }, [name, t, yawOff]);
  await page.waitForTimeout(700);
  shots.push(await page.screenshot({ type: 'png' }));
}
// Composite with a canvas in the page.
const b64 = shots.map((b) => b.toString('base64'));
const grid = await page.evaluate(async (imgs) => {
  const cols = Math.min(4, imgs.length), rows = Math.ceil(imgs.length / cols);
  const c = document.createElement('canvas'); c.width = cols * 300; c.height = rows * 300;
  const ctx = c.getContext('2d');
  for (let i = 0; i < imgs.length; i++) {
    const im = new Image(); im.src = 'data:image/png;base64,' + imgs[i]; await im.decode();
    ctx.drawImage(im, 50, 20, 300, 300, (i % cols) * 300, Math.floor(i / cols) * 300, 300, 300);
  }
  return c.toDataURL('image/png').split(',')[1];
}, b64);
const fs = await import('fs');
fs.writeFileSync(out, Buffer.from(grid, 'base64'));
await browser.close();
