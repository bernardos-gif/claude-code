import * as THREE from 'three';
import { Arena } from '../world/Arena';
import { Lighting } from '../world/Lighting';
import { VFXManager } from '../vfx/VFXManager';
import { AudioManager } from '../audio/AudioManager';
import { CameraController } from '../camera/CameraController';
import { InputManager } from './InputManager';
import { ControlSettings, loadSettings, saveSettings } from '../config/controls';
import { World } from './World';
import { Actor } from '../entities/Actor';
import { AbilitySystem } from '../combat/AbilitySystem';
import { PlayerController } from '../entities/PlayerController';
import { EnemyAI } from '../entities/EnemyAI';
import { WaveManager } from './WaveManager';
import { UIManager } from '../ui/UIManager';
import { CharacterSelection } from '../ui/CharacterSelection';
import { PortraitRenderer } from '../ui/PortraitRenderer';
import { CHARACTERS, getCharacter } from '../data/characters';
import { ENEMIES } from '../data/enemies';
import type { CharacterDefinition, EnemyDefinition } from '../data/types';
import { FireFX, EarthFX } from '../vfx/ElementFX';
import { Textures } from '../vfx/Textures';
import { rand, TAU } from './math';
import { RoomEnvironment } from 'three/examples/jsm/environments/RoomEnvironment.js';

export type GameState = 'loading' | 'select' | 'playing' | 'paused' | 'gameover';
type Quality = 'high' | 'medium' | 'low';

/**
 * Top-level orchestrator: owns the renderer and every system, runs the main
 * loop and the state machine (select → playing ⇄ paused → gameover).
 */
export class GameManager {
  readonly renderer: THREE.WebGLRenderer;
  readonly scene = new THREE.Scene();
  readonly settings: ControlSettings;
  readonly input: InputManager;
  readonly audio = new AudioManager();
  readonly camera: CameraController;
  readonly arena: Arena;
  readonly lighting: Lighting;
  readonly vfx: VFXManager;
  readonly world: World;
  readonly ui: UIManager;
  readonly waves: WaveManager;
  selection!: CharacterSelection;
  state: GameState = 'loading';
  playerDef: CharacterDefinition | null = null;
  playerCtl: PlayerController | null = null;
  private last = performance.now();
  private portraits: Record<string, string> = {};
  private matchTime = 0;
  private deathTimer = 0;
  private quality: Quality = 'high';
  private targetRing: THREE.Mesh;
  private lastPauseToggle = 0;
  private fpsAcc = 0;
  private fpsFrames = 0;
  fps = 60;
  /** Tests can pause the real-time loop and drive the game with advance(). */
  loopEnabled = true;

  constructor(private container: HTMLElement) {
    this.settings = loadSettings();
    this.renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'high-performance' });
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = THREE.PCFShadowMap;
    container.appendChild(this.renderer.domElement);
    this.quality = this.detectQuality();
    this.applyQuality(this.quality, false);

    this.input = new InputManager(this.renderer.domElement, this.settings);
    this.camera = new CameraController(innerWidth / innerHeight);
    this.arena = new Arena();
    this.scene.add(this.arena.group);
    // Soft image-based lighting so metals and armour read well.
    const pmrem = new THREE.PMREMGenerator(this.renderer);
    this.scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
    this.scene.environmentIntensity = 0.35;
    pmrem.dispose();
    this.lighting = new Lighting(this.scene, this.renderer, this.quality === 'high' ? 2 : this.quality === 'medium' ? 1 : 1);
    this.lighting.skyUniforms = this.arena.skyMat.uniforms as any;
    this.vfx = new VFXManager(this.scene, this.camera.camera);
    this.vfx.groundFn = (x, z) => this.arena.terrainHeight(x, z);
    this.vfx.quality = this.quality === 'low' ? 0.6 : 1;
    this.ui = new UIManager(container, this.input, this.settings);
    this.world = new World(this.scene, this.arena, this.lighting, this.vfx, this.audio, this.camera, this.input, this.ui);
    this.waves = new WaveManager(this.world, (def, pos, hp, dmg) => this.spawnEnemy(def, pos, hp, dmg));
    this.audio.setVolumes(this.settings.sfxVolume, this.settings.musicVolume);

    // Target indicator ring on the ground.
    this.targetRing = new THREE.Mesh(
      new THREE.RingGeometry(0.85, 1.05, 40),
      new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.7, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide }),
    );
    this.targetRing.rotation.x = -Math.PI / 2;
    this.targetRing.visible = false;
    this.targetRing.renderOrder = 3;
    this.scene.add(this.targetRing);

    this.arena.onDestroy = (d, dir) => {
      const wood = d.kind === 'crate' || d.kind === 'barrel';
      this.vfx.spawnDebris(d.center, wood ? 10 : 16, d.color, { dir, force: wood ? 6 : 8, size: wood ? 0.22 : 0.32 });
      EarthFX.dust(this.vfx, d.center.clone().setY(d.center.y - d.height * 0.4), d.radius * 2, 12);
      this.audio.play(wood ? 'destroy_wood' : 'destroy_stone', d.center);
      if (!wood) this.camera.addShake(0.25, d.center);
      this.waves.score += wood ? 10 : 50;
    };

    this.world.events.on('damage', (r) => this.ui.damageNumber(r, r.target.kind === 'player'));
    this.world.events.on('kill', (target: Actor) => {
      const def = Object.values(ENEMIES).find((e) => e.id === target.def.id);
      if (def) this.waves.score += Math.round(def.score * (1 + this.world.combat.comboCount * 0.02));
    });
    this.world.events.on('abilityFailed', (slot: number, why: string) => {
      this.ui.abilityFailed(slot, why);
      this.audio.play('error', null, { volume: 0.5 });
    });
    this.world.events.on('perfectDodge', (a: Actor) => {
      if (this.world.time - (a.userData.lastPerfect ?? -9) < 0.6) return;
      a.userData.lastPerfect = this.world.time;
      this.audio.play('perfect_dodge', a.position, { volume: 0.6 });
      this.world.slowMo(0.35, 0.25);
      this.ui.floatText(a.center().setY(a.position.y + a.height + 0.3), 'DODGE', '#ffffff', 0.9);
    });

    window.addEventListener('resize', () => this.resize());
    // Browsers only allow audio after a user gesture.
    const unlock = () => this.audio.unlock();
    window.addEventListener('pointerdown', unlock);
    window.addEventListener('keydown', unlock);
    document.addEventListener('pointerlockchange', () => {
      if (!document.pointerLockElement && this.state === 'playing' && performance.now() - this.lastPauseToggle > 250) this.pause();
    });
    document.addEventListener('visibilitychange', () => {
      if (document.hidden && this.state === 'playing') this.pause();
    });
  }

  /** Builds portraits and the selection screen, then starts the loop. */
  async init(): Promise<void> {
    this.ui.setLoading('Forging the arena…');
    await new Promise((r) => setTimeout(r, 30));
    const pr = new PortraitRenderer(this.renderer);
    for (const def of CHARACTERS) this.portraits[def.id] = pr.render(def);
    this.selection = new CharacterSelection(this.container, this.renderer.domElement, this.audio, this.portraits, this.settings);
    this.selection.onStart = (def) => this.startMatch(def);
    this.selection.scene.environment = this.scene.environment;
    this.selection.scene.environmentIntensity = 0.3;
    this.resize();
    // Pre-compile arena shaders to avoid a hitch on first frame.
    this.renderer.compile(this.scene, this.camera.camera);
    this.ui.setLoading(null);
    const params = new URLSearchParams(location.search);
    const quick = params.get('char');
    if (quick && getCharacter(quick)) this.startMatch(getCharacter(quick)!);
    else this.showSelect();
    requestAnimationFrame(this.frame);
  }

  private detectQuality(): Quality {
    const saved = (() => {
      try {
        return localStorage.getItem('elemental-clash.quality') as Quality | null;
      } catch {
        return null;
      }
    })();
    if (saved === 'high' || saved === 'medium' || saved === 'low') return saved;
    const gl = this.renderer.getContext();
    const dbg = gl.getExtension('WEBGL_debug_renderer_info');
    const name = dbg ? String(gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL)) : '';
    if (/swiftshader|llvmpipe|software/i.test(name)) return 'low';
    return devicePixelRatio > 1.5 ? 'medium' : 'high';
  }

  applyQuality(q: Quality, persist = true): void {
    this.quality = q;
    const ratio = q === 'high' ? Math.min(2, devicePixelRatio) : q === 'medium' ? Math.min(1.25, devicePixelRatio) : 0.85;
    this.renderer.setPixelRatio(ratio);
    this.renderer.shadowMap.enabled = q !== 'low';
    if (this.vfx) this.vfx.quality = q === 'low' ? 0.6 : 1;
    if (persist) {
      try {
        localStorage.setItem('elemental-clash.quality', q);
      } catch {
        /* ignore */
      }
    }
    this.resize();
  }

  private resize(): void {
    const w = innerWidth;
    const h = innerHeight;
    this.renderer.setSize(w, h);
    this.camera?.resize(w / h);
    this.selection?.resize(w, h);
  }

  // ------------------------------------------------------------ states --
  showSelect(): void {
    this.state = 'select';
    this.world.reset();
    this.vfx.clear();
    this.ui.clearWorldElements();
    this.ui.hideOverlay();
    this.ui.showHUD(false);
    this.input.gameplayEnabled = false;
    this.input.exitPointerLock();
    this.selection.show();
    this.audio.setIntensity(0);
    this.audio.startMusic();
  }

  startMatch(def: CharacterDefinition): void {
    this.audio.unlock();
    this.audio.startMusic();
    this.playerDef = def;
    this.selection?.hide();
    this.world.reset();
    this.vfx.clear();
    this.ui.clearWorldElements();
    this.ui.hideOverlay();
    this.arena.resetState();
    this.camera.stopCinematic();
    EnemyAI.attackers.clear();
    this.world.playerDef = def;

    const p = new Actor(def, 'player', 'player');
    p.abilities = new AbilitySystem(p, def.abilities);
    this.playerCtl = new PlayerController(def);
    p.controller = this.playerCtl;
    p.position.set(0, 0, 8);
    p.facing = Math.PI;
    this.world.addActor(p);
    this.world.player = p;
    def.hooks.onSpawn?.(p, this.world);
    this.camera.distanceScale = 1;
    this.camera.setProfile(def.camera);
    this.camera.snapBehind(p);

    this.ui.setupHUD(def, this.portraits[def.id] ?? '');
    this.ui.showHUD(true);
    this.input.clearAll();
    this.input.endFrame();
    this.input.gameplayEnabled = true;
    this.input.requestPointerLock();
    this.matchTime = 0;
    this.deathTimer = 0;
    this.state = 'playing';
    this.waves.start();
    this.audio.setIntensity(1);
    FireFX.burst(this.vfx, p.center(), 0.01);
  }

  spawnEnemy(def: EnemyDefinition, pos: THREE.Vector3, hpMul = 1, dmgMul = 1): Actor {
    const e = new Actor(def, 'enemy', 'enemy');
    e.stats.attackDamage *= dmgMul;
    e.stats.maxHealth = Math.round(def.stats.maxHealth * hpMul);
    e.health.max = e.stats.maxHealth;
    e.health.current = e.stats.maxHealth;
    e.health.displayed = e.stats.maxHealth;
    e.position.copy(pos);
    const p = this.world.player;
    if (p) e.faceTowards(p.position);
    e.controller = new EnemyAI(def, this.playerDef);
    e.setState('spawn');
    e.iframes = 1.0;
    e.anim.play('spawn', { fade: 0, restart: true });
    this.world.addActor(e);
    // Portal effect.
    this.vfx.decal(pos, 2.2, Textures.runes(), 0xff3040, 1.6, { additive: true, opacity: 0.9, spin: 2, fadeIn: 0.15 });
    this.vfx.emit('dark', pos.clone().setY(pos.y + 0.5), 20, { speed: [1, 3], life: [0.6, 1.1], size: [1, 1.8], sizeEnd: 1.5, color: [0x200606, 0x100404], alpha: 0.7, disc: 1, gravity: -2 });
    this.vfx.emit('glow', pos.clone().setY(pos.y + 0.3), 16, { speed: [1, 4], dir: new THREE.Vector3(0, 1, 0), spread: 0.3, life: [0.4, 0.8], size: [0.3, 0.6], color: 0xff3040, colorEnd: 0x400000, disc: 1 });
    this.vfx.flash(pos.clone().setY(pos.y + 1), 0xff2030, 20, 10, 0.6);
    this.audio.play('enemy_spawn', pos, { volume: 0.7 });
    return e;
  }

  pause(): void {
    if (this.state !== 'playing') return;
    this.lastPauseToggle = performance.now();
    this.state = 'paused';
    this.input.gameplayEnabled = false;
    this.input.exitPointerLock();
    this.audio.setIntensity(0.2);
    this.ui.showPause(
      { resume: () => this.resume(), restart: () => this.playerDef && this.startMatch(this.playerDef), select: () => this.showSelect() },
      {
        onQuality: (q) => this.applyQuality(q),
        onVolumes: (s, m) => this.audio.setVolumes(s, m),
        getQuality: () => this.quality,
      },
    );
  }

  resume(): void {
    if (this.state !== 'paused') return;
    this.lastPauseToggle = performance.now();
    this.ui.hideOverlay();
    this.ui.refreshKeyLabels();
    this.state = 'playing';
    this.input.clearAll();
    this.input.gameplayEnabled = true;
    this.input.requestPointerLock();
    this.audio.setIntensity(1);
    this.last = performance.now();
  }

  private gameOver(): void {
    this.state = 'gameover';
    this.input.gameplayEnabled = false;
    this.input.exitPointerLock();
    this.audio.play('game_over');
    this.audio.setIntensity(0);
    const c = this.world.combat;
    this.ui.showGameOver(
      { wave: this.waves.wave, kills: c.kills, maxCombo: c.maxCombo, damage: c.totalDamageDealt, time: this.matchTime, score: this.waves.score },
      this.playerDef!,
      { retry: () => this.startMatch(this.playerDef!), select: () => this.showSelect() },
    );
  }

  // --------------------------------------------------------------- loop --
  private frame = (now: number) => {
    requestAnimationFrame(this.frame);
    if (!this.loopEnabled) {
      this.last = now;
      return;
    }
    const raw = Math.max(0, (now - this.last) / 1000);
    const dt = Math.min(0.05, raw);
    this.last = now;
    this.fpsAcc += raw;
    this.fpsFrames++;
    if (this.fpsAcc > 0.5) {
      this.fps = this.fpsFrames / this.fpsAcc;
      this.fpsAcc = 0;
      this.fpsFrames = 0;
    }
    try {
      this.step(dt);
    } catch (err) {
      console.error(err);
    }
    this.input.endFrame();
  };

  step(dt: number, render = true): void {
    this.audio.update(dt);
    if (this.state === 'select') {
      this.selection.update(dt);
      if (render) this.renderer.render(this.selection.scene, this.selection.camera);
      return;
    }
    if (this.state === 'loading') return;

    const input = this.input;
    if (this.state === 'playing') {
      if (input.wasPressed('pause')) {
        this.pause();
      }
      if (input.wasPressed('help')) this.ui.toggleHelp();
      if (input.wasPressed('mute')) this.audio.setMuted(!this.audio.muted);
    } else if (this.state === 'paused' && input.wasPressed('pause') && performance.now() - this.lastPauseToggle > 250) {
      this.resume();
    }

    const running = this.state === 'playing' || this.state === 'gameover';
    const w = this.world;
    const p = w.player;
    if (running) {
      let wdt = w.worldDelta(dt);
      if (this.state === 'gameover') wdt *= 0.5;
      if (this.state === 'playing') this.matchTime += dt;
      w.update(wdt);
      if (this.state === 'playing') this.waves.update(wdt);
      this.cleanupDead();
      this.ambientFx(wdt);
      if (p && !p.alive && this.state === 'playing') {
        this.deathTimer += dt;
        if (this.deathTimer === dt) w.slowMo(0.35, 1.2);
        if (this.deathTimer > 2.2) this.gameOver();
      }
      this.vfx.update(wdt, this.renderer.domElement.clientHeight);
    }
    const cam = this.camera;
    cam.update(dt, p, input, this.arena, this.state === 'playing');
    this.lighting.follow(p?.position ?? new THREE.Vector3());
    this.lighting.update(dt);
    this.arena.update(dt, w.time);
    this.audio.listener.position.copy(cam.camera.position);
    cam.right(this.audio.listener.right);
    this.audio.setIntensity(this.state === 'playing' ? (w.aliveEnemies().length ? 1 : 0.45) : 0.1);
    this.updateTargetRing(dt);
    this.ui.update(dt, w, cam.camera, this.playerCtl, { wave: this.waves.wave, remaining: this.waves.remaining, score: this.waves.score, time: this.matchTime, state: this.waves.state });
    if (render) this.renderer.render(this.scene, cam.camera);
  }

  private updateTargetRing(dt: number): void {
    const p = this.world.player;
    const t = p?.target;
    if (t && t.targetable && this.state === 'playing') {
      this.targetRing.visible = true;
      this.targetRing.position.set(t.position.x, t.position.y + 0.08, t.position.z);
      const s = t.radius * 2.2;
      this.targetRing.scale.setScalar(s * (1 + Math.sin(this.world.realTime * 6) * 0.05));
      this.targetRing.rotation.z += dt;
      (this.targetRing.material as THREE.MeshBasicMaterial).color.set(t === this.playerCtl?.lockTarget ? 0xff4040 : 0xffffff);
    } else this.targetRing.visible = false;
  }

  /** Dead enemies sink into the ground and are removed. */
  private cleanupDead(): void {
    const w = this.world;
    for (const a of [...w.actors]) {
      if (a.kind === 'player' || a.alive) continue;
      const t = w.time - a.deathTime;
      if (t > 2.2) a.root.position.y -= 0.02;
      if (t > 3.2) w.removeActor(a);
    }
  }

  private ambientFx(dt: number): void {
    if (!this.arena.props.visible) return;
    const cam = this.camera.camera.position;
    for (const b of this.arena.braziers) {
      if (b.distanceToSquared(cam) > 3600) continue;
      if (Math.random() < dt * 22) FireFX.trailPuff(this.vfx, b.clone().add(new THREE.Vector3(rand(-0.4, 0.4), 0, rand(-0.4, 0.4))));
      if (Math.random() < dt * 6) FireFX.embers(this.vfx, b, 1, 0.3);
    }
    // Drifting motes around the player for atmosphere.
    const p = this.world.player;
    if (p && Math.random() < dt * 8) {
      const a = Math.random() * TAU;
      const r = rand(3, 14);
      const pos = p.position.clone().add(new THREE.Vector3(Math.cos(a) * r, rand(0.5, 4), Math.sin(a) * r));
      this.vfx.emit('glow', pos, 1, { speed: [0.1, 0.4], life: [2, 3.5], size: [0.06, 0.12], sizeEnd: 1, color: 0xfff0c0, alpha: 0.7, gravity: -0.05 });
    }
  }

  // ------------------------------------------------------ test hooks ---
  /** Exposed on window.__game for automated tests / debugging. */
  debugApi() {
    return {
      gm: this,
      world: this.world,
      start: (id: string) => this.startMatch(getCharacter(id)!),
      select: () => this.showSelect(),
      player: () => this.world.player,
      state: () => this.state,
      press: (action: Parameters<InputManager['simulatePress']>[0]) => {
        this.input.simulatePress(action);
        setTimeout(() => this.input.simulateRelease(action), 60);
      },
      hold: (action: Parameters<InputManager['simulatePress']>[0], down: boolean) => (down ? this.input.simulatePress(action) : this.input.simulateRelease(action)),
      cast: (slot: number) => this.world.player?.abilities?.tryCast(slot, this.world),
      freeCast: (on: boolean) => {
        const ab = this.world.player?.abilities;
        if (ab) ab.freeCasting = on;
      },
      fillUlt: () => this.world.player?.abilities?.addUltCharge(100),
      spawn: (type: keyof typeof ENEMIES, dist = 8, angle = 0) => {
        const p = this.world.player!;
        const pos = p.position.clone().add(new THREE.Vector3(Math.sin(p.facing + angle) * dist, 0, Math.cos(p.facing + angle) * dist));
        pos.y = this.arena.groundHeight(pos.x, pos.z);
        return this.spawnEnemy(ENEMIES[type], pos);
      },
      stopWaves: () => this.waves.reset(),
      /** Pause/resume the real-time loop (tests drive the game with advance()). */
      setLoop: (on: boolean) => (this.loopEnabled = on),
      /** Render a single frame (for screenshots while the loop is paused). */
      renderOnce: () => this.step(1 / 60, true),
      /** Deterministically advance the simulation at 60 Hz without rendering (tests). */
      advance: (seconds: number) => {
        const n = Math.round(seconds * 60);
        for (let i = 0; i < n; i++) {
          this.step(1 / 60, false);
          this.input.endFrame();
        }
      },
      godMode: (on: boolean) => {
        const p = this.world.player;
        if (p) p.effects.apply({ id: 'god', duration: on ? 99999 : 0.001, mods: { damageTaken: on ? 0 : 1 }, flags: { invulnerable: on } }, this.world);
      },
      stats: () => ({ fps: this.fps, actors: this.world.actors.length, enemies: this.world.aliveEnemies().length, particles: Object.values(this.vfx.layers).reduce((s, l) => s + l.count, 0), calls: this.renderer.info.render.calls, tris: this.renderer.info.render.triangles }),
      saveSettings: () => saveSettings(this.settings),
    };
  }
}
