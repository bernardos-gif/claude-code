// Gameplay smoke test with screenshots: node scripts/play.mjs <charId> [outPrefix]
// Uses window.__game.advance() to step the simulation deterministically (software
// WebGL in CI is far too slow for real-time input).
import { chromium } from 'playwright';
const [char = 'blaze', prefix = `screenshots/${char}`] = process.argv.slice(2);
const shotAt = (process.env.SHOT ?? '0.35,0.35,0.5,0.9,0.95,1.3').split(',').map(Number);
const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => browser.close().finally(() => process.exit(1)));
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
const errors = [];
page.on('console', (m) => { if (m.type() === 'error' && !m.text().includes('ERR_CERT')) errors.push(m.text()); if (m.type() === 'warning' && m.text().includes('[anim]')) errors.push(m.text()); });
page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}\n${e.stack}`));
await page.goto(`${process.env.URL ?? 'http://localhost:5173/'}?char=${char}`);
await page.waitForTimeout(4000);
const g = (fn, arg) => page.evaluate(fn, arg);
const shot = async (name) => { await page.waitForTimeout(700); await page.screenshot({ path: `${prefix}-${name}.png` }); };
await g(() => { const G = window.__game; G.stopWaves(); G.godMode(true); G.freeCast(true); });
await g(() => { const G = window.__game; G.spawn('fighter', 6, 0); G.spawn('fighter', 7, 0.5); G.spawn('ranged', 13, -0.4); G.spawn('heavy', 9, 0.8); G.advance(1.3); });
// Basic combo.
for (let i = 0; i < 6; i++) await g(() => { window.__game.press('attack'); window.__game.advance(0.25); });
await shot('combo');
const names = await g(() => window.__game.gm.playerDef.abilities.map((a) => a.name));
const results = [];
for (let s = 0; s < 6; s++) {
  await g(() => { const G = window.__game; const W = G.world; if (W.aliveEnemies().length < 3) { G.spawn('fighter', 6, 0.2); G.spawn('fighter', 7, -0.3); G.spawn('ranged', 12, 0.1); G.advance(1.2); } });
  if (s === 5) await g(() => window.__game.fillUlt());
  const r = await g((slot) => { const G = window.__game; const ok = G.cast(slot); return { ok, why: G.player().abilities.lastFailReason }; }, s);
  await g((t) => window.__game.advance(t), shotAt[s]);
  await shot(`a${s + 1}`);
  const before = await g(() => Math.round(window.__game.world.combat.totalDamageDealt));
  await g((t) => window.__game.advance(t), s === 5 ? 9 : 2);
  const after = await g(() => Math.round(window.__game.world.combat.totalDamageDealt));
  const st = await g(() => window.__game.stats());
  results.push(`ability ${s + 1} ${names[s]}: cast=${r.ok}${r.ok ? '' : ` (${r.why})`} dmgDuring≈${after - before} particles=${st.particles}`);
}
await shot('end');
const info = await g(() => { const W = window.__game.world; return { maxCombo: W.combat.maxCombo, kills: W.combat.kills, dmg: Math.round(W.combat.totalDamageDealt), state: window.__game.state(), hp: Math.round(W.player?.health.current) }; });
console.log(results.join('\n'));
console.log('result', JSON.stringify(info));
console.log(errors.length ? `ERRORS (${errors.length}):\n${errors.slice(0, 15).join('\n')}` : 'no errors');
await browser.close();
