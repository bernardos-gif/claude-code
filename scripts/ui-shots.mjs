// Captures selection (all fighters), an ability preview, pause and game-over screens.
import { chromium } from 'playwright';
const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => browser.close().finally(() => process.exit(1)));
const page = await browser.newPage({ viewport: { width: 1440, height: 810 } });
const errors = [];
page.on('pageerror', (e) => errors.push(e.message));
page.on('console', (m) => { if (m.type() === 'error' && !m.text().includes('ERR_CERT')) errors.push(m.text()); });
await page.goto(process.env.URL ?? 'http://localhost:5173/');
await page.waitForFunction(() => window.__game && window.__game.state() === 'select', null, { timeout: 60000 });
for (let i = 1; i < 4; i++) {
  await page.locator('.roster .card').nth(i).click();
  await page.waitForTimeout(2500);
  await page.screenshot({ path: `screenshots/ui-select-${i}.png` });
}
await page.locator('.info .ab').nth(5).click();
await page.waitForTimeout(900);
await page.screenshot({ path: 'screenshots/ui-select-preview.png' });
await page.evaluate(() => { window.__game.start('shadow'); const G = window.__game; G.stopWaves(); G.godMode(true); G.freeCast(true); G.spawn('fighter', 7, 0); G.spawn('fighter', 8, 0.4); G.advance(1.3); G.cast(3); G.advance(1.2); });
await page.waitForTimeout(1200);
await page.screenshot({ path: 'screenshots/ui-clones.png' });
await page.evaluate(() => window.__game.gm.pause());
await page.waitForTimeout(600);
await page.locator('.menu-tabs .tab').nth(1).click();
await page.waitForTimeout(400);
await page.screenshot({ path: 'screenshots/ui-pause.png' });
await page.locator('.menu-tabs .tab').nth(0).click();
await page.locator('.menu-list .btn.primary').click();
await page.evaluate(() => { const G = window.__game; G.godMode(false); const p = G.player(); G.world.combat.dealDamage(null, p, { amount: 99999, element: 'physical', ignoreIFrames: true }); G.advance(3); });
await page.waitForTimeout(1000);
await page.screenshot({ path: 'screenshots/ui-gameover.png' });
console.log(errors.length ? errors.join('\n') : 'no errors');
await browser.close();
