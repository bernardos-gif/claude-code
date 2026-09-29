// End-to-end test: builds nothing itself — run `npm run build` first (npm run test:e2e does both).
// Serves dist/ with `vite preview`, drives the real game in headless Chromium and checks:
//  - the selection screen renders all fighters, stats and 6 ability icons
//  - every fighter can start a match, land combos and cast all six abilities
//  - enemies of all three types spawn, fight and die
//  - pause menu, rebinding UI and game-over / retry flow work
//  - no console errors or page exceptions occur
import { chromium } from 'playwright';
import { spawn } from 'child_process';
import fs from 'fs';

const PORT = 4179;
const URL = `http://localhost:${PORT}/`;
const shots = process.env.E2E_SHOTS ?? 'screenshots/e2e';
fs.mkdirSync(shots, { recursive: true });

const server = spawn('npx', ['vite', 'preview', '--port', String(PORT), '--strictPort'], { stdio: ['ignore', 'pipe', 'pipe'] });
await new Promise((resolve, reject) => {
  const t = setTimeout(() => reject(new Error('preview server did not start')), 20000);
  server.stdout.on('data', (d) => {
    if (String(d).includes(String(PORT))) {
      clearTimeout(t);
      resolve();
    }
  });
});

let failures = 0;
const check = (cond, msg) => {
  console.log(`${cond ? '  ✔' : '  ✘'} ${msg}`);
  if (!cond) failures++;
};

const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { server.kill(); browser.close().finally(() => process.exit(1)); });
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
  const errors = [];
  page.on('console', (m) => {
    const t = m.text();
    if (m.type() === 'error' && !t.includes('ERR_CERT') && !t.includes('fonts.g')) errors.push(t);
    if (t.includes('[anim] missing clip')) errors.push(t);
  });
  page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
  const g = (fn, arg) => page.evaluate(fn, arg);

  console.log('Selection screen');
  await page.goto(URL);
  await page.waitForFunction(() => window.__game && window.__game.state() === 'select', null, { timeout: 60000 });
  await page.waitForTimeout(1500);
  const cards = await page.locator('.roster .card').count();
  check(cards >= 4, `roster shows ${cards} fighters`);
  check((await page.locator('.info .ab').count()) === 6, 'six ability icons shown');
  check((await page.locator('.info .stat').count()) >= 9, 'stat rows shown');
  await page.locator('.roster .card').nth(2).click();
  await page.waitForTimeout(400);
  check((await page.locator('.info-name').textContent())?.includes('Titan'), 'clicking a card selects that fighter');
  await page.locator('.info .ab').nth(4).click();
  await page.waitForTimeout(300);
  check((await page.locator('.ab-detail b').textContent())?.length > 0, 'ability preview details');
  await page.screenshot({ path: `${shots}/select.png` });

  const ids = await g(() => window.__game.gm.selection && ['blaze', 'volt', 'titan', 'shadow']);
  for (const id of ids) {
    console.log(`Fighter: ${id}`);
    await g((cid) => { window.__game.start(cid); window.__game.setLoop(false); }, id);
    check((await g(() => window.__game.state())) === 'playing', 'match started');
    check((await page.locator('.ability-bar .slot').count()) === 6, 'HUD shows six ability slots');
    await g(() => {
      const G = window.__game;
      G.stopWaves();
      G.godMode(true);
      G.freeCast(true);
      G.spawn('fighter', 6, 0);
      G.spawn('fighter', 7, 0.6);
      G.spawn('ranged', 12, -0.5);
      G.spawn('heavy', 9, 0.9);
      G.advance(1.3);
    });
    for (let i = 0; i < 8; i++) await g(() => { window.__game.press('attack'); window.__game.advance(0.22); });
    const combo = await g(() => window.__game.world.combat.maxCombo);
    check(combo >= 3, `basic combo connects (max combo ${combo})`);
    for (let s = 0; s < 6; s++) {
      await g(() => {
        const G = window.__game;
        if (G.world.aliveEnemies().length < 3) {
          G.spawn('fighter', 5, 0.2);
          G.spawn('fighter', 6, -0.3);
          G.spawn('ranged', 11, 0.1);
          G.advance(1.2);
        }
      });
      if (s === 5) await g(() => window.__game.fillUlt());
      const before = await g(() => window.__game.world.combat.totalDamageDealt);
      const ok = await g((slot) => window.__game.cast(slot), s);
      await g((t) => window.__game.advance(t), s === 5 ? 10 : 2.5);
      const after = await g(() => window.__game.world.combat.totalDamageDealt);
      const name = await g((slot) => window.__game.gm.playerDef.abilities[slot].name, s);
      const buffOnly = await g((slot) => window.__game.gm.playerDef.abilities[slot].damage === 0, s);
      check(ok, `cast ${name}`);
      if (!buffOnly) check(after > before, `${name} dealt damage (${Math.round(after - before)})`);
    }
    await g(() => { window.__game.advance(0.5); window.__game.renderOnce(); });
    await page.screenshot({ path: `${shots}/${id}.png` });
    await g(() => window.__game.setLoop(true));
    const kills = await g(() => window.__game.world.combat.kills);
    check(kills > 0, `enemies defeated (${kills})`);
  }

  console.log('Waves, pause and game over');
  await g(() => { window.__game.start('blaze'); window.__game.setLoop(false); window.__game.advance(4); window.__game.setLoop(true); });
  const enemies = await g(() => window.__game.world.aliveEnemies().length);
  check(enemies > 0, `wave 1 spawns enemies (${enemies})`);
  await g(() => window.__game.gm.pause());
  await page.waitForTimeout(300);
  check((await g(() => window.__game.state())) === 'paused', 'pause');
  await page.locator('.menu-tabs .tab').nth(1).click();
  check((await page.locator('.rb-row').count()) >= 12, 'rebinding list shown');
  await page.locator('.menu-tabs .tab').nth(2).click();
  check((await page.locator('.set-row').count()) >= 4, 'settings shown');
  await page.locator('.menu-tabs .tab').nth(0).click();
  await page.locator('.menu-list .btn.primary').click();
  check((await g(() => window.__game.state())) === 'playing', 'resume');
  await g(() => {
    const p = window.__game.player();
    p.health.current = 1;
    window.__game.world.combat.dealDamage(null, p, { amount: 9999, element: 'physical', ignoreIFrames: true });
    window.__game.advance(3);
  });
  await page.waitForTimeout(500);
  check((await g(() => window.__game.state())) === 'gameover', 'game over after death');
  check((await page.locator('.gameover').count()) === 1, 'game over screen');
  await page.screenshot({ path: `${shots}/gameover.png` });
  await page.locator('.gameover .btn.primary').click();
  await page.waitForTimeout(300);
  check((await g(() => window.__game.state())) === 'playing', 'retry restarts the match');
  await g(() => window.__game.select());
  check((await g(() => window.__game.state())) === 'select', 'back to character select');

  check(errors.length === 0, `no console errors${errors.length ? `:\n${errors.slice(0, 10).join('\n')}` : ''}`);
} finally {
  await browser.close();
  server.kill();
}
console.log(failures ? `\nE2E FAILED (${failures})` : '\nE2E PASSED');
process.exit(failures ? 1 : 0);
