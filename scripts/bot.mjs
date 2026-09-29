// Bot playthrough: drives the player through real input actions against live waves.
// node scripts/bot.mjs <charId> [seconds]
import { chromium } from 'playwright';
const [char = 'blaze', secs = '90'] = process.argv.slice(2);
const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => browser.close().finally(() => process.exit(1)));
const page = await browser.newPage({ viewport: { width: 960, height: 540 } });
const errors = [];
page.on('console', (m) => { if (m.type() === 'error' && !m.text().includes('ERR_CERT')) errors.push(m.text()); });
page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}\n${e.stack}`));
await page.goto(`${process.env.URL ?? 'http://localhost:5173/'}?char=${char}`);
await page.waitForFunction(() => window.__game && window.__game.state() === 'playing', null, { timeout: 60000 });
const report = await page.evaluate(async (total) => {
  const G = window.__game;
  const W = G.world;
  const log = { hitsTaken: 0, dmgTaken: 0, enemyAttacks: {}, casts: {}, dodges: 0, projectilesFired: 0 };
  W.events.on('damage', (r) => {
    if (r.target.kind === 'player') {
      log.hitsTaken++;
      log.dmgTaken += r.amount;
      const k = r.attacker?.def.id ?? 'dot';
      log.enemyAttacks[k] = (log.enemyAttacks[k] ?? 0) + 1;
    }
  });
  W.events.on('abilityCast', (a, def) => { if (a.kind === 'player') log.casts[def.id] = (log.casts[def.id] ?? 0) + 1; });
  const hold = (act, on) => G.hold(act, on);
  let t = 0;
  let fwd = false;
  const ranged = { maxDist: 0 };
  while (t < total && G.state() === 'playing') {
    const p = G.player();
    const enemies = W.aliveEnemies().filter((e) => e.state !== 'spawn');
    let target = null;
    let best = 1e9;
    for (const e of enemies) {
      const d = e.position.distanceTo(p.position);
      if (d < best) { best = d; target = e; }
      if (e.def.id === 'ranged') ranged.maxDist = Math.max(ranged.maxDist, d);
    }
    if (target) {
      const dx = target.position.x - p.position.x;
      const dz = target.position.z - p.position.z;
      G.gm.camera.yaw = Math.atan2(dx, dz);
      const want = best > 2.6;
      if (want !== fwd) { hold('moveForward', want); fwd = want; }
      if (best < 3.2) G.press('attack');
      if (Math.random() < 0.05) {
        const slot = Math.floor(Math.random() * 5);
        G.press(['ability1', 'ability2', 'ability3', 'ability4', 'ability5'][slot]);
      }
      if (p.abilities.ultReady && best < 8) G.press('ultimate');
      if (Math.random() < 0.02) { G.press('dodge'); log.dodges++; }
      if (Math.random() < 0.01) G.press('jump');
    } else if (fwd) { hold('moveForward', false); fwd = false; }
    G.advance(0.1);
    t += 0.1;
    if (Math.round(t * 10) % 50 === 0) await new Promise((r) => setTimeout(r, 0));
  }
  hold('moveForward', false);
  const c = W.combat;
  return { char: G.gm.playerDef.id, simulated: +t.toFixed(1), state: G.state(), wave: G.gm.waves.wave, kills: c.kills, maxCombo: c.maxCombo, dmgDealt: Math.round(c.totalDamageDealt), hp: Math.round(G.player()?.health.current ?? 0), ...log, dmgTaken: Math.round(log.dmgTaken), rangedMaxDist: +ranged.maxDist.toFixed(1), stats: G.stats() };
}, Number(secs));
await page.waitForTimeout(800);
await page.screenshot({ path: `screenshots/bot-${char}.png` });
console.log(JSON.stringify(report, null, 1));
console.log(errors.length ? `ERRORS (${errors.length}):\n${errors.slice(0, 10).join('\n')}` : 'no errors');
await browser.close();
