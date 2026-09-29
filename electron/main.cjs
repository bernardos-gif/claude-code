// Electron main process: wraps the built game (dist/) as a desktop app.
// `--smoke-test` loads the game, starts a match, checks it runs, then exits
// with code 0 (pass) or 1 (fail) — used by CI on a real macOS runner.
const { app, BrowserWindow, Menu, shell, screen } = require('electron');
const path = require('path');
const fs = require('fs');

const SMOKE = process.argv.includes('--smoke-test');
const DEV_URL = process.env.ELECTRON_DEV_URL; // e.g. http://localhost:5173 for live development

// Prefer the discrete GPU on dual-GPU Macs and never throttle the game loop.
app.commandLine.appendSwitch('force_high_performance_gpu');
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');
if (SMOKE) app.commandLine.appendSwitch('ignore-gpu-blocklist');

app.setName('Elemental Clash');

function buildMenu(win) {
  const isMac = process.platform === 'darwin';
  const template = [
    ...(isMac
      ? [
          {
            label: app.name,
            submenu: [{ role: 'about' }, { type: 'separator' }, { role: 'hide' }, { role: 'hideOthers' }, { role: 'unhide' }, { type: 'separator' }, { role: 'quit' }],
          },
        ]
      : [{ label: 'File', submenu: [{ role: 'quit' }] }]),
    {
      label: 'View',
      submenu: [
        { role: 'togglefullscreen' },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        ...(app.isPackaged ? [] : [{ type: 'separator' }, { role: 'reload' }, { role: 'toggleDevTools' }]),
      ],
    },
    { label: 'Window', submenu: [{ role: 'minimize' }, { role: 'zoom' }, ...(isMac ? [{ role: 'front' }] : [{ role: 'close' }])] },
    {
      role: 'help',
      submenu: [{ label: 'Controls: press H in game · Esc pauses', enabled: false }],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
  void win;
}

function createWindow() {
  const { workAreaSize } = screen.getPrimaryDisplay();
  const width = Math.min(1600, Math.round(workAreaSize.width * 0.9));
  const height = Math.min(900, Math.round(workAreaSize.height * 0.9));
  const win = new BrowserWindow({
    width,
    height,
    minWidth: 1024,
    minHeight: 600,
    title: 'Elemental Clash',
    backgroundColor: '#07060a',
    show: false,
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      backgroundThrottling: false,
    },
  });
  buildMenu(win);

  // The game only ever loads its own files; anything else opens in the browser.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (e, url) => {
    if (!DEV_URL || !url.startsWith(DEV_URL)) e.preventDefault();
  });

  win.once('ready-to-show', () => win.show());

  if (DEV_URL) win.loadURL(DEV_URL);
  else win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'));

  if (SMOKE) runSmokeTest(win);
  return win;
}

async function runSmokeTest(win) {
  const fail = (msg) => {
    console.error(`SMOKE TEST FAILED: ${msg}`);
    app.exit(1);
  };
  const errors = [];
  win.webContents.on('console-message', (event) => {
    if (event.level === 'error') errors.push(event.message);
  });
  win.webContents.on('render-process-gone', (_e, details) => fail(`renderer gone: ${details.reason}`));
  const timer = setTimeout(() => fail('timed out'), 120000);
  const js = (code) => win.webContents.executeJavaScript(code);
  try {
    await new Promise((resolve) => win.webContents.once('did-finish-load', resolve));
    for (let i = 0; i < 240; i++) {
      const state = await js('window.__game ? window.__game.state() : "loading"');
      if (state === 'select') break;
      await new Promise((r) => setTimeout(r, 250));
    }
    const state = await js('window.__game ? window.__game.state() : "missing"');
    if (state !== 'select') return fail(`selection screen not reached (state=${state})`);
    const result = await js(`(() => {
      const G = window.__game;
      G.start('titan');
      G.stopWaves();
      G.freeCast(true);
      G.spawn('fighter', 5, 0);
      G.spawn('ranged', 9, 0.5);
      G.advance(1.5);
      for (let i = 0; i < 5; i++) { G.cast(i); G.advance(1.5); }
      G.fillUlt();
      G.cast(5);
      G.advance(3);
      return { state: G.state(), damage: G.world.combat.totalDamageDealt, gl: !!document.querySelector('canvas').getContext('webgl2') };
    })()`);
    console.log('smoke result', JSON.stringify(result));
    if (process.env.SMOKE_SCREENSHOT) {
      await js('window.__game.renderOnce()');
      await new Promise((r) => setTimeout(r, 500));
      const img = await win.webContents.capturePage();
      fs.writeFileSync(process.env.SMOKE_SCREENSHOT, img.toPNG());
      console.log(`screenshot saved to ${process.env.SMOKE_SCREENSHOT}`);
    }
    if (result.state !== 'playing') return fail(`unexpected state ${result.state}`);
    if (!(result.damage > 0)) return fail('no damage dealt');
    if (errors.length) return fail(`console errors: ${errors.join(' | ')}`);
    clearTimeout(timer);
    console.log('SMOKE TEST PASSED');
    app.exit(0);
  } catch (err) {
    fail(err && err.stack ? err.stack : String(err));
  }
}

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

// A game quits when its window closes, even on macOS.
app.on('window-all-closed', () => app.quit());
