import * as THREE from 'three';
import { EventBus } from './EventBus';
import type { Actor } from '../entities/Actor';
import type { CharacterDefinition } from '../data/types';
import { CombatSystem } from '../combat/CombatSystem';
import { ProjectileSystem } from '../combat/ProjectileSystem';
import { ZoneSystem } from '../combat/ZoneSystem';
import { HealthSystem } from '../combat/HealthSystem';
import { CharacterController } from '../entities/CharacterController';
import type { Arena } from '../world/Arena';
import type { Lighting } from '../world/Lighting';
import type { VFXManager } from '../vfx/VFXManager';
import type { AudioManager } from '../audio/AudioManager';
import type { CameraController } from '../camera/CameraController';
import type { InputManager } from './InputManager';

/** HUD features gameplay code can call without depending on the DOM layer. */
export interface WorldUI {
  floatText(pos: THREE.Vector3, text: string, color: string, size?: number): void;
  screenFlash(color: string, alpha: number, duration: number): void;
  announce(text: string, sub?: string, color?: string): void;
  vignette(color: string, strength: number, duration: number): void;
}

/**
 * Shared simulation state and the service locator handed to abilities, AI,
 * and controllers. Owns world time, hit-stop and slow motion.
 */
export class World {
  readonly events = new EventBus();
  readonly actors: Actor[] = [];
  player: Actor | null = null;
  playerDef: CharacterDefinition | null = null;
  /** Global gameplay flags (e.g. realmActive pauses enemy spawning). */
  flags: Record<string, any> = {};
  time = 0;
  realTime = 0;
  private hitstop = 0;
  private slowmoTimer = 0;
  private slowmoScale = 1;
  readonly combat: CombatSystem;
  readonly projectiles: ProjectileSystem;
  readonly zones: ZoneSystem;
  readonly health = new HealthSystem();
  readonly physics: CharacterController;
  /** Extra per-frame callbacks (ultimate sequences, spawners). */
  private tickers: ((dt: number) => boolean | void)[] = [];

  constructor(
    public readonly scene: THREE.Scene,
    public readonly arena: Arena,
    public readonly lighting: Lighting,
    public readonly vfx: VFXManager,
    public readonly audio: AudioManager,
    public readonly camera: CameraController,
    public readonly input: InputManager,
    public ui: WorldUI,
  ) {
    this.combat = new CombatSystem(this);
    this.projectiles = new ProjectileSystem(this);
    this.zones = new ZoneSystem(this);
    this.physics = new CharacterController(this);
  }

  /** Freeze-frame on impactful hits (does not stack beyond the longest request). */
  hitStop(seconds: number): void {
    this.hitstop = Math.max(this.hitstop, Math.min(0.14, seconds));
  }

  slowMo(scale: number, seconds: number): void {
    this.slowmoScale = scale;
    this.slowmoTimer = seconds;
  }

  get timeScale(): number {
    return this.slowmoTimer > 0 ? this.slowmoScale : 1;
  }

  /** Converts real frame time into simulation time. */
  worldDelta(realDt: number): number {
    this.realTime += realDt;
    if (this.slowmoTimer > 0) this.slowmoTimer -= realDt;
    if (this.hitstop > 0) {
      this.hitstop -= realDt;
      return realDt * 0.03;
    }
    return realDt * this.timeScale;
  }

  addActor(a: Actor): Actor {
    this.actors.push(a);
    this.scene.add(a.root);
    return a;
  }

  removeActor(a: Actor): void {
    a.removed = true;
    a.abilities?.cancelAll();
    this.scene.remove(a.root);
    const i = this.actors.indexOf(a);
    if (i >= 0) this.actors.splice(i, 1);
    if (this.player === a) this.player = null;
  }

  /** Registers a per-frame callback; return true from it to unregister. */
  addTicker(fn: (dt: number) => boolean | void): void {
    this.tickers.push(fn);
  }

  enemiesOf(a: Actor): Actor[] {
    return this.combat.hostilesOf(a.faction);
  }

  aliveEnemies(): Actor[] {
    return this.actors.filter((a) => a.faction === 'enemy' && a.alive && !a.removed);
  }

  update(dt: number): void {
    this.time += dt;
    const actors = this.actors;
    for (const a of actors) if (!a.removed && !a.hidden) a.controller?.update(a, dt, this);
    for (const a of [...actors]) if (!a.removed && !a.effects.flags.frozen) a.update(dt, this);
    this.physics.step(actors, dt);
    this.projectiles.update(dt);
    this.zones.update(dt);
    this.combat.update(dt);
    this.health.update(actors, dt);
    for (let i = this.tickers.length - 1; i >= 0; i--) {
      if (this.tickers[i](dt)) this.tickers.splice(i, 1);
    }
    for (const a of actors) {
      if (a.removed) continue;
      if (!a.effects.flags.frozen) a.anim.update(dt);
      if (a.alive && !a.hidden) a.def.vfx.aura?.(this, a, dt);
    }
  }

  clearTickers(): void {
    this.tickers = [];
  }

  reset(): void {
    for (const a of [...this.actors]) this.removeActor(a);
    this.projectiles.clear();
    this.zones.clear();
    this.combat.reset();
    this.clearTickers();
    this.hitstop = 0;
    this.slowmoTimer = 0;
    this.time = 0;
    this.flags = {};
    this.lighting.clear();
  }
}
