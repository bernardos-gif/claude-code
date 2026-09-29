import * as THREE from 'three';
import type { Actor, ActorController } from './Actor';
import type { World } from '../core/World';
import type { CharacterDefinition } from '../data/types';
import { ABILITY_ACTIONS } from '../config/controls';
import type { DamageResult } from '../combat/CombatSystem';

/**
 * Turns player input into character actions: camera-relative movement,
 * buffered combos, dodges, jumps, ability casts and target selection.
 */
export class PlayerController implements ActorController {
  comboIndex = 0;
  private sinceAttack = 99;
  lockTarget: Actor | null = null;
  softTarget: Actor | null = null;
  private fwd = new THREE.Vector3();
  private right = new THREE.Vector3();
  private move = new THREE.Vector3();
  lastFail = '';
  lastFailTime = -9;

  constructor(private def: CharacterDefinition) {}

  update(a: Actor, dt: number, w: World): void {
    const input = w.input;
    input.now = w.realTime;
    if (!input.gameplayEnabled || !a.alive) {
      a.moveDir.set(0, 0, 0);
      return;
    }
    const cam = w.camera;
    cam.forward(this.fwd);
    cam.right(this.right);
    let x = 0;
    let z = 0;
    if (input.isDown('moveForward')) z += 1;
    if (input.isDown('moveBack')) z -= 1;
    if (input.isDown('moveRight')) x += 1;
    if (input.isDown('moveLeft')) x -= 1;
    this.move.set(0, 0, 0).addScaledVector(this.fwd, z).addScaledVector(this.right, x);
    if (this.move.lengthSq() > 0) this.move.normalize();
    a.moveDir.copy(this.move);
    a.moveScale = input.isDown('walk') ? 0.4 : 1;
    a.userData.inputDir = this.move.clone();
    a.userData.aimDir = this.fwd.clone();

    this.updateTargeting(a, w);

    if (input.buffered('jump', 0.15) && a.tryJump(w)) input.consume('jump');

    if (input.buffered('dodge', 0.15)) {
      const dir = this.move.lengthSq() > 0.01 ? this.move : this.fwd.clone().negate();
      if (a.tryDodge(w, dir)) {
        input.consume('dodge');
        this.comboIndex = 0;
      }
    }

    ABILITY_ACTIONS.forEach((act, i) => {
      if (!input.buffered(act, 0.2) || !a.abilities) return;
      if (a.abilities.tryCast(i, w)) {
        input.consume(act);
        this.comboIndex = 0;
      } else {
        const why = a.abilities.lastFailReason;
        if (why !== 'busy') {
          input.consume(act);
          this.lastFail = why;
          this.lastFailTime = w.realTime;
          w.events.emit('abilityFailed', i, why);
        }
      }
    });

    this.sinceAttack += dt;
    if (a.state !== 'attack' && this.sinceAttack > this.def.combo.resetTime) this.comboIndex = 0;
    if (input.buffered('attack', 0.3)) {
      const canChain = a.state === 'attack' && a.attack?.canCancel();
      if (a.canAct || canChain) {
        const combo = this.def.combo;
        if (!a.grounded) {
          if (!a.userData.airAttackUsed) {
            a.userData.airAttackUsed = true;
            a.startAttack(combo.air, w);
            this.comboIndex = 0;
          }
        } else {
          if (this.comboIndex >= combo.ground.length) this.comboIndex = 0;
          a.startAttack(combo.ground[this.comboIndex], w);
          this.comboIndex = (this.comboIndex + 1) % combo.ground.length;
        }
        this.sinceAttack = 0;
        input.consume('attack');
      }
    }
    if (a.grounded) a.userData.airAttackUsed = false;
  }

  private updateTargeting(a: Actor, w: World): void {
    const input = w.input;
    if (this.lockTarget && !this.lockTarget.targetable) this.lockTarget = null;
    // Soft target: the enemy closest to the camera's aim within range.
    let best: Actor | null = null;
    let bestScore = Infinity;
    for (const e of w.combat.hostilesOf(a.faction)) {
      const dx = e.position.x - a.position.x;
      const dz = e.position.z - a.position.z;
      const d = Math.hypot(dx, dz);
      if (d > 28) continue;
      const cos = d > 0.01 ? (dx * this.fwd.x + dz * this.fwd.z) / d : 1;
      if (cos < 0.35 && d > 4) continue;
      const score = (1 - cos) * 12 + d * 0.35;
      if (score < bestScore) {
        bestScore = score;
        best = e;
      }
    }
    this.softTarget = best;
    if (input.wasPressed('lockOn') || input.buffered('lockOn', 0.05)) {
      input.consume('lockOn');
      if (this.lockTarget && best && best !== this.lockTarget) this.lockTarget = best;
      else if (this.lockTarget) this.lockTarget = null;
      else this.lockTarget = best;
    }
    a.target = this.lockTarget ?? this.softTarget;
    w.camera.lockTarget = this.lockTarget;
  }

  onDamaged(a: Actor, result: DamageResult, attacker: Actor | null, w: World): void {
    w.audio.play(a.def.sounds.hurt, a.position, { volume: 0.7 });
    if (result.amount > a.health.max * 0.08) w.ui.vignette('#ff2020', Math.min(0.6, result.amount / a.health.max * 3), 0.5);
  }
}
