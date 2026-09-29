import { GameManager } from './core/GameManager';
// Fonts are bundled so the game (and the desktop app) works fully offline.
import '@fontsource/rajdhani/500.css';
import '@fontsource/rajdhani/600.css';
import '@fontsource/rajdhani/700.css';
import '@fontsource/teko/400.css';
import '@fontsource/teko/500.css';
import './styles.css';

const container = document.getElementById('app')!;
const game = new GameManager(container);
(window as any).__game = game.debugApi();
game.init().catch((err) => {
  console.error(err);
  const msg = document.createElement('div');
  msg.className = 'fatal';
  msg.textContent = `Failed to start: ${err?.message ?? err}. WebGL 2 is required.`;
  container.appendChild(msg);
});
