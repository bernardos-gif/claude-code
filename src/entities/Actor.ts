import * as THREE from 'three';
import type { CharacterHooks, CharacterSounds, CharacterStats, CharacterVFX, Faction, AttackStep, ComboDef } from '../data/types';
import type { AnimationSet } from '../characters/AnimationClip';
import { AnimationController } from '../characters/AnimationController';
import type { Rig } from '../characters/Rig';
import { Health } from '../combat/HealthSystem';
import { EffectManager } from '../combat/StatusEffects';
import type { World } from '../core/World';
import type { DamageResult, DamageSpec } from '../combat/CombatSystem';
import type { AbilitySystem } from '../combat/AbilitySystem';
import { MeleeRunner } from '../combat/MeleeRunner';
import { angleDiff, clamp, dirFromYaw, moveAngleTowards, yawFromDir } from '../core/math';

export type ActorState =
  | 'idle'
  | 'move'
  | 'air'
  | 'attack'
  | 'ability'
  | 'dodge'
  | 'hitstun'
  | 'knockback'
  | 'knockdown'
  | 'getup'
  | 'stunned'
  | 'dead'
  | 'spawn'
  | 'cinematic';

export type ActorKind = 'player' | 'enemy' | 'clone';

/** Common subset shared by CharacterDefinition and EnemyDefinition. */
export interface ActorDef {
  id: string;
  name: string;
  stats: CharacterStats;
  animations: AnimationSet;
  sounds: CharacterSounds;
  vfx: CharacterVFX;
  buildModel(): Rig;
  hooks?: CharacterHooks;
  combo?: ComboDef;
}

export interface ActorController {
  update(actor: Actor, dt: number, world: World): void;
  onDamaged?(actor: Actor, result: DamageResult, attacker: Actor | null, world: World): void;
}

const LOCOMOTION_STATES: ActorState[] = ['idle', 'move', 'air'];

export class Actor {
  static nextId = 1;
  readonly id = Actor.nextId++;
  readonly root = new THREE.Group();
  readonly visual = new THREE.Group();
  readonly rig: Rig;
  readonly anim: AnimationController;
  readonly health: Health;
  readonly effects: EffectManager;
  readonly stats: CharacterStats;
  readonly velocity = new THREE.Vector3();
  /** Desired horizontal move direction (unit or zero), set by the controller. */
  readonly moveDir = new THREE.Vector3();
  /** 0..1 (walk .. run) */
  moveScale = 1;
  facing = 0;
  grounded = true;
  groundY = 0;
  airJumpsUsed = 0;
  airDodgeUsed = false;
  fallPeakY = 0;
  hitWall = false;
  state: ActorState = 'idle';
  stateTime = 0;
  hitstunLeft = 0;
  iframes = 0;
  dodgeCooldown = 0;
  landTimer = 0;
  noGravity = 0;
  /** Scripted velocity is authoritative while > 0 (dashes, lunges). */
  scripted = false;
  passThrough = false;
  controller: ActorController | null = null;
  abilities: AbilitySystem | null = null;
  attack: MeleeRunner | null = null;
  target: Actor | null = null;
  owner: Actor | null = null;
  removed = false;
  deathTime = 0;
  worldTime = 0;
  lastAttacker: Actor | null = null;
  lastHitTime = -99;
  hidden = false;
  userData: Record<string, any> = {};
  private flashT = 0;
  private flashColor = new THREE.Color(1, 1, 1);
  private origEmissive: { mat: THREE.MeshStandardMaterial; color: THREE.Color; intensity: number; opacity: number; transparent: boolean }[] = [];
  private opacity = 1;
  targetOpacity = 1;
  private dodgeDir = new THREE.Vector3();
  private dodgeTime = 0;
  private dodgeDuration = 0;
  private visualScale = 1;
  /** Called every frame while dodging (Volt blink, Shadow smoke...). */
  onDodgeFrame: ((a: Actor, t: number, world: World) => void) | null = null;

  constructor(
    public readonly def: ActorDef,
    public readonly kind: ActorKind,
    public readonly faction: Faction,
  ) {
    this.stats = { ...def.stats };
    this.rig = def.buildModel();
    this.visual.add(this.rig.root);
    this.root.add(this.visual);
    this.anim = new AnimationController(this.rig, def.animations);
    this.health = new Health(this.stats.maxHealth);
    this.effects = new EffectManager(this);
    this.visualScale = this.stats.scale;
    this.visual.scale.setScalar(this.stats.scale);
    for (const mat of this.rig.materials) {
      this.origEmissive.push({
        mat,
        color: mat.emissive.clone(),
        intensity: mat.emissiveIntensity,
        opacity: mat.opacity,
        transparent: mat.transparent,
      });
    }
  }

  get position(): THREE.Vector3 {
    return this.root.position;
  }

  get name(): string {
    return this.def.name;
  }

  get alive(): boolean {
    return this.state !== 'dead' && !this.health.dead;
  }

  get scale(): number {
    return this.stats.scale * this.effects.mods.scale;
  }

  get radius(): number {
    return 0.42 * this.scale;
  }

  get height(): number {
    return this.rig.height * this.scale;
  }

  get targetable(): boolean {
    return this.alive && !this.hidden && !this.effects.flags.untargetable && !this.removed;
  }

  get invulnerable(): boolean {
    return this.iframes > 0 || this.effects.flags.invulnerable || this.hidden;
  }

  get stealthed(): boolean {
    return this.effects.flags.stealthed;
  }

  /** True when the actor can accept a new action (move/attack/ability). */
  get canAct(): boolean {
    return LOCOMOTION_STATES.includes(this.state) && !this.effects.flags.stunned && !this.effects.flags.frozen;
  }

  get inLocomotion(): boolean {
    return LOCOMOTION_STATES.includes(this.state);
  }

  forward(out = new THREE.Vector3()): THREE.Vector3 {
    return dirFromYaw(this.facing, out);
  }

  /** World position of the torso centre (for projectile aim, VFX). */
  center(out = new THREE.Vector3()): THREE.Vector3 {
    return out.copy(this.position).setY(this.position.y + this.height * 0.55);
  }

  socketPos(name: string, out = new THREE.Vector3()): THREE.Vector3 {
    const s = this.rig.sockets[name];
    if (!s) return this.center(out);
    return s.getWorldPosition(out);
  }

  faceTowards(p: THREE.Vector3, maxStep = Infinity): void {
    const dx = p.x - this.position.x;
    const dz = p.z - this.position.z;
    if (dx * dx + dz * dz < 1e-6) return;
    const yaw = yawFromDir(dx, dz);
    this.facing = maxStep === Infinity ? yaw : moveAngleTowards(this.facing, yaw, maxStep);
  }

  setState(s: ActorState): void {
    if (this.state === 'dead' && s !== 'dead') return;
    this.state = s;
    this.stateTime = 0;
  }

  /** Returns to idle/move/air depending on grounding. */
  returnToLocomotion(): void {
    this.scripted = false;
    this.setState(this.grounded ? 'idle' : 'air');
  }

  // ------------------------------------------------------------ actions --
  tryJump(world: World): boolean {
    if (!this.canAct || this.effects.flags.rooted) return false;
    if (this.grounded) {
      this.velocity.y = this.stats.jumpVelocity;
      this.grounded = false;
      this.setState('air');
      this.anim.play('jump', { fade: 0.06, restart: true });
      world.audio.play(this.def.sounds.jump, this.position);
      this.def.vfx.land(world, this, 0.4);
      return true;
    }
    if (this.airJumpsUsed < this.stats.airJumps) {
      this.airJumpsUsed++;
      this.velocity.y = this.stats.jumpVelocity * 0.92;
      this.setState('air');
      this.anim.play(this.anim.has('airJump') ? 'airJump' : 'jump', { fade: 0.04, restart: true });
      this.userData.airJumpAnim = this.anim.has('airJump');
      world.audio.play(this.def.sounds.jump, this.position, { pitch: 1.25 });
      this.def.vfx.dodge(world, this, new THREE.Vector3(0, 1, 0));
      return true;
    }
    return false;
  }

  canDodge(): boolean {
    if (this.dodgeCooldown > 0 || this.effects.flags.stunned || this.effects.flags.rooted || this.effects.flags.frozen) return false;
    if (!this.grounded && this.airDodgeUsed) return false;
    if (this.canAct) return true;
    // Dodge-cancel out of attack recovery.
    if (this.state === 'attack' && this.attack && this.attack.canCancel()) return true;
    return false;
  }

  tryDodge(world: World, dir: THREE.Vector3): boolean {
    if (!this.canDodge()) return false;
    if (this.attack) {
      this.attack.cancel();
      this.attack = null;
    }
    const d = dir.lengthSq() > 0.01 ? dir.clone().setY(0).normalize() : this.forward().multiplyScalar(-1);
    this.dodgeDir.copy(d);
    this.dodgeDuration = this.stats.dodgeDuration;
    this.dodgeTime = 0;
    this.iframes = this.stats.dodgeIFrames;
    this.dodgeCooldown = this.stats.dodgeCooldown;
    if (!this.grounded) this.airDodgeUsed = true;
    this.setState('dodge');
    this.scripted = true;
    this.noGravity = this.grounded ? 0 : this.stats.dodgeDuration;
    if (!this.grounded) this.velocity.y = Math.max(this.velocity.y, 0);
    // Dodge faces the movement direction except for backward dodges.
    const localAngle = angleDiff(this.facing, yawFromDir(d.x, d.z));
    const backwards = Math.abs(localAngle) > Math.PI * 0.6;
    if (!backwards) this.facing = yawFromDir(d.x, d.z);
    this.userData.dodgeBack = backwards;
    this.anim.play(backwards && this.anim.has('dodgeBack') ? 'dodgeBack' : 'dodge', { duration: this.dodgeDuration + 0.08, restart: true, fade: 0.05 });
    world.audio.play(this.def.sounds.dodge, this.position);
    this.def.vfx.dodge(world, this, d);
    return true;
  }

  startAttack(step: AttackStep, world: World, damageScale = 1): void {
    if (this.attack) this.attack.cancel();
    this.attack = new MeleeRunner(this, step, world, damageScale);
    this.setState('attack');
  }

  // ------------------------------------------------------------- damage --
  flash(color = 0xffffff, strength = 1): void {
    this.flashColor.set(color);
    this.flashT = strength;
  }

  interruptActions(world: World): void {
    if (this.attack) {
      this.attack.cancel();
      this.attack = null;
    }
    this.abilities?.interrupt(world);
    this.scripted = false;
    this.noGravity = 0;
  }

  /** Called by CombatSystem after damage has been applied. */
  receiveHit(result: DamageResult, spec: DamageSpec, attacker: Actor | null, world: World, dir: THREE.Vector3): void {
    this.lastAttacker = attacker;
    this.lastHitTime = world.time;
    this.flash(result.crit ? 0xfff2a0 : 0xffffff, spec.isDot ? 0.2 : 0.7);
    // Local-space hit direction for the flinch spring.
    const fwd = this.forward();
    const localZ = -(dir.x * fwd.x + dir.z * fwd.z);
    const localX = dir.x * fwd.z - dir.z * fwd.x;

    if (this.health.dead) {
      this.die(world, dir, spec.knockback ?? 0);
      return;
    }
    if (spec.isDot || spec.noReaction) {
      this.anim.flinch(localX, localZ, 0.25);
      return;
    }
    const inKnockdown = this.state === 'knockdown' || this.state === 'getup';
    const poise = this.stats.poise + this.effects.mods.poise;
    const armored = this.effects.flags.superArmor || (spec.stagger ?? 0) < poise || !!this.abilities?.active?.uninterruptible;
    const unblockable = (spec.stagger ?? 0) >= 250;
    const kbMul = this.effects.mods.knockbackTaken / Math.max(0.2, this.stats.mass);

    if ((armored && !unblockable) || inKnockdown) {
      this.anim.flinch(localX, localZ, 0.6);
      if (!this.effects.flags.superArmor && !inKnockdown) {
        this.velocity.x += dir.x * (spec.knockback ?? 0) * kbMul * 0.15;
        this.velocity.z += dir.z * (spec.knockback ?? 0) * kbMul * 0.15;
      }
      return;
    }

    this.interruptActions(world);
    this.faceTowards(this.position.clone().sub(dir));
    const kb = (spec.knockback ?? 0) * kbMul;
    const launch = (spec.launch ?? 0) * Math.min(1.2, kbMul);
    if (kb >= 11 || launch >= 5 || (this.state === 'knockback' && (launch > 0 || kb > 4))) {
      this.setState('knockback');
      this.velocity.x = dir.x * kb;
      this.velocity.z = dir.z * kb;
      this.velocity.y = Math.max(launch, this.grounded ? 4.5 : 3.5);
      this.grounded = false;
      this.anim.play('knockback', { fade: 0.05, restart: true });
    } else {
      this.setState('hitstun');
      this.hitstunLeft = spec.hitstun ?? 0.3;
      this.velocity.x = dir.x * kb;
      this.velocity.z = dir.z * kb;
      if (launch > 0) {
        this.velocity.y = launch;
        this.grounded = false;
      }
      this.anim.play('hit', { fade: 0.03, restart: true, duration: Math.max(0.25, this.hitstunLeft) });
    }
    this.anim.flinch(localX, localZ, 1);
  }

  die(world: World, dir: THREE.Vector3, force: number): void {
    if (this.state === 'dead') return;
    this.interruptActions(world);
    this.health.current = 0;
    this.setState('dead');
    this.deathTime = world.time;
    this.velocity.x = dir.x * Math.min(18, 4 + force * 0.6);
    this.velocity.z = dir.z * Math.min(18, 4 + force * 0.6);
    this.velocity.y = Math.max(this.velocity.y, 3 + Math.min(6, force * 0.2));
    this.grounded = false;
    this.anim.play('death', { fade: 0.06, restart: true });
    world.audio.play(this.def.sounds.death, this.position);
    this.def.vfx.death(world, this);
    world.events.emit('actorDied', this);
  }

  // ------------------------------------------------------------- update --
  update(dt: number, world: World): void {
    this.worldTime = world.time;
    this.stateTime += dt;
    if (this.iframes > 0) this.iframes -= dt;
    if (this.dodgeCooldown > 0) this.dodgeCooldown -= dt;
    if (this.landTimer > 0) this.landTimer -= dt;
    if (this.noGravity > 0) this.noGravity -= dt;

    this.effects.transient = {};
    if (this.attack?.step.superArmor) this.effects.transient.superArmor = true;
    if (this.abilities) this.abilities.update(dt, world);
    this.effects.update(dt, world);

    const flags = this.effects.flags;
    switch (this.state) {
      case 'attack':
        if (this.attack) {
          if (this.attack.update(dt)) {
            this.attack = null;
            this.returnToLocomotion();
          }
        } else this.returnToLocomotion();
        break;
      case 'dodge': {
        this.dodgeTime += dt;
        const t = this.dodgeTime / this.dodgeDuration;
        const speed = (this.stats.dodgeDistance / this.dodgeDuration) * (t < 0.7 ? 1.15 : 0.6);
        this.velocity.x = this.dodgeDir.x * speed;
        this.velocity.z = this.dodgeDir.z * speed;
        this.onDodgeFrame?.(this, t, world);
        if (t >= 1) {
          this.velocity.x *= 0.3;
          this.velocity.z *= 0.3;
          this.returnToLocomotion();
        }
        break;
      }
      case 'hitstun':
        this.hitstunLeft -= dt;
        if (this.hitstunLeft <= 0 && this.grounded) this.returnToLocomotion();
        break;
      case 'knockdown':
        if (this.stateTime > (this.kind === 'enemy' ? 0.75 : 0.45)) {
          this.setState('getup');
          this.anim.play('getup', { fade: 0.1, restart: true });
        }
        break;
      case 'getup':
        if (this.stateTime > this.anim.clipDuration('getup') * 0.9) {
          this.iframes = Math.max(this.iframes, 0.2);
          this.returnToLocomotion();
        }
        break;
      case 'stunned':
        if (!flags.stunned) this.returnToLocomotion();
        break;
      case 'dead':
        break;
      default:
        break;
    }

    if ((flags.stunned || flags.frozen) && this.state !== 'dead' && this.state !== 'knockback' && this.state !== 'stunned' && this.state !== 'cinematic') {
      this.interruptActions(world);
      this.setState('stunned');
      this.anim.play(this.anim.has('stunned') ? 'stunned' : 'hit', { fade: 0.08, speed: 0.4 });
    }

    this.def.hooks?.onUpdate?.(this, dt, world);
    this.updateLocomotionAnim(dt);
    this.updateFootsteps(world);
    this.updateVisuals(dt);
  }

  private updateLocomotionAnim(dt: number): void {
    if (!this.inLocomotion) {
      this.anim.setLean(0, 0);
      return;
    }
    const hs = Math.hypot(this.velocity.x, this.velocity.z);
    const moveSpeed = this.stats.moveSpeed * this.effects.mods.moveSpeed;
    if (this.grounded) {
      if (this.landTimer > 0 && hs < moveSpeed * 0.3) {
        this.anim.play('land', { fade: 0.05 });
        return;
      }
      const walkRef = this.stats.walkSpeed;
      if (hs < 0.4) {
        this.anim.play('idle', { fade: 0.2 });
        if (this.state !== 'idle') this.state = 'idle';
      } else if (hs < walkRef * 1.15) {
        this.anim.play('walk', { fade: 0.15, speed: clamp(hs / walkRef, 0.5, 1.6) });
        this.state = 'move';
      } else {
        this.anim.play('run', { fade: 0.15, speed: clamp(hs / this.stats.moveSpeed, 0.7, 2.2) });
        this.state = 'move';
      }
      // Lean into acceleration and turns.
      const turn = this.userData.turnRate ?? 0;
      this.anim.setLean(clamp(hs / Math.max(1, moveSpeed), 0, 1) * 0.08, clamp(-turn * 0.04, -0.2, 0.2));
    } else {
      this.state = 'air';
      if (this.anim.current === 'airJump' && !this.anim.isFinished()) {
        /* let the somersault finish */
      } else if (this.velocity.y > 1) this.anim.play('jump', { fade: 0.1 });
      else this.anim.play('fall', { fade: 0.25 });
      this.anim.setLean(0, 0);
    }
  }

  private stepPhase = 0;
  /** Footstep sounds/effects on each foot contact of the walk/run cycle. */
  private updateFootsteps(world: World): void {
    const name = this.anim.current;
    if (!this.grounded || !this.inLocomotion || (name !== 'walk' && name !== 'run')) return;
    const phase = (this.anim.time / this.anim.clipDuration(name)) % 1;
    const last = this.stepPhase;
    this.stepPhase = phase;
    if (!((last < 0.5 && phase >= 0.5) || phase < last)) return;
    const heavy = this.stats.mass > 2;
    if (this.kind === 'player' || heavy) {
      world.audio.play(this.def.sounds.footstep, this.position, { volume: this.kind === 'player' ? (heavy ? 0.45 : 0.25) : 0.35, pitch: 0.9 + Math.random() * 0.2 });
    }
    this.def.vfx.footstep?.(world, this);
    this.def.hooks?.onFootstep?.(this, world);
  }

  private updateVisuals(dt: number): void {
    this.root.rotation.y = this.facing;
    const targetScale = this.scale;
    this.visualScale += (targetScale - this.visualScale) * Math.min(1, dt * 6);
    this.visual.scale.setScalar(this.visualScale);

    if (this.flashT > 0) this.flashT = Math.max(0, this.flashT - dt * 9);
    const wantOpacity = this.targetOpacity * (this.stealthed ? 0.18 : 1);
    this.opacity += (wantOpacity - this.opacity) * Math.min(1, dt * 10);
    for (const o of this.origEmissive) {
      const m = o.mat;
      if (this.flashT > 0.001) {
        m.emissive.copy(o.color).lerp(this.flashColor, this.flashT);
        m.emissiveIntensity = o.intensity + this.flashT * 0.8;
      } else if (m.emissiveIntensity !== o.intensity || !m.emissive.equals(o.color)) {
        m.emissive.copy(o.color);
        m.emissiveIntensity = o.intensity;
      }
      const transparent = this.opacity < 0.98 || o.transparent;
      if (m.transparent !== transparent) {
        m.transparent = transparent;
        m.depthWrite = !transparent || o.transparent === false ? !transparent : m.depthWrite;
      }
      m.opacity = o.opacity * this.opacity;
    }
    this.root.visible = !this.hidden;
  }

  /** Reset baseline material values (after permanent tint changes such as Iron Skin). */
  refreshMaterialBaseline(): void {
    for (const o of this.origEmissive) {
      o.color.copy(o.mat.emissive);
      o.intensity = o.mat.emissiveIntensity;
    }
  }

  onLanded(world: World, fallSpeed: number): void {
    this.airJumpsUsed = 0;
    this.airDodgeUsed = false;
    if (this.state === 'knockback') {
      this.setState('knockdown');
      this.velocity.x *= 0.3;
      this.velocity.z *= 0.3;
      this.def.vfx.land(world, this, 0.9);
      world.audio.play('body_fall', this.position);
      world.camera.addShake(this.kind === 'player' ? 0.25 : 0.05, this.position);
      return;
    }
    if (this.state === 'dead') {
      this.velocity.x *= 0.4;
      this.velocity.z *= 0.4;
      return;
    }
    if (fallSpeed > 6) {
      this.landTimer = 0.14;
      this.def.vfx.land(world, this, Math.min(1, fallSpeed / 20));
      world.audio.play(this.def.sounds.land, this.position, { volume: Math.min(1, fallSpeed / 15) });
    }
    this.def.hooks?.onLand?.(this, fallSpeed, world);
  }
}
