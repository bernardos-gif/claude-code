import type { Actor, ActorController } from './Actor';
import type { World } from '../core/World';
import type { AttackStep } from '../data/types';

/**
 * Controller for summoned allies (Shadow clones): hunts the nearest enemy,
 * blinks to close distance and runs its owner's combo at reduced damage.
 */
export class CloneAI implements ActorController {
  private step = 0;
  private blinkCd = 0.3;
  private retarget = 0;
  private target: Actor | null = null;

  constructor(
    public readonly owner: Actor,
    private readonly combo: AttackStep[],
    private readonly damageScale: number,
    private readonly onBlink?: (clone: Actor, from: import('three').Vector3, to: import('three').Vector3, world: World) => void,
  ) {}

  update(a: Actor, dt: number, w: World): void {
    a.moveDir.set(0, 0, 0);
    if (!a.alive) return;
    this.blinkCd -= dt;
    this.retarget -= dt;
    if (this.retarget <= 0 || !this.target?.targetable) {
      this.retarget = 0.6;
      const pref = this.owner.target;
      this.target = pref && pref.targetable && pref.position.distanceTo(a.position) < 20 && Math.random() < 0.5 ? pref : w.combat.nearestHostile(a.faction, a.position, 32);
    }
    const t = this.target;
    if (!t) {
      const d = this.owner.position.clone().sub(a.position).setY(0);
      if (d.length() > 4) a.moveDir.copy(d.normalize());
      return;
    }
    const d = t.position.clone().sub(a.position).setY(0);
    const dist = d.length();
    a.target = t;
    if (dist > 2.1 + t.radius) {
      if (dist > 6 && this.blinkCd <= 0 && a.canAct) {
        this.blinkCd = 1.4;
        const to = t.position.clone().addScaledVector(d.normalize(), -(t.radius + 1.2));
        const safe = w.arena.safePoint(a.position, to, a.radius);
        const from = a.position.clone();
        a.position.copy(safe);
        a.faceTowards(t.position);
        this.onBlink?.(a, from, safe, w);
        return;
      }
      if (a.canAct) a.moveDir.copy(d.normalize());
    } else {
      const canChain = a.state === 'attack' && a.attack?.canCancel();
      if (a.canAct || canChain) {
        a.faceTowards(t.position);
        a.startAttack(this.combo[this.step % this.combo.length], w, this.damageScale);
        this.step++;
      }
    }
  }
}
