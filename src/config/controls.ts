/**
 * Configurable control bindings. Every gameplay input goes through an Action,
 * so rebinding a key never requires touching gameplay code.
 * Codes use KeyboardEvent.code, plus Mouse0/Mouse1/Mouse2 for mouse buttons.
 */
export type Action =
  | 'moveForward'
  | 'moveBack'
  | 'moveLeft'
  | 'moveRight'
  | 'jump'
  | 'dodge'
  | 'attack'
  | 'ability1'
  | 'ability2'
  | 'ability3'
  | 'ability4'
  | 'ability5'
  | 'ultimate'
  | 'lockOn'
  | 'walk'
  | 'pause'
  | 'help'
  | 'mute';

export const ABILITY_ACTIONS: Action[] = ['ability1', 'ability2', 'ability3', 'ability4', 'ability5', 'ultimate'];

export const ACTION_LABELS: Record<Action, string> = {
  moveForward: 'Move Forward',
  moveBack: 'Move Back',
  moveLeft: 'Move Left',
  moveRight: 'Move Right',
  jump: 'Jump',
  dodge: 'Dodge',
  attack: 'Basic Attack',
  ability1: 'Ability 1',
  ability2: 'Ability 2',
  ability3: 'Ability 3',
  ability4: 'Ability 4',
  ability5: 'Ability 5',
  ultimate: 'Ultimate',
  lockOn: 'Lock / Cycle Target',
  walk: 'Walk (hold)',
  pause: 'Pause',
  help: 'Toggle Controls Help',
  mute: 'Mute Audio',
};

export const DEFAULT_BINDINGS: Record<Action, string[]> = {
  moveForward: ['KeyW', 'ArrowUp'],
  moveBack: ['KeyS', 'ArrowDown'],
  moveLeft: ['KeyA', 'ArrowLeft'],
  moveRight: ['KeyD', 'ArrowRight'],
  jump: ['Space'],
  dodge: ['ShiftLeft', 'ShiftRight'],
  attack: ['Mouse0'],
  ability1: ['KeyQ'],
  ability2: ['KeyE'],
  ability3: ['KeyR'],
  ability4: ['KeyF'],
  ability5: ['KeyZ'],
  ultimate: ['KeyX'],
  lockOn: ['Tab', 'Mouse2'],
  walk: ['ControlLeft'],
  pause: ['Escape', 'KeyP'],
  help: ['KeyH'],
  mute: ['KeyM'],
};

export interface ControlSettings {
  bindings: Record<Action, string[]>;
  mouseSensitivity: number;
  invertY: boolean;
  musicVolume: number;
  sfxVolume: number;
}

const STORAGE_KEY = 'elemental-clash.controls.v1';

export function defaultSettings(): ControlSettings {
  return {
    bindings: JSON.parse(JSON.stringify(DEFAULT_BINDINGS)),
    mouseSensitivity: 1,
    invertY: false,
    musicVolume: 0.35,
    sfxVolume: 0.8,
  };
}

export function loadSettings(): ControlSettings {
  const base = defaultSettings();
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return base;
    const parsed = JSON.parse(raw) as Partial<ControlSettings>;
    if (parsed.bindings) {
      for (const k of Object.keys(base.bindings) as Action[]) {
        const b = parsed.bindings[k];
        if (Array.isArray(b) && b.every((x) => typeof x === 'string')) base.bindings[k] = b;
      }
    }
    if (typeof parsed.mouseSensitivity === 'number') base.mouseSensitivity = parsed.mouseSensitivity;
    if (typeof parsed.invertY === 'boolean') base.invertY = parsed.invertY;
    if (typeof parsed.musicVolume === 'number') base.musicVolume = parsed.musicVolume;
    if (typeof parsed.sfxVolume === 'number') base.sfxVolume = parsed.sfxVolume;
  } catch {
    /* storage unavailable: defaults */
  }
  return base;
}

export function saveSettings(s: ControlSettings): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(s));
  } catch {
    /* ignore */
  }
}

export function keyLabel(code: string | undefined): string {
  if (!code) return '—';
  if (code === 'Mouse0') return 'LMB';
  if (code === 'Mouse1') return 'MMB';
  if (code === 'Mouse2') return 'RMB';
  if (code.startsWith('Key')) return code.slice(3);
  if (code.startsWith('Digit')) return code.slice(5);
  if (code.startsWith('Arrow')) return { ArrowUp: '↑', ArrowDown: '↓', ArrowLeft: '←', ArrowRight: '→' }[code] ?? code;
  if (code.startsWith('Shift')) return 'Shift';
  if (code.startsWith('Control')) return 'Ctrl';
  if (code.startsWith('Alt')) return 'Alt';
  if (code === 'Escape') return 'Esc';
  return code;
}
