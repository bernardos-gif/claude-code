// Quick screenshot helper: node scripts/shot.mjs <url> <out.png> [waitMs] [evalJs]
import { chromium } from 'playwright';
const [url, out, wait = '4000', js] = process.argv.slice(2);
const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => browser.close().finally(() => process.exit(1)));
const page = await browser.newPage({ viewport: { width: Number(process.env.W ?? 1440), height: Number(process.env.H ?? 810) } });
const logs = [];
page.on('console', (m) => logs.push(`[${m.type()}] ${m.text()}`));
page.on('pageerror', (e) => logs.push(`[pageerror] ${e.message}\n${e.stack}`));
await page.goto(url);
await page.waitForTimeout(Number(wait));
if (js) {
  const r = await page.evaluate(js);
  if (r !== undefined) console.log('eval:', JSON.stringify(r));
  await page.waitForTimeout(1500);
}
await page.screenshot({ path: out });
console.log(logs.slice(0, 40).join('\n'));
await browser.close();
