import { GameManager } from './core/GameManager';
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
