import * as THREE from 'three';
import type { World } from './World';
import type { EnemyDefinition } from '../data/types';
import { ENEMIES } from '../data/enemies';
import { distXZ, rand } from '../core/math';

export type WaveState = 'idle' | 'intermission' | 'spawning' | 'fighting';

/** Endless escalating waves spawned through the arena's portals. */
export class WaveManager {
  wave = 0;
  state: WaveState = 'idle';
  private timer = 0;
  private queue: EnemyDefinition[] = [];
  private spawnTimer = 0;
  readonly maxAlive = 12;
  score = 0;

  constructor(private w: World, private spawn: (def: EnemyDefinition, pos: THREE.Vector3, hpMul: number, dmgMul: number) => void) {}

  reset(): void {
    this.wave = 0;
    this.state = 'idle';
    this.queue = [];
    this.score = 0;
  }

  start(): void {
    this.reset();
    this.next();
  }

  get remaining(): number {
    return this.queue.length + this.w.aliveEnemies().length;
  }

  composition(n: number): EnemyDefinition[] {
    const f = n === 1 ? 3 : n === 2 ? 4 : n === 3 ? 3 : 4 + Math.floor(n / 2);
    const r = n === 1 ? 0 : n === 2 ? 2 : n === 3 ? 2 : 2 + Math.floor(n / 2);
    const h = n < 3 ? 0 : n === 3 ? 1 : 1 + Math.floor((n - 3) / 2);
    const list: EnemyDefinition[] = [];
    for (let i = 0; i < f; i++) list.push(ENEMIES.fighter);
    for (let i = 0; i < r; i++) list.push(ENEMIES.ranged);
    // Shuffle fighters/ranged; heavies arrive in the second half.
    list.sort(() => Math.random() - 0.5);
    for (let i = 0; i < h; i++) list.splice(Math.floor(list.length * (0.5 + Math.random() * 0.5)), 0, ENEMIES.heavy);
    return list;
  }

  private next(): void {
    this.wave++;
    this.queue = this.composition(this.wave);
    this.state = 'intermission';
    this.timer = this.wave === 1 ? 2.2 : 4;
    const heavies = this.queue.filter((e) => e.id === 'heavy').length;
    this.w.ui.announce(`WAVE ${this.wave}`, `${this.queue.length} enemies${heavies ? ` · ${heavies} Juggernaut${heavies > 1 ? 's' : ''}` : ''}`);
    this.w.audio.play('wave_start');
  }

  update(dt: number): void {
    if (this.state === 'idle') return;
    if (this.w.flags.realmActive) return;
    if (this.state === 'intermission') {
      this.timer -= dt;
      if (this.timer <= 0) this.state = 'spawning';
      return;
    }
    const alive = this.w.aliveEnemies().length;
    if (this.state === 'spawning') {
      this.spawnTimer -= dt;
      if (this.spawnTimer <= 0 && this.queue.length && alive < this.maxAlive) {
        this.spawnTimer = rand(0.35, 0.8);
        const def = this.queue.shift()!;
        const hpMul = 1 + 0.12 * (this.wave - 1);
        const dmgMul = 1 + 0.07 * (this.wave - 1);
        this.spawn(def, this.pickSpawnPoint(), hpMul, dmgMul);
      }
      if (!this.queue.length) this.state = 'fighting';
    }
    if (this.state === 'fighting' && !this.queue.length && alive === 0) {
      const p = this.w.player;
      if (p && p.alive) {
        p.health.heal(p.health.max * 0.25);
        this.w.ui.floatText(p.center().setY(p.position.y + 2.4), '+25% HP', '#7dff9a', 1.1);
      }
      this.score += 250 * this.wave;
      this.w.ui.announce('WAVE CLEARED', `+${250 * this.wave} pts`, '#7dff9a');
      this.w.audio.play('wave_clear');
      this.next();
    }
  }

  private pickSpawnPoint(): THREE.Vector3 {
    const pts = this.w.arena.spawnPoints;
    const p = this.w.player?.position ?? new THREE.Vector3();
    // Prefer portals that are not right next to the player.
    const sorted = [...pts].sort((a, b) => distXZ(b, p) - distXZ(a, p));
    const pick = sorted[Math.floor(Math.random() * Math.min(4, sorted.length))];
    const out = pick.clone().add(new THREE.Vector3(rand(-2.5, 2.5), 0, rand(-2.5, 2.5)));
    out.y = this.w.arena.groundHeight(out.x, out.z);
    const mesh = this.w.arena.portalMeshes[pts.indexOf(pick)];
    if (mesh) mesh.userData.active = 2;
    return out;
  }
}
