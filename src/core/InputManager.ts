import { Action, ControlSettings } from '../config/controls';

/**
 * Low-level input capture. Gameplay code only ever asks about Actions,
 * which are resolved through the configurable binding table.
 */
export class InputManager {
  private down = new Set<string>();
  private pressed = new Set<string>();
  private released = new Set<string>();
  private pressTime = new Map<Action, number>();
  private consumed = new Set<Action>();
  private captureCb: ((code: string) => void) | null = null;

  mouseDX = 0;
  mouseDY = 0;
  wheel = 0;
  pointerLocked = false;
  /** True when gameplay should receive input (false in menus). */
  gameplayEnabled = false;
  private dragging = false;
  private ignoreMoveUntil = 0;
  now = 0;

  constructor(private element: HTMLElement, public settings: ControlSettings) {
    window.addEventListener('keydown', this.onKeyDown);
    window.addEventListener('keyup', this.onKeyUp);
    window.addEventListener('blur', () => this.down.clear());
    element.addEventListener('mousedown', this.onMouseDown);
    // While rebinding, mouse buttons anywhere on the page (menus cover the canvas) are captured.
    window.addEventListener(
      'mousedown',
      (e) => {
        if (!this.captureCb) return;
        e.preventDefault();
        e.stopPropagation();
        this.handlePress(`Mouse${e.button}`);
      },
      true,
    );
    window.addEventListener('mouseup', this.onMouseUp);
    window.addEventListener('mousemove', this.onMouseMove);
    element.addEventListener('wheel', this.onWheel, { passive: false });
    element.addEventListener('contextmenu', (e) => e.preventDefault());
    document.addEventListener('pointerlockchange', () => {
      this.pointerLocked = document.pointerLockElement === this.element;
      // Browsers can emit a bogus large movement right after locking.
      this.ignoreMoveUntil = performance.now() + 120;
      this.mouseDX = 0;
      this.mouseDY = 0;
    });
  }

  /** Next key/mouse press is delivered to cb instead of gameplay (used by the rebinding UI). */
  captureNextKey(cb: (code: string) => void): void {
    this.captureCb = cb;
  }

  requestPointerLock(): void {
    if (this.pointerLocked) return;
    try {
      const res = (this.element as any).requestPointerLock?.();
      if (res && typeof res.catch === 'function') res.catch(() => {});
    } catch {
      /* pointer lock unsupported (headless, iframe): drag-to-look fallback */
    }
  }

  exitPointerLock(): void {
    if (document.pointerLockElement) document.exitPointerLock();
  }

  private handlePress(code: string): void {
    if (this.captureCb) {
      const cb = this.captureCb;
      this.captureCb = null;
      cb(code);
      return;
    }
    if (!this.down.has(code)) {
      this.pressed.add(code);
      for (const action of this.actionsFor(code)) {
        this.pressTime.set(action, this.now);
        this.consumed.delete(action);
      }
    }
    this.down.add(code);
  }

  private handleRelease(code: string): void {
    if (this.down.has(code)) this.released.add(code);
    this.down.delete(code);
  }

  private actionsFor(code: string): Action[] {
    const out: Action[] = [];
    const b = this.settings.bindings;
    for (const k in b) {
      if (b[k as Action].includes(code)) out.push(k as Action);
    }
    return out;
  }

  private onKeyDown = (e: KeyboardEvent) => {
    if (this.captureCb) {
      e.preventDefault();
      this.handlePress(e.code);
      return;
    }
    const target = e.target as HTMLElement | null;
    if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA')) return;
    if (this.gameplayEnabled && (e.code === 'Tab' || e.code === 'Space' || e.code.startsWith('Arrow') || e.code === 'KeyF')) {
      e.preventDefault();
    }
    if (e.repeat) return;
    this.handlePress(e.code);
  };

  private onKeyUp = (e: KeyboardEvent) => {
    this.handleRelease(e.code);
  };

  private onMouseDown = (e: MouseEvent) => {
    const code = `Mouse${e.button}`;
    if (this.gameplayEnabled && !this.pointerLocked) this.requestPointerLock();
    this.dragging = true;
    this.handlePress(code);
  };

  private onMouseUp = (e: MouseEvent) => {
    this.dragging = false;
    this.handleRelease(`Mouse${e.button}`);
  };

  private onMouseMove = (e: MouseEvent) => {
    if (performance.now() < this.ignoreMoveUntil) return;
    if (Math.abs(e.movementX) > 250 || Math.abs(e.movementY) > 250) return;
    if (this.pointerLocked) {
      this.mouseDX += e.movementX;
      this.mouseDY += e.movementY;
    } else if (this.dragging && this.gameplayEnabled) {
      // Fallback when pointer lock is unavailable: drag to look.
      this.mouseDX += e.movementX;
      this.mouseDY += e.movementY;
    }
  };

  private onWheel = (e: WheelEvent) => {
    if (this.gameplayEnabled) e.preventDefault();
    this.wheel += Math.sign(e.deltaY);
  };

  isDown(action: Action): boolean {
    for (const code of this.settings.bindings[action]) if (this.down.has(code)) return true;
    return false;
  }

  wasPressed(action: Action): boolean {
    for (const code of this.settings.bindings[action]) if (this.pressed.has(code)) return true;
    return false;
  }

  /** Buffered press: true if the action was pressed within `window` seconds and not yet consumed. */
  buffered(action: Action, window: number): boolean {
    const t = this.pressTime.get(action);
    if (t === undefined || this.consumed.has(action)) return false;
    return this.now - t <= window;
  }

  consume(action: Action): void {
    this.consumed.add(action);
  }

  /** Synthetic input used by automated tests and the attract-mode demo. */
  simulatePress(action: Action): void {
    const code = this.settings.bindings[action][0];
    if (code) this.handlePress(code);
  }

  simulateRelease(action: Action): void {
    const code = this.settings.bindings[action][0];
    if (code) this.handleRelease(code);
  }

  endFrame(): void {
    this.pressed.clear();
    this.released.clear();
    this.mouseDX = 0;
    this.mouseDY = 0;
    this.wheel = 0;
  }

  clearAll(): void {
    this.down.clear();
    this.pressed.clear();
    this.pressTime.clear();
    this.consumed.clear();
  }
}
