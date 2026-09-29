import * as THREE from 'three';
import type { CharacterDefinition } from '../data/types';
import type { World, WorldUI } from '../core/World';
import type { Actor } from '../entities/Actor';
import type { PlayerController } from '../entities/PlayerController';
import type { DamageResult } from '../combat/CombatSystem';
import { ABILITY_ACTIONS, ACTION_LABELS, Action, ControlSettings, DEFAULT_BINDINGS, keyLabel, saveSettings } from '../config/controls';
import type { InputManager } from '../core/InputManager';
import { iconDataURL } from './Icons';

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, cls = '', parent?: HTMLElement, html?: string): HTMLElementTagNameMap[K] => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html !== undefined) e.innerHTML = html;
  parent?.appendChild(e);
  return e;
};

interface FloatItem {
  el: HTMLDivElement;
  pos: THREE.Vector3;
  age: number;
  life: number;
  rise: number;
}

interface BarItem {
  root: HTMLDivElement;
  fill: HTMLDivElement;
  trail: HTMLDivElement;
  status: HTMLDivElement;
  name: HTMLDivElement;
  lastIcons: string;
}

const STATUS_COLORS: Record<string, string> = {
  burn: '#ff7a20',
  stun: '#ffe060',
  slow: '#7fb0ff',
  static: '#9fdcff',
  mark: '#d080ff',
  blind: '#9a90a8',
  armor: '#c8ccd4',
  haste: '#9fdcff',
  stealth: '#a080d0',
  giant: '#ffc070',
  storm: '#bfe8ff',
  realm: '#c080ff',
};

export interface GameOverStats {
  wave: number;
  kills: number;
  maxCombo: number;
  damage: number;
  time: number;
  score: number;
}

export interface SettingsCallbacks {
  onQuality(q: 'high' | 'medium' | 'low'): void;
  onVolumes(sfx: number, music: number): void;
  getQuality(): string;
}

/**
 * DOM-based HUD and menus. Everything character-specific (portrait, name,
 * colours, ability icons, key labels) is rebuilt from the CharacterDefinition
 * in setupHUD(), so the HUD adapts to any fighter automatically.
 */
export class UIManager implements WorldUI {
  readonly root: HTMLDivElement;
  private hud: HTMLDivElement;
  private hpFill!: HTMLDivElement;
  private hpTrail!: HTMLDivElement;
  private hpText!: HTMLDivElement;
  private ultFill!: HTMLDivElement;
  private ultText!: HTMLDivElement;
  private ultBox!: HTMLDivElement;
  private statusRow!: HTMLDivElement;
  private slots: { root: HTMLDivElement; cd: HTMLDivElement; txt: HTMLDivElement; key: HTMLDivElement; pips: HTMLDivElement }[] = [];
  private comboBox!: HTMLDivElement;
  private comboNum!: HTMLDivElement;
  private comboRank!: HTMLDivElement;
  private comboBar!: HTMLDivElement;
  private waveBox!: HTMLDivElement;
  private reticle!: HTMLDivElement;
  private barsLayer!: HTMLDivElement;
  private floatLayer!: HTMLDivElement;
  private announceEl!: HTMLDivElement;
  private flashEl!: HTMLDivElement;
  private vignetteEl!: HTMLDivElement;
  private lowHpEl!: HTMLDivElement;
  private helpEl!: HTMLDivElement;
  private hintEl!: HTMLDivElement;
  private overlay: HTMLDivElement;
  private loadingEl: HTMLDivElement;
  private floats: FloatItem[] = [];
  private floatPool: HTMLDivElement[] = [];
  private bars = new Map<Actor, BarItem>();
  private flashT = 0;
  private flashDur = 1;
  private flashAlpha = 0;
  private vigT = 0;
  private vigDur = 1;
  private vigStrength = 0;
  private lastCombo = 0;
  private def: CharacterDefinition | null = null;
  private tmp = new THREE.Vector3();
  private announceTimer = 0;
  private lastHp = 0;

  constructor(parent: HTMLElement, private input: InputManager, private settings: ControlSettings) {
    this.root = el('div', 'ui-root', parent);
    this.hud = el('div', 'hud hidden', this.root);
    this.overlay = el('div', 'overlay hidden', this.root);
    this.loadingEl = el('div', 'loading', this.root, `<div class="loading-inner"><div class="loading-logo">ELEMENTAL <span>CLASH</span></div><div class="spinner"></div><div class="loading-text">Forging the arena…</div></div>`);
    this.buildHudSkeleton();
  }

  // ---------------------------------------------------------- loading --
  setLoading(text: string | null): void {
    if (text === null) {
      this.loadingEl.classList.add('fade');
      setTimeout(() => this.loadingEl.classList.add('hidden'), 600);
    } else {
      this.loadingEl.classList.remove('hidden', 'fade');
      (this.loadingEl.querySelector('.loading-text') as HTMLElement).textContent = text;
    }
  }

  // -------------------------------------------------------------- HUD --
  private buildHudSkeleton(): void {
    const h = this.hud;
    this.barsLayer = el('div', 'bars-layer', h);
    this.floatLayer = el('div', 'float-layer', h);
    this.reticle = el('div', 'reticle hidden', h, '<i></i><i></i><i></i><i></i>');
    this.vignetteEl = el('div', 'vignette', h);
    this.lowHpEl = el('div', 'lowhp', h);
    this.flashEl = el('div', 'screen-flash', h);
    el('div', 'crosshair', h);
    this.announceEl = el('div', 'announce', h);
    this.waveBox = el('div', 'wave-box', h);
    this.comboBox = el('div', 'combo hidden', h);
    this.comboNum = el('div', 'combo-num', this.comboBox);
    el('div', 'combo-label', this.comboBox, 'HITS');
    this.comboRank = el('div', 'combo-rank', this.comboBox);
    const cb = el('div', 'combo-timer', this.comboBox);
    this.comboBar = el('div', 'combo-timer-fill', cb);
    this.hintEl = el('div', 'hint', h);
    this.helpEl = el('div', 'help hidden', h);
  }

  setupHUD(def: CharacterDefinition, portrait: string): void {
    this.def = def;
    this.hud.style.setProperty('--c1', def.theme.primary);
    this.hud.style.setProperty('--c2', def.theme.secondary);
    this.hud.style.setProperty('--glow', def.theme.glow);
    this.hud.style.setProperty('--dark', def.theme.dark);
    this.hud.querySelector('.player-panel')?.remove();
    this.hud.querySelector('.ability-bar')?.remove();
    const panel = el('div', 'player-panel', this.hud);
    const pwrap = el('div', 'portrait', panel);
    const img = el('img', '', pwrap);
    img.src = portrait;
    const info = el('div', 'player-info', panel);
    el('div', 'player-name', info, `${def.name}<span>${def.title}</span>`);
    const hp = el('div', 'hp-bar', info);
    this.hpTrail = el('div', 'hp-trail', hp);
    this.hpFill = el('div', 'hp-fill', hp);
    this.hpText = el('div', 'hp-text', hp);
    this.ultBox = el('div', 'ult-bar', info);
    this.ultFill = el('div', 'ult-fill', this.ultBox);
    this.ultText = el('div', 'ult-text', this.ultBox);
    this.statusRow = el('div', 'status-row', info);

    const bar = el('div', 'ability-bar', this.hud);
    this.slots = [];
    def.abilities.forEach((ab, i) => {
      const slot = el('div', `slot${ab.ultimate ? ' ult' : ''}`, bar);
      slot.title = `${ab.name}\n${ab.description}`;
      const icon = el('img', 'slot-icon', slot);
      icon.src = iconDataURL(ab.icon);
      const cd = el('div', 'slot-cd', slot);
      const txt = el('div', 'slot-txt', slot);
      const key = el('div', 'slot-key', slot);
      const pips = el('div', 'slot-pips', slot);
      el('div', 'slot-name', slot, ab.name);
      this.slots.push({ root: slot, cd, txt, key, pips });
      void i;
    });
    this.refreshKeyLabels();
    this.hintEl.innerHTML = `<b>${keyLabel(this.settings.bindings.help[0])}</b> controls &nbsp;·&nbsp; <b>${keyLabel(this.settings.bindings.pause[0])}</b> pause &nbsp;·&nbsp; <b>${keyLabel(this.settings.bindings.lockOn[0])}</b> lock target`;
    this.buildHelp();
    for (const b of this.bars.values()) b.root.remove();
    this.bars.clear();
    this.lastHp = 1;
  }

  refreshKeyLabels(): void {
    this.slots.forEach((s, i) => (s.key.textContent = keyLabel(this.settings.bindings[ABILITY_ACTIONS[i]][0])));
  }

  private buildHelp(): void {
    const b = this.settings.bindings;
    const rows: [string, string][] = [
      ['Move', `${keyLabel(b.moveForward[0])} ${keyLabel(b.moveLeft[0])} ${keyLabel(b.moveBack[0])} ${keyLabel(b.moveRight[0])}`],
      ['Camera', 'Mouse (click to capture)'],
      ['Basic attack / combo', keyLabel(b.attack[0])],
      ['Jump (double jump: Volt, Shadow)', keyLabel(b.jump[0])],
      ['Dodge (invulnerable)', keyLabel(b.dodge[0])],
      ['Abilities', ABILITY_ACTIONS.slice(0, 5).map((a) => keyLabel(b[a][0])).join(' ')],
      ['Ultimate', keyLabel(b.ultimate[0])],
      ['Lock / cycle target', b.lockOn.map(keyLabel).join(' / ')],
      ['Walk', keyLabel(b.walk[0])],
      ['Pause / settings', keyLabel(b.pause[0])],
      ['Mute', keyLabel(b.mute[0])],
    ];
    this.helpEl.innerHTML = `<h3>Controls</h3>${rows.map(([a, k]) => `<div class="row"><span>${a}</span><b>${k}</b></div>`).join('')}${this.def ? `<h3>${this.def.passive.name}</h3><p>${this.def.passive.description}</p>` : ''}`;
  }

  toggleHelp(force?: boolean): void {
    const hidden = force === undefined ? !this.helpEl.classList.contains('hidden') : !force;
    this.helpEl.classList.toggle('hidden', hidden);
  }

  showHUD(show: boolean): void {
    this.hud.classList.toggle('hidden', !show);
  }

  // ------------------------------------------------------ WorldUI impl --
  floatText(pos: THREE.Vector3, text: string, color: string, size = 1): void {
    const e = this.floatPool.pop() ?? el('div', 'float');
    e.className = 'float text';
    e.textContent = text;
    e.style.color = color;
    e.style.fontSize = `${Math.round(22 * size)}px`;
    this.floatLayer.appendChild(e);
    this.floats.push({ el: e, pos: pos.clone(), age: 0, life: 1.1, rise: 1.4 });
  }

  damageNumber(r: DamageResult, playerTarget: boolean): void {
    if (r.amount <= 0) return;
    const e = this.floatPool.pop() ?? el('div', 'float');
    const big = r.crit || r.amount > 120;
    e.className = `float dmg${r.crit ? ' crit' : ''}${playerTarget ? ' taken' : ''}`;
    e.textContent = `${Math.round(r.amount)}${r.crit ? '!' : ''}`;
    e.style.color = '';
    e.style.fontSize = `${Math.round(Math.min(46, 16 + Math.sqrt(r.amount) * (big ? 2.4 : 1.5)))}px`;
    this.floatLayer.appendChild(e);
    const p = r.position.clone().add(new THREE.Vector3((Math.random() - 0.5) * 0.8, 0.4, (Math.random() - 0.5) * 0.8));
    this.floats.push({ el: e, pos: p, age: 0, life: big ? 1.0 : 0.75, rise: big ? 1.6 : 1.1 });
  }

  screenFlash(color: string, alpha: number, duration: number): void {
    this.flashEl.style.background = color;
    this.flashAlpha = alpha;
    this.flashT = 0;
    this.flashDur = duration;
  }

  vignette(color: string, strength: number, duration: number): void {
    this.vignetteEl.style.boxShadow = `inset 0 0 180px 40px ${color}`;
    this.vigStrength = Math.max(this.vigStrength * (1 - this.vigT / this.vigDur), strength);
    this.vigT = 0;
    this.vigDur = duration;
  }

  announce(text: string, sub?: string, color = '#ffffff'): void {
    this.announceEl.innerHTML = `<div class="a-main" style="color:${color}">${text}</div>${sub ? `<div class="a-sub">${sub}</div>` : ''}`;
    this.announceEl.classList.remove('show');
    void this.announceEl.offsetWidth;
    this.announceEl.classList.add('show');
    this.announceTimer = 2.2;
  }

  abilityFailed(slot: number, reason: string): void {
    const s = this.slots[slot];
    if (!s) return;
    s.root.classList.remove('deny');
    void s.root.offsetWidth;
    s.root.classList.add('deny');
    if (reason === 'target') this.hintFlash('No target in range');
    else if (reason === 'meter') this.hintFlash('Ultimate not charged');
    else if (reason === 'grounded') this.hintFlash('Must be on the ground');
  }

  private hintTimer = 0;
  private hintFlash(text: string): void {
    const e = this.hud.querySelector('.hint-flash') as HTMLDivElement ?? el('div', 'hint-flash', this.hud);
    e.textContent = text;
    e.classList.add('show');
    this.hintTimer = 1.2;
  }

  // ----------------------------------------------------------- update --
  update(dt: number, w: World, camera: THREE.PerspectiveCamera, pc: PlayerController | null, wave: { wave: number; remaining: number; score: number; time: number; state: string }): void {
    const p = w.player;
    const W = window.innerWidth;
    const H = window.innerHeight;
    if (p && this.def) {
      const hp = p.health;
      this.hpFill.style.width = `${(hp.ratio * 100).toFixed(2)}%`;
      this.hpTrail.style.width = `${((hp.displayed / hp.max) * 100).toFixed(2)}%`;
      this.hpText.textContent = `${Math.ceil(hp.current)} / ${hp.max}`;
      this.hpFill.classList.toggle('low', hp.ratio < 0.3);
      this.lowHpEl.style.opacity = hp.ratio < 0.3 && p.alive ? `${0.35 + Math.sin(w.realTime * 6) * 0.15}` : '0';
      if (hp.ratio < this.lastHp - 0.001) {
        this.hpFill.parentElement!.classList.remove('hurt');
        void this.hpFill.offsetWidth;
        this.hpFill.parentElement!.classList.add('hurt');
      }
      this.lastHp = hp.ratio;
      const ab = p.abilities!;
      const ult = ab.ult / ab.ultMax;
      this.ultFill.style.width = `${(ult * 100).toFixed(1)}%`;
      this.ultText.textContent = ab.ultReady ? `ULTIMATE READY — ${keyLabel(this.settings.bindings.ultimate[0])}` : `ULTIMATE ${Math.floor(ult * 100)}%`;
      this.ultBox.classList.toggle('ready', ab.ultReady);
      ab.defs.forEach((d, i) => {
        const s = this.slots[i];
        const frac = ab.cooldownFraction(i);
        const ready = ab.isReady(i);
        s.root.classList.toggle('ready', ready);
        s.root.classList.toggle('cooling', !ready);
        s.cd.style.background = frac > 0 ? `conic-gradient(rgba(0,0,0,0.72) ${frac * 360}deg, rgba(0,0,0,0) 0)` : 'none';
        if (d.ultimate) s.txt.textContent = ready ? '' : `${Math.floor((1 - frac) * 100)}%`;
        else if (!ready) s.txt.textContent = ab.cooldowns[i] > 1 ? `${Math.ceil(ab.cooldowns[i])}` : ab.cooldowns[i].toFixed(1);
        else s.txt.textContent = '';
        if (ab.maxCharges[i] > 1) {
          const html = Array.from({ length: ab.maxCharges[i] }, (_, k) => `<i class="${k < ab.charges[i] ? 'on' : ''}"></i>`).join('');
          if (s.pips.innerHTML !== html) s.pips.innerHTML = html;
        }
        s.root.classList.toggle('active', ab.active?.def === d || ab.background.some((b) => b.def === d));
      });
      // Status effects on the player.
      const icons = p.effects.list.filter((e) => e.spec.icon).map((e) => `<span class="st" style="--sc:${STATUS_COLORS[e.spec.icon!] ?? '#fff'}" title="${e.spec.id}">${e.spec.icon!.toUpperCase()}<em style="width:${Math.max(0, Math.min(1, e.remaining / e.spec.duration)) * 100}%"></em></span>`).join('');
      if (this.statusRow.innerHTML !== icons) this.statusRow.innerHTML = icons;
      if (p.userData.ultJustReady) {
        p.userData.ultJustReady = false;
        this.ultBox.classList.remove('flashy');
        void this.ultBox.offsetWidth;
        this.ultBox.classList.add('flashy');
        w.audio.play('ult_ready');
        this.announce('ULTIMATE READY', `Press ${keyLabel(this.settings.bindings.ultimate[0])}`, this.def.theme.glow);
      }
    }

    // Combo.
    const combo = w.combat.comboCount;
    if (combo >= 2) {
      this.comboBox.classList.remove('hidden');
      if (combo !== this.lastCombo) {
        this.comboNum.textContent = `${combo}`;
        this.comboNum.classList.remove('pop');
        void this.comboNum.offsetWidth;
        this.comboNum.classList.add('pop');
        const rank = combo >= 60 ? 'GODLIKE' : combo >= 40 ? 'SAVAGE' : combo >= 25 ? 'BRUTAL' : combo >= 12 ? 'GREAT' : combo >= 5 ? 'NICE' : '';
        this.comboRank.textContent = rank;
        this.comboRank.dataset.rank = rank;
      }
      this.comboBar.style.width = `${(w.combat.comboTimer / w.combat.comboWindow) * 100}%`;
    } else this.comboBox.classList.add('hidden');
    this.lastCombo = combo;

    const mins = Math.floor(wave.time / 60);
    const secs = Math.floor(wave.time % 60);
    this.waveBox.innerHTML = `<div class="wave-num">WAVE <b>${wave.wave}</b></div><div class="wave-sub">${wave.state === 'intermission' ? 'Next wave incoming' : `${wave.remaining} enemies left`}</div><div class="wave-score">${wave.score.toLocaleString()} <span>pts</span> · ${mins}:${secs.toString().padStart(2, '0')}</div>`;

    // Enemy health bars.
    const seen = new Set<Actor>();
    const target = p?.target ?? null;
    for (const a of w.actors) {
      if (a.faction !== 'enemy' || a.removed || a.hidden) continue;
      if (!a.alive && w.time - a.deathTime > 0.6) continue;
      const head = this.tmp.copy(a.position);
      head.y += a.height + 0.45;
      const dist = camera.position.distanceTo(head);
      const recently = w.time - a.health.lastDamageTime < 4;
      if (dist > 55 || (!recently && a !== target && dist > 22)) continue;
      const v = head.project(camera);
      if (v.z > 1 || v.x < -1.1 || v.x > 1.1 || v.y < -1.1 || v.y > 1.1) continue;
      seen.add(a);
      let bar = this.bars.get(a);
      if (!bar) {
        const root = el('div', 'ebar', this.barsLayer);
        const name = el('div', 'ebar-name', root);
        name.textContent = a.def.name;
        const box = el('div', 'ebar-box', root);
        const trail = el('div', 'ebar-trail', box);
        const fill = el('div', 'ebar-fill', box);
        const status = el('div', 'ebar-status', root);
        bar = { root, fill, trail, status, name, lastIcons: '' };
        this.bars.set(a, bar);
        if (a.stats.scale > 1.2) root.classList.add('big');
      }
      const x = (v.x + 1) * 0.5 * W;
      const y = (1 - v.y) * 0.5 * H;
      const s = Math.max(0.6, Math.min(1.15, 18 / dist));
      bar.root.style.transform = `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px) translate(-50%, -100%) scale(${s.toFixed(3)})`;
      bar.root.style.opacity = a.alive ? '1' : `${Math.max(0, 1 - (w.time - a.deathTime) / 0.6)}`;
      bar.fill.style.width = `${(a.health.ratio * 100).toFixed(1)}%`;
      bar.trail.style.width = `${((a.health.displayed / a.health.max) * 100).toFixed(1)}%`;
      bar.root.classList.toggle('targeted', a === target);
      bar.root.classList.toggle('locked', a === pc?.lockTarget);
      const icons = a.effects.list.filter((e) => e.spec.icon).map((e) => `<i style="--sc:${STATUS_COLORS[e.spec.icon!] ?? '#fff'}">${e.spec.icon === 'static' ? '⚡'.repeat(e.stacks) : e.spec.icon!.slice(0, 1).toUpperCase()}</i>`).join('');
      if (icons !== bar.lastIcons) {
        bar.status.innerHTML = icons;
        bar.lastIcons = icons;
      }
    }
    for (const [a, bar] of this.bars) {
      if (!seen.has(a)) {
        if (a.removed) {
          bar.root.remove();
          this.bars.delete(a);
        } else bar.root.style.opacity = '0';
      }
    }

    // Target reticle.
    if (target && target.targetable) {
      const c = this.tmp.copy(target.position);
      c.y += target.height * 0.55;
      const v = c.project(camera);
      if (v.z < 1) {
        this.reticle.classList.remove('hidden');
        this.reticle.classList.toggle('locked', target === pc?.lockTarget);
        const size = Math.max(40, Math.min(160, (target.height * 520) / Math.max(1, camera.position.distanceTo(target.position))));
        this.reticle.style.transform = `translate(${((v.x + 1) * 0.5 * W).toFixed(1)}px, ${((1 - v.y) * 0.5 * H).toFixed(1)}px) translate(-50%, -50%)`;
        this.reticle.style.width = this.reticle.style.height = `${size.toFixed(0)}px`;
      } else this.reticle.classList.add('hidden');
    } else this.reticle.classList.add('hidden');

    // Floating numbers.
    for (let i = this.floats.length - 1; i >= 0; i--) {
      const f = this.floats[i];
      f.age += dt;
      const k = f.age / f.life;
      if (k >= 1) {
        f.el.remove();
        this.floatPool.push(f.el);
        this.floats.splice(i, 1);
        continue;
      }
      const pos = this.tmp.copy(f.pos);
      pos.y += f.rise * (1 - Math.pow(1 - k, 2));
      const v = pos.project(camera);
      if (v.z > 1) {
        f.el.style.opacity = '0';
        continue;
      }
      const scale = k < 0.12 ? 0.6 + (k / 0.12) * 0.7 : 1.3 - Math.min(0.3, (k - 0.12) * 1.2);
      f.el.style.transform = `translate(${((v.x + 1) * 0.5 * W).toFixed(1)}px, ${((1 - v.y) * 0.5 * H).toFixed(1)}px) translate(-50%, -50%) scale(${scale.toFixed(3)})`;
      f.el.style.opacity = `${k > 0.7 ? (1 - k) / 0.3 : 1}`;
    }

    // Screen effects.
    this.flashT += dt;
    this.flashEl.style.opacity = `${Math.max(0, this.flashAlpha * (1 - this.flashT / this.flashDur))}`;
    this.vigT += dt;
    this.vignetteEl.style.opacity = `${Math.max(0, this.vigStrength * (1 - this.vigT / this.vigDur))}`;
    if (this.announceTimer > 0) {
      this.announceTimer -= dt;
      if (this.announceTimer <= 0) this.announceEl.classList.remove('show');
    }
    if (this.hintTimer > 0) {
      this.hintTimer -= dt;
      if (this.hintTimer <= 0) this.hud.querySelector('.hint-flash')?.classList.remove('show');
    }
  }

  clearWorldElements(): void {
    for (const f of this.floats) f.el.remove();
    this.floats = [];
    for (const b of this.bars.values()) b.root.remove();
    this.bars.clear();
    this.flashAlpha = 0;
    this.vigStrength = 0;
    this.announceEl.classList.remove('show');
  }

  // ------------------------------------------------------------ menus --
  hideOverlay(): void {
    this.overlay.classList.add('hidden');
    this.overlay.innerHTML = '';
  }

  showPause(cb: { resume(): void; restart(): void; select(): void }, settingsCb: SettingsCallbacks): void {
    this.overlay.classList.remove('hidden');
    this.overlay.innerHTML = '';
    const panel = el('div', 'menu-panel', this.overlay);
    el('h2', '', panel, 'PAUSED');
    const tabs = el('div', 'menu-tabs', panel);
    const body = el('div', 'menu-body', panel);
    const show = (tab: string) => {
      tabs.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b.dataset.tab === tab));
      body.innerHTML = '';
      if (tab === 'main') {
        const list = el('div', 'menu-list', body);
        const btn = (t: string, fn: () => void, cls = '') => {
          const b = el('button', `btn ${cls}`, list, t);
          b.onclick = fn;
        };
        btn('Resume', cb.resume, 'primary');
        btn('Restart Battle', cb.restart);
        btn('Character Select', cb.select);
      } else if (tab === 'controls') this.buildRebind(body);
      else this.buildSettings(body, settingsCb);
    };
    for (const [id, label] of [
      ['main', 'Menu'],
      ['controls', 'Controls'],
      ['settings', 'Settings'],
    ]) {
      const b = el('button', 'tab', tabs, label);
      b.dataset.tab = id;
      b.onclick = () => show(id);
    }
    show('main');
  }

  private buildRebind(body: HTMLElement): void {
    const list = el('div', 'rebind', body);
    el('p', 'muted', list, 'Click a binding, then press a key or mouse button. Esc cancels.');
    const actions = Object.keys(ACTION_LABELS) as Action[];
    const render = () => {
      grid.innerHTML = '';
      for (const act of actions) {
        const row = el('div', 'rb-row', grid);
        el('span', '', row, ACTION_LABELS[act]);
        const b = el('button', 'rb-key', row, this.settings.bindings[act].map(keyLabel).join(' / '));
        b.onclick = (ev) => {
          ev.stopPropagation();
          b.textContent = 'Press…';
          b.classList.add('waiting');
          setTimeout(() => {
            this.input.captureNextKey((code) => {
              if (code !== 'Escape') {
                // Remove this code from any other action to avoid conflicts.
                for (const other of actions) {
                  if (other !== act) this.settings.bindings[other] = this.settings.bindings[other].filter((c) => c !== code);
                }
                this.settings.bindings[act] = [code, ...this.settings.bindings[act].filter((c) => c !== code)].slice(0, 2);
                saveSettings(this.settings);
                this.refreshKeyLabels();
                this.buildHelp();
              }
              render();
            });
          }, 50);
        };
      }
    };
    const grid = el('div', 'rb-grid', list);
    render();
    const reset = el('button', 'btn', list, 'Reset to defaults');
    reset.onclick = () => {
      this.settings.bindings = JSON.parse(JSON.stringify(DEFAULT_BINDINGS));
      saveSettings(this.settings);
      this.refreshKeyLabels();
      this.buildHelp();
      render();
    };
  }

  private buildSettings(body: HTMLElement, cb: SettingsCallbacks): void {
    const s = this.settings;
    const wrap = el('div', 'settings', body);
    const slider = (label: string, min: number, max: number, step: number, value: number, on: (v: number) => void) => {
      const row = el('label', 'set-row', wrap);
      el('span', '', row, label);
      const inp = el('input', '', row) as HTMLInputElement;
      inp.type = 'range';
      inp.min = `${min}`;
      inp.max = `${max}`;
      inp.step = `${step}`;
      inp.value = `${value}`;
      const out = el('b', '', row, value.toFixed(2));
      inp.oninput = () => {
        on(Number(inp.value));
        out.textContent = Number(inp.value).toFixed(2);
        saveSettings(s);
      };
    };
    slider('Mouse sensitivity', 0.2, 3, 0.05, s.mouseSensitivity, (v) => (s.mouseSensitivity = v));
    slider('Sound effects', 0, 1, 0.05, s.sfxVolume, (v) => {
      s.sfxVolume = v;
      cb.onVolumes(s.sfxVolume, s.musicVolume);
    });
    slider('Music', 0, 1, 0.05, s.musicVolume, (v) => {
      s.musicVolume = v;
      cb.onVolumes(s.sfxVolume, s.musicVolume);
    });
    const inv = el('label', 'set-row', wrap);
    el('span', '', inv, 'Invert camera Y');
    const box = el('input', '', inv) as HTMLInputElement;
    box.type = 'checkbox';
    box.checked = s.invertY;
    box.onchange = () => {
      s.invertY = box.checked;
      saveSettings(s);
    };
    const q = el('div', 'set-row', wrap);
    el('span', '', q, 'Graphics quality');
    const qs = el('div', 'seg', q);
    for (const level of ['low', 'medium', 'high'] as const) {
      const b = el('button', `seg-btn${cb.getQuality() === level ? ' on' : ''}`, qs, level);
      b.onclick = () => {
        cb.onQuality(level);
        qs.querySelectorAll('button').forEach((x) => x.classList.toggle('on', x === b));
      };
    }
  }

  showGameOver(stats: GameOverStats, def: CharacterDefinition, cb: { retry(): void; select(): void }): void {
    this.overlay.classList.remove('hidden');
    this.overlay.innerHTML = '';
    const panel = el('div', 'menu-panel gameover', this.overlay);
    panel.style.setProperty('--c1', def.theme.primary);
    el('h2', '', panel, 'DEFEATED');
    el('div', 'go-sub', panel, `${def.name} fell on wave ${stats.wave}`);
    const grid = el('div', 'go-grid', panel);
    const mins = Math.floor(stats.time / 60);
    const secs = Math.floor(stats.time % 60);
    for (const [k, v] of [
      ['Score', stats.score.toLocaleString()],
      ['Waves survived', `${Math.max(0, stats.wave - 1)}`],
      ['Enemies defeated', `${stats.kills}`],
      ['Best combo', `${stats.maxCombo}`],
      ['Damage dealt', Math.round(stats.damage).toLocaleString()],
      ['Time', `${mins}:${secs.toString().padStart(2, '0')}`],
    ]) {
      const c = el('div', 'go-cell', grid);
      el('div', 'go-v', c, v);
      el('div', 'go-k', c, k);
    }
    const list = el('div', 'menu-list row', panel);
    const retry = el('button', 'btn primary', list, 'Fight Again');
    retry.onclick = cb.retry;
    const sel = el('button', 'btn', list, 'Character Select');
    sel.onclick = cb.select;
  }
}
