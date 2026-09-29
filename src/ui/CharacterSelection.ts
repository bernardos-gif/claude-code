import * as THREE from 'three';
import type { CharacterDefinition, CharacterStats } from '../data/types';
import { CHARACTERS } from '../data/characters';
import { AnimationController } from '../characters/AnimationController';
import type { Rig } from '../characters/Rig';
import { VFXManager } from '../vfx/VFXManager';
import { FireFX, LightningFX, EarthFX, ShadowFX } from '../vfx/ElementFX';
import { Textures } from '../vfx/Textures';
import type { AudioManager } from '../audio/AudioManager';
import { ABILITY_ACTIONS, ControlSettings, keyLabel } from '../config/controls';
import { iconDataURL } from './Icons';
import { rand, TAU } from '../core/math';

const el = <K extends keyof HTMLElementTagNameMap>(tag: K, cls = '', parent?: HTMLElement, html?: string): HTMLElementTagNameMap[K] => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html !== undefined) e.innerHTML = html;
  parent?.appendChild(e);
  return e;
};

interface StatRow {
  label: string;
  get(s: CharacterStats): number;
  fmt(v: number): string;
  invert?: boolean;
}

const STAT_ROWS: StatRow[] = [
  { label: 'Health', get: (s) => s.maxHealth, fmt: (v) => `${v}` },
  { label: 'Move Speed', get: (s) => s.moveSpeed, fmt: (v) => `${v.toFixed(1)} m/s` },
  { label: 'Attack Damage', get: (s) => s.attackDamage, fmt: (v) => `${v}` },
  { label: 'Defense', get: (s) => s.defense, fmt: (v) => `${v}` },
  { label: 'Attack Speed', get: (s) => s.attackSpeed, fmt: (v) => `${v.toFixed(2)}×` },
  { label: 'Dodge Distance', get: (s) => s.dodgeDistance, fmt: (v) => `${v.toFixed(1)} m` },
  { label: 'Ability Damage', get: (s) => s.abilityPower, fmt: (v) => `${Math.round(v * 100)}%` },
  { label: 'Cooldown Speed', get: (s) => 1 / s.cooldownMultiplier, fmt: (v) => `${v >= 1 ? '+' : ''}${Math.round((v - 1) * 100)}%` },
  { label: 'Critical Chance', get: (s) => s.critChance, fmt: (v) => `${Math.round(v * 100)}%` },
];

/**
 * Character selection: 3D showcase (drag to rotate, click an ability to see
 * its animation), full stats, passive, and all six abilities with icons.
 */
export class CharacterSelection {
  readonly scene = new THREE.Scene();
  readonly camera = new THREE.PerspectiveCamera(32, 1, 0.1, 400);
  private root: HTMLDivElement;
  private info!: HTMLElement;
  private roster!: HTMLElement;
  private index = 0;
  private model: { holder: THREE.Group; rig: Rig; anim: AnimationController; def: CharacterDefinition } | null = null;
  private yaw = 0.35;
  private yawVel = 0;
  private dragging = false;
  private lastX = 0;
  private idleTime = 0;
  private vfx: VFXManager;
  private ring: THREE.Mesh;
  private ringMat: THREE.MeshBasicMaterial;
  private rim: THREE.DirectionalLight;
  private fill: THREE.PointLight;
  private hemi: THREE.HemisphereLight;
  private backMat: THREE.ShaderMaterial;
  private previewTimer = 0;
  private previewSlot = -1;
  private time = 0;
  visible = false;
  onStart: (def: CharacterDefinition) => void = () => {};

  constructor(parent: HTMLElement, private canvas: HTMLCanvasElement, private audio: AudioManager, private portraits: Record<string, string>, private settings: ControlSettings) {
    this.root = el('div', 'select hidden', parent);
    this.vfx = new VFXManager(this.scene, this.camera);
    this.vfx.groundFn = () => 0;

    // Stage.
    this.backMat = new THREE.ShaderMaterial({
      side: THREE.BackSide,
      depthWrite: false,
      uniforms: { c1: { value: new THREE.Color(0x3a0e04) }, c2: { value: new THREE.Color(0x05040a) } },
      vertexShader: `varying vec3 vP; void main(){ vP = position; gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }`,
      fragmentShader: `uniform vec3 c1; uniform vec3 c2; varying vec3 vP;
        void main(){ float h = normalize(vP).y; float r = length(normalize(vP).xz);
          vec3 col = mix(c1, c2, smoothstep(-0.1, 0.6, h));
          col += c1 * 0.6 * smoothstep(0.3, 0.0, abs(h - 0.05));
          gl_FragColor = vec4(col, 1.0);
          #include <colorspace_fragment>
        }`,
    });
    this.scene.add(new THREE.Mesh(new THREE.SphereGeometry(120, 32, 16), this.backMat));
    const floor = new THREE.Mesh(new THREE.CircleGeometry(40, 48), new THREE.MeshStandardMaterial({ color: 0x0c0a10, roughness: 0.35, metalness: 0.4 }));
    floor.rotation.x = -Math.PI / 2;
    floor.receiveShadow = true;
    this.scene.add(floor);
    const pedestal = new THREE.Mesh(new THREE.CylinderGeometry(1.5, 1.7, 0.3, 48), new THREE.MeshStandardMaterial({ color: 0x1c1a22, roughness: 0.4, metalness: 0.6 }));
    pedestal.position.y = 0.15;
    pedestal.receiveShadow = true;
    pedestal.castShadow = true;
    this.scene.add(pedestal);
    this.ringMat = new THREE.MeshBasicMaterial({ map: Textures.runes(), color: 0xff6a1a, transparent: true, opacity: 0.8, blending: THREE.AdditiveBlending, depthWrite: false });
    this.ring = new THREE.Mesh(new THREE.PlaneGeometry(3.4, 3.4), this.ringMat);
    this.ring.rotation.x = -Math.PI / 2;
    this.ring.position.y = 0.31;
    this.scene.add(this.ring);
    this.hemi = new THREE.HemisphereLight(0xbfc8ff, 0x201810, 0.7);
    this.scene.add(this.hemi);
    const key = new THREE.DirectionalLight(0xfff0e0, 2.6);
    key.position.set(3, 6, 5);
    key.castShadow = true;
    key.shadow.mapSize.set(1024, 1024);
    key.shadow.camera.left = key.shadow.camera.bottom = -4;
    key.shadow.camera.right = key.shadow.camera.top = 4;
    this.scene.add(key);
    this.rim = new THREE.DirectionalLight(0xff6a1a, 2.2);
    this.rim.position.set(-4, 3, -4);
    this.scene.add(this.rim);
    this.fill = new THREE.PointLight(0xff6a1a, 4, 8, 2);
    this.fill.position.set(0, 0.8, 1.2);
    this.scene.add(this.fill);
    this.scene.fog = new THREE.Fog(0x05040a, 12, 60);

    this.buildDOM();
    canvas.addEventListener('pointerdown', this.onDown);
    window.addEventListener('pointerup', this.onUp);
    window.addEventListener('pointermove', this.onMove);
    window.addEventListener('keydown', this.onKey);
  }

  private buildDOM(): void {
    const r = this.root;
    el('header', 'sel-title', r, `<div class="logo">ELEMENTAL <span>CLASH</span></div><div class="logo-sub">Choose your fighter</div>`);
    this.roster = el('aside', 'roster', r);
    CHARACTERS.forEach((def, i) => {
      const card = el('button', 'card', this.roster);
      card.style.setProperty('--c1', def.theme.primary);
      card.style.setProperty('--dark', def.theme.dark);
      card.innerHTML = `<img src="${this.portraits[def.id] ?? ''}" alt=""><div class="card-text"><div class="card-name">${def.name}</div><div class="card-role">${def.role} · ${def.element}</div></div><div class="card-key">${i + 1}</div>`;
      card.onmouseenter = () => this.audio.play('ui_hover');
      card.onclick = () => {
        this.audio.unlock();
        this.audio.play('ui_click');
        this.select(i);
      };
    });
    this.info = el('section', 'info', r);
    const foot = el('footer', 'sel-foot', r);
    el('div', 'sel-hint', foot, 'Drag to rotate &nbsp;·&nbsp; ← → switch fighter &nbsp;·&nbsp; click an ability to preview &nbsp;·&nbsp; Enter to start');
    const start = el('button', 'start-btn', foot, 'START BATTLE');
    start.onclick = () => this.start();
  }

  private start(): void {
    this.audio.unlock();
    this.audio.play('ui_select');
    this.onStart(CHARACTERS[this.index]);
  }

  show(): void {
    this.visible = true;
    this.root.classList.remove('hidden');
    this.select(this.index, true);
  }

  hide(): void {
    this.visible = false;
    this.root.classList.add('hidden');
  }

  select(i: number, force = false): void {
    if (i === this.index && this.model && !force) return;
    this.index = (i + CHARACTERS.length) % CHARACTERS.length;
    const def = CHARACTERS[this.index];
    this.roster.querySelectorAll('.card').forEach((c, k) => c.classList.toggle('on', k === this.index));
    this.root.style.setProperty('--c1', def.theme.primary);
    this.root.style.setProperty('--c2', def.theme.secondary);
    this.root.style.setProperty('--glow', def.theme.glow);
    this.root.style.setProperty('--dark', def.theme.dark);
    this.buildInfo(def);
    this.loadModel(def);
    this.previewSlot = -1;
  }

  private buildInfo(def: CharacterDefinition): void {
    const maxes = STAT_ROWS.map((row) => Math.max(...CHARACTERS.map((c) => row.get(c.stats))));
    const mins = STAT_ROWS.map((row) => Math.min(...CHARACTERS.map((c) => row.get(c.stats))));
    const diff = '<i class="on"></i>'.repeat(def.difficulty) + '<i></i>'.repeat(3 - def.difficulty);
    const stats = STAT_ROWS.map((row, k) => {
      const v = row.get(def.stats);
      const f = 0.18 + 0.82 * ((v - mins[k] * 0.6) / Math.max(1e-6, maxes[k] - mins[k] * 0.6));
      return `<div class="stat"><span>${row.label}</span><b>${row.fmt(v)}</b><div class="stat-bar"><div style="width:${Math.min(100, f * 100).toFixed(0)}%"></div></div></div>`;
    }).join('');
    const abil = def.abilities
      .map((ab, k) => `<button class="ab${ab.ultimate ? ' ult' : ''}" data-slot="${k}"><img src="${iconDataURL(ab.icon)}" alt=""><kbd>${keyLabel(this.settings.bindings[ABILITY_ACTIONS[k]][0])}</kbd><span>${ab.name}</span></button>`)
      .join('');
    this.info.innerHTML = `
      <div class="info-head">
        <div class="info-name">${def.name}</div>
        <div class="info-title">${def.title}</div>
        <div class="tags"><span>${def.role}</span><span>${def.element}</span><span class="diff">Difficulty ${diff}</span></div>
      </div>
      <p class="desc">${def.description}</p>
      <div class="playstyle"><b>How to play</b>${def.playstyle}</div>
      <div class="stats">${stats}</div>
      <div class="passive"><b>Passive — ${def.passive.name}</b>${def.passive.description}</div>
      <div class="abilities">${abil}</div>
      <div class="ab-detail"></div>`;
    const detail = this.info.querySelector('.ab-detail') as HTMLElement;
    const showDetail = (k: number) => {
      const ab = def.abilities[k];
      const cd = ab.ultimate ? 'Ultimate meter' : `${(ab.cooldown * def.stats.cooldownMultiplier).toFixed(1)}s cooldown${ab.charges ? ` · ${ab.charges} charges` : ''}`;
      const dmg = ab.damage ? ` · ${Math.round(ab.damage * def.stats.abilityPower)} dmg` : '';
      detail.innerHTML = `<div class="abd-head"><img src="${iconDataURL(ab.icon)}" alt=""><div><b>${ab.name}</b><small>${keyLabel(this.settings.bindings[ABILITY_ACTIONS[k]][0])} · ${cd}${dmg}</small></div></div><p>${ab.description}</p><div class="abd-tags">${ab.tags.map((t) => `<span>${t}</span>`).join('')}</div>`;
      this.info.querySelectorAll('.ab').forEach((b, j) => b.classList.toggle('on', j === k));
    };
    this.info.querySelectorAll<HTMLButtonElement>('.ab').forEach((b) => {
      const k = Number(b.dataset.slot);
      b.onmouseenter = () => showDetail(k);
      b.onclick = () => {
        this.audio.unlock();
        this.audio.play('ui_click');
        showDetail(k);
        this.previewAbility(k);
      };
    });
    showDetail(0);
  }

  private loadModel(def: CharacterDefinition): void {
    if (this.model) {
      this.scene.remove(this.model.holder);
      this.model.holder.traverse((o) => {
        const m = o as THREE.Mesh;
        if (m.isMesh) (Array.isArray(m.material) ? m.material : [m.material]).forEach((x) => x.dispose());
      });
    }
    const rig = def.buildModel();
    const holder = new THREE.Group();
    holder.add(rig.root);
    holder.scale.setScalar(def.stats.scale);
    holder.position.y = 0.3;
    rig.root.traverse((o) => ((o as THREE.Mesh).isMesh ? ((o as THREE.Mesh).castShadow = true) : null));
    this.scene.add(holder);
    const anim = new AnimationController(rig, def.animations);
    anim.play('idle', { fade: 0 });
    this.model = { holder, rig, anim, def };
    this.vfx.clear();
    const c1 = new THREE.Color(def.theme.primary);
    this.ringMat.color.copy(c1);
    this.rim.color.set(def.theme.glow);
    this.fill.color.set(def.theme.glow);
    // Dark fighters get more fill light so their silhouette reads.
    this.hemi.intensity = def.element === 'shadow' ? 1.8 : 0.7;
    this.fill.intensity = def.element === 'shadow' ? 10 : 4;
    this.rim.intensity = def.element === 'shadow' ? 4 : 2.2;
    (this.backMat.uniforms.c1.value as THREE.Color).set(def.theme.dark).lerp(c1, def.element === 'shadow' ? 0.5 : 0.25);
    // Entrance flourish.
    this.burst(def, 1.2);
    this.idleTime = 0;
  }

  previewAbility(slot: number): void {
    const m = this.model;
    if (!m) return;
    const ab = m.def.abilities[slot];
    const dur = Math.max(0.6, m.anim.clipDuration(ab.anim) || 0.8);
    m.anim.play(ab.anim, { restart: true, fade: 0.08 });
    this.previewTimer = dur + 0.25;
    this.previewSlot = slot;
    this.idleTime = 0;
    setTimeout(() => this.burst(m.def, ab.ultimate ? 2 : 1), dur * 450);
    const snd: Record<string, string> = { fire: 'fire_burst', lightning: 'zap_heavy', earth: 'stone_heavy', shadow: 'shadow_blink' };
    setTimeout(() => this.audio.play(snd[m.def.element] ?? 'whoosh', null, { volume: 0.5 }), dur * 450);
  }

  private burst(def: CharacterDefinition, scale: number): void {
    const p = new THREE.Vector3(0, 1.1 * def.stats.scale, 0);
    const v = this.vfx;
    switch (def.element) {
      case 'fire':
        FireFX.burst(v, p, 1.5 * scale);
        v.ring(new THREE.Vector3(0, 0.3, 0), 0xff7a20, 3 * scale, 0.5);
        break;
      case 'lightning':
        LightningFX.arcBurst(v, p, 2 * scale, 6);
        v.ring(new THREE.Vector3(0, 0.3, 0), 0x6fc8ff, 3 * scale, 0.4);
        break;
      case 'earth':
        EarthFX.dust(v, new THREE.Vector3(0, 0.3, 0), 2 * scale, 14);
        v.spawnDebris(new THREE.Vector3(0, 0.5, 0), Math.round(6 * scale), 0x7d7064, { force: 4, size: 0.2 });
        break;
      default:
        ShadowFX.puff(v, p, 1.5 * scale);
    }
  }

  private ambient(def: CharacterDefinition, dt: number): void {
    const v = this.vfx;
    const r = 1.4;
    const a = Math.random() * TAU;
    const p = new THREE.Vector3(Math.cos(a) * r, 0.35, Math.sin(a) * r);
    switch (def.element) {
      case 'fire':
        if (Math.random() < dt * 30) FireFX.embers(v, p, 1, 0.2);
        if (Math.random() < dt * 4) FireFX.trailPuff(v, p);
        break;
      case 'lightning':
        if (Math.random() < dt * 14) v.emit('spark', p, 1, { speed: [0.5, 2], dir: new THREE.Vector3(0, 1, 0), spread: 0.5, life: 0.5, size: 0.18, color: LightningFX.colors, gravity: -1 });
        if (Math.random() < dt * 1.5) {
          const q = new THREE.Vector3(rand(-1, 1), rand(0.5, 2.5), rand(-1, 1)).multiplyScalar(def.stats.scale);
          v.bolt(q, q.clone().add(new THREE.Vector3(rand(-0.8, 0.8), rand(-0.8, 0.8), rand(-0.8, 0.8))), 0x6fc8ff, { width: 0.04, jag: 0.4, dur: 0.12, branches: 0 });
        }
        break;
      case 'earth':
        if (Math.random() < dt * 8) v.emit('dust', p, 1, { speed: [0.2, 0.6], dir: new THREE.Vector3(0, 1, 0), spread: 0.4, life: 1.6, size: 0.8, sizeEnd: 1.8, color: 0x9c8a70, alpha: 0.35, gravity: -0.2 });
        if (Math.random() < dt * 6) v.emit('spark', p, 1, { speed: [0.2, 0.6], dir: new THREE.Vector3(0, 1, 0), spread: 0.3, life: 1.2, size: 0.1, color: 0xffa040, gravity: -0.6 });
        break;
      default:
        if (Math.random() < dt * 16) ShadowFX.wisp(v, p, 1);
    }
  }

  private onDown = (e: PointerEvent) => {
    if (!this.visible) return;
    this.dragging = true;
    this.lastX = e.clientX;
    this.audio.unlock();
  };
  private onUp = () => {
    this.dragging = false;
  };
  private onMove = (e: PointerEvent) => {
    if (!this.visible || !this.dragging) return;
    const dx = e.clientX - this.lastX;
    this.lastX = e.clientX;
    this.yawVel = dx * 0.012;
    this.yaw += dx * 0.012;
    this.idleTime = 0;
  };
  private onKey = (e: KeyboardEvent) => {
    if (!this.visible) return;
    if (e.code === 'ArrowRight' || e.code === 'KeyD') this.select(this.index + 1);
    else if (e.code === 'ArrowLeft' || e.code === 'KeyA') this.select(this.index - 1);
    else if (e.code === 'Enter' || e.code === 'NumpadEnter') this.start();
    else if (e.code.startsWith('Digit')) {
      const n = Number(e.code.slice(5)) - 1;
      if (n >= 0 && n < CHARACTERS.length) this.select(n);
    }
  };

  resize(w: number, h: number): void {
    this.camera.aspect = w / h;
    // Shift the projection so the fighter stands between the two panels.
    const shift = w > 900 ? 0.09 : 0;
    this.camera.setViewOffset(w, h, w * shift, 0, w, h);
    this.camera.updateProjectionMatrix();
  }

  update(dt: number): void {
    this.time += dt;
    const m = this.model;
    if (m) {
      if (!this.dragging) {
        this.yaw += this.yawVel;
        this.yawVel *= Math.pow(0.02, dt);
        this.idleTime += dt;
        if (this.idleTime > 2.5) this.yaw += dt * 0.25;
      }
      m.holder.rotation.y = this.yaw;
      if (this.previewTimer > 0) {
        this.previewTimer -= dt;
        if (this.previewTimer <= 0) m.anim.play('idle', { fade: 0.3 });
      }
      m.anim.update(dt);
      this.ambient(m.def, dt);
      const h = m.rig.height * m.def.stats.scale;
      const dist = 3.6 + h * 1.65;
      const look = new THREE.Vector3(0, 0.3 + h * 0.47, 0);
      this.camera.position.lerp(new THREE.Vector3(0, look.y + h * 0.12, dist), Math.min(1, dt * 4));
      this.camera.lookAt(look);
    }
    this.ring.rotation.z += dt * 0.2;
    this.vfx.update(dt, this.canvas.clientHeight || window.innerHeight);
  }
}
