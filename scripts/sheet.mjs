// Contact sheet: node scripts/sheet.mjs out.png a.png b.png ...
import { chromium } from 'playwright';
import fs from 'fs';
const [out, ...files] = process.argv.slice(2);
const browser = await chromium.launch();
const page = await browser.newPage();
const imgs = files.map((f) => fs.readFileSync(f).toString('base64'));
const data = await page.evaluate(async (imgs) => {
  const cw = 640, ch = 360, cols = 2, rows = Math.ceil(imgs.length / cols);
  const c = document.createElement('canvas'); c.width = cw * cols; c.height = ch * rows;
  const ctx = c.getContext('2d');
  for (let i = 0; i < imgs.length; i++) { const im = new Image(); im.src = 'data:image/png;base64,' + imgs[i]; await im.decode(); ctx.drawImage(im, (i % cols) * cw, Math.floor(i / cols) * ch, cw, ch); }
  return c.toDataURL('image/jpeg', 0.85).split(',')[1];
}, imgs);
fs.writeFileSync(out, Buffer.from(data, 'base64'));
await browser.close();
