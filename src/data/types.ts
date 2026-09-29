/**
 * Data contracts for characters, enemies, attacks and abilities.
 * A new fighter is added by writing one CharacterDefinition (see README → "Adding a fifth character").
 */
import type { Actor } from '../entities/Actor';
import type { World } from '../core/World';
import type { AbilityCast } from '../combat/AbilitySystem';
import type { Rig } from '../characters/Rig';
import type { AnimationSet } from '../characters/AnimationClip';
import type { DamageResult, DamageSpec } from '../combat/CombatSystem';
import type * as THREE from 'three';

export type Faction = 'player' | 'enemy';
export type ElementType = 'fire' | 'lightning' | 'earth' | 'shadow' | 'physical' | 'void';

export interface CharacterStats {
  maxHealth: number;
  /** Run speed (units / second). */
  moveSpeed: number;
  walkSpeed: number;
  acceleration: number;
  /** Radians per second. */
  turnSpeed: number;
  /** Base damage of basic attacks (combo steps scale this). */
  attackDamage: number;
  /** Mitigation: damage × 100 / (100 + defense). */
  defense: number;
  /** Multiplier on basic-attack playback speed. */
  attackSpeed: number;
  dodgeDistance: number;
  dodgeDuration: number;
  dodgeCooldown: number;
  /** Seconds of invulnerability at the start of a dodge. */
  dodgeIFrames: number;
  /** Multiplier applied to all ability damage. */
  abilityPower: number;
  /** Multiplier applied to all ability cooldowns (lower = faster). */
  cooldownMultiplier: number;
  critChance: number;
  critMultiplier: number;
  jumpVelocity: number;
  airJumps: number;
  gravityScale: number;
  /** Stagger resistance: hits with stagger below this do not interrupt. */
  poise: number;
  /** Knockback resistance. */
  mass: number;
  /** Model / hurtbox scale. */
  scale: number;
  ultChargeRate: number;
}

// ---------------------------------------------------------------- attacks --
export interface MeleeHitSpec {
  /** Seconds (before attack-speed scaling) into the step. */
  time: number;
  range: number;
  /** Full cone angle in degrees. */
  arc: number;
  /** Multiplier on stats.attackDamage. */
  damage: number;
  knockback: number;
  launch?: number;
  hitstun: number;
  stagger: number;
  hitstop?: number;
  shake?: number;
  element?: ElementType;
  /** Vertical reach above/below the attacker's feet. */
  heightMin?: number;
  heightMax?: number;
  critBonus?: number;
}

export interface SwingTrail {
  socket: 'handL' | 'handR' | 'footL' | 'footR' | 'weapon';
  color: number;
  from: number;
  to: number;
  width?: number;
}

export interface AttackContext {
  attacker: Actor;
  world: World;
  step: AttackStep;
  hitIndex: number;
}

export interface AttackStep {
  name: string;
  anim: string;
  /** Total step length in seconds before attack-speed scaling. */
  duration: number;
  hits: MeleeHitSpec[];
  /** Forward distance travelled during [lungeStart, lungeEnd]. */
  lunge?: number;
  lungeStart?: number;
  lungeEnd?: number;
  /** After this time the next combo input is accepted (buffered input fires here). */
  cancelTime: number;
  swingSound?: string;
  trail?: SwingTrail[];
  superArmor?: boolean;
  /** Each target can be hit only once across all hit frames (charges). */
  hitOnce?: boolean;
  onStart?(ctx: AttackContext): void;
  onHitFrame?(ctx: AttackContext): void;
  onHit?(ctx: AttackContext, target: Actor, result: DamageResult): void;
}

export interface ComboDef {
  ground: AttackStep[];
  air: AttackStep;
  /** Seconds after a step ends before the chain resets to step 0. */
  resetTime: number;
}

// -------------------------------------------------------------- abilities --
export type IconGlyph =
  | 'dash' | 'fist' | 'fireballs' | 'tornado' | 'meteor' | 'nova'
  | 'blink' | 'thunderFist' | 'chain' | 'field' | 'spear' | 'storm'
  | 'quake' | 'rock' | 'charge' | 'shield' | 'cracks' | 'giant'
  | 'shadowStep' | 'blades' | 'smoke' | 'clone' | 'execute' | 'realm'
  | 'star' | 'swirl';

export interface IconSpec {
  glyph: IconGlyph;
  /** Background gradient (inner, outer). */
  bg: [string, string];
  /** Glyph colour. */
  fg: string;
  /** Optional glow colour. */
  glow?: string;
}

export interface AbilityDef {
  id: string;
  name: string;
  description: string;
  /** Seconds (scaled by stats.cooldownMultiplier). Ultimates use the meter instead. */
  cooldown: number;
  charges?: number;
  /** Headline damage (before abilityPower) — also used by the implementation. */
  damage: number;
  ultimate?: boolean;
  icon: IconSpec;
  /** Main animation clip, used by the selection-screen preview. */
  anim: string;
  castInAir?: boolean;
  /** When true the cast does not lock movement (buffs such as Iron Skin). */
  freeMovement?: boolean;
  tags: string[];
  /** Optional precondition, e.g. Execution needs a nearby enemy. */
  canCast?(caster: Actor, world: World): boolean;
  /** Builds the ability timeline. */
  cast(c: AbilityCast): void;
}

export interface PassiveDef {
  name: string;
  description: string;
}

// -------------------------------------------------------------- characters --
export interface CharacterHooks {
  /** Adjust outgoing damage before mitigation (crits, backstabs, bonuses). */
  modifyOutgoing?(self: Actor, target: Actor, spec: DamageSpec, world: World): void;
  onDealDamage?(self: Actor, target: Actor, result: DamageResult, spec: DamageSpec, world: World): void;
  onTakeDamage?(self: Actor, result: DamageResult, world: World): void;
  onUpdate?(self: Actor, dt: number, world: World): void;
  onLand?(self: Actor, fallSpeed: number, world: World): void;
  onFootstep?(self: Actor, world: World): void;
  /** Called once when the actor is created (set per-actor callbacks here). */
  onSpawn?(self: Actor, world: World): void;
}

export interface CharacterVFX {
  /** Impact effect when this character hits something. */
  hit(world: World, pos: THREE.Vector3, dir: THREE.Vector3, strength: number, crit: boolean): void;
  dodge(world: World, actor: Actor, dir: THREE.Vector3): void;
  land(world: World, actor: Actor, strength: number): void;
  death(world: World, actor: Actor): void;
  /** Ambient per-frame particles (embers, sparks...). */
  aura?(world: World, actor: Actor, dt: number): void;
  footstep?(world: World, actor: Actor): void;
}

export interface CharacterSounds {
  swing: string;
  heavySwing: string;
  hit: string;
  heavyHit: string;
  dodge: string;
  jump: string;
  land: string;
  hurt: string;
  death: string;
  footstep: string;
}

/** How enemies perceive this fighter; drives AI adaptation for any future character. */
export interface ThreatProfile {
  /** 0 slow … 1 extremely fast / teleporting. */
  mobility: number;
  /** 0 melee only … 1 heavy ranged pressure. */
  range: number;
  /** 0 fragile … 1 tank. */
  durability: number;
  /** 0 visible … 1 stealth specialist. */
  stealth: number;
  /** 0 single target … 1 big area damage. */
  area: number;
}

export interface CameraProfile {
  distance: number;
  height: number;
  shoulder: number;
  fov: number;
}

export interface CharacterTheme {
  primary: string;
  secondary: string;
  glow: string;
  dark: string;
}

export interface CharacterDefinition {
  id: string;
  name: string;
  title: string;
  role: string;
  description: string;
  playstyle: string;
  /** 1 (easy) – 3 (hard). */
  difficulty: number;
  element: ElementType;
  theme: CharacterTheme;
  stats: CharacterStats;
  buildModel(): Rig;
  animations: AnimationSet;
  combo: ComboDef;
  /** Exactly six abilities; index 5 is the ultimate. */
  abilities: AbilityDef[];
  passive: PassiveDef;
  hooks: CharacterHooks;
  vfx: CharacterVFX;
  sounds: CharacterSounds;
  threat: ThreatProfile;
  camera: CameraProfile;
  portrait: IconSpec;
  /** Selection-screen rating bars (0–10), purely presentational. */
  ratings: { power: number; speed: number; defense: number; range: number; control: number };
}

// ----------------------------------------------------------------- enemies --
export interface AIProfile {
  /** Distance the AI tries to keep from its target. */
  preferredRange: number;
  /** Distance at which melee attacks are attempted. */
  attackRange: number;
  /** Retreat when the target is closer than this (ranged). */
  retreatRange: number;
  /** 0..1 probability weight of attacking when able. */
  aggression: number;
  /** Seconds between attack attempts. */
  attackCooldown: number;
  /** How much the AI circles around its target. */
  strafe: number;
  /** Turn rate multiplier while tracking (anti-backstab behaviour). */
  turnRate: number;
  /** Chance to dodge incoming projectiles / telegraphed attacks. */
  evasion: number;
  /** Move away from harmful hazard zones. */
  avoidHazards: boolean;
  /** Seconds the AI keeps chasing a last-known position when the target is hidden. */
  memory: number;
  /** Speed multiplier while fleeing. */
  fleeSpeed: number;
  /** Chance per decision to panic and flee when the target closes in quickly. */
  panic: number;
}

export interface EnemyAttack extends AttackStep {
  /** Minimum/maximum target distance for choosing this attack. */
  minRange: number;
  maxRange: number;
  weight: number;
  /** Telegraph (ground marker) radius for area attacks. */
  telegraph?: number;
  projectile?: {
    speed: number;
    damage: number;
    radius: number;
    color: number;
    time: number;
    count?: number;
    spread?: number;
    arc?: boolean;
  };
}

export interface EnemyDefinition {
  id: string;
  name: string;
  stats: CharacterStats;
  buildModel(): Rig;
  animations: AnimationSet;
  attacks: EnemyAttack[];
  ai: AIProfile;
  /** Per-player-character tactical overrides (keyed by CharacterDefinition.id). */
  vsCharacter: Record<string, Partial<AIProfile>>;
  sounds: CharacterSounds;
  vfx: CharacterVFX;
  score: number;
  healthBarOffset: number;
}
