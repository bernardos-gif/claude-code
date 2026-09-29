import * as THREE from 'three';
import type { CharacterDefinition } from '../data/types';
import { AnimationController } from '../characters/AnimationController';

/**
 * Renders real 3D head-and-shoulders portraits of each fighter (used by the
 * selection roster and HUD) into data URLs via an offscreen render target.
 */
export class PortraitRenderer {
  private scene = new THREE.Scene();
  private camera = new THREE.PerspectiveCamera(24, 1, 0.05, 50);
  private cache = new Map<string, string>();

  constructor(private renderer: THREE.WebGLRenderer) {
    this.scene.add(new THREE.HemisphereLight(0xffffff, 0x303040, 1.4));
    const key = new THREE.DirectionalLight(0xffffff, 2.4);
    key.position.set(1.5, 2, 3);
    this.scene.add(key);
    const rim = new THREE.DirectionalLight(0xffffff, 2.2);
    rim.position.set(-2, 1.5, -2);
    rim.name = 'rim';
    this.scene.add(rim);
  }

  render(def: CharacterDefinition, size = 256): string {
    const cached = this.cache.get(def.id);
    if (cached) return cached;
    const rig = def.buildModel();
    const holder = new THREE.Group();
    holder.add(rig.root);
    holder.scale.setScalar(def.stats.scale);
    this.scene.add(holder);
    const anim = new AnimationController(rig, def.animations);
    anim.play('idle', { fade: 0 });
    anim.update(0.3);
    holder.updateMatrixWorld(true);
    (this.scene.getObjectByName('rim') as THREE.DirectionalLight).color.set(def.theme.glow);

    const head = rig.bones.head.getWorldPosition(new THREE.Vector3());
    const h = rig.height * def.stats.scale;
    const target = head.clone().add(new THREE.Vector3(0, 0.04 * h, 0));
    this.camera.position.set(target.x + 0.35 * h, target.y + 0.05 * h, target.z + 1.15 * h);
    this.camera.lookAt(target.x, target.y - 0.1 * h, target.z);
    this.camera.updateProjectionMatrix();

    const rt = new THREE.WebGLRenderTarget(size, size, { samples: 4 });
    rt.texture.colorSpace = THREE.SRGBColorSpace;
    const prevTarget = this.renderer.getRenderTarget();
    const prevClear = this.renderer.getClearColor(new THREE.Color());
    const prevAlpha = this.renderer.getClearAlpha();
    this.renderer.setRenderTarget(rt);
    this.renderer.setClearColor(0x000000, 0);
    this.renderer.clear();
    this.renderer.render(this.scene, this.camera);
    const px = new Uint8Array(size * size * 4);
    this.renderer.readRenderTargetPixels(rt, 0, 0, size, size, px);
    this.renderer.setRenderTarget(prevTarget);
    this.renderer.setClearColor(prevClear, prevAlpha);
    rt.dispose();

    const cv = document.createElement('canvas');
    cv.width = cv.height = size;
    const ctx = cv.getContext('2d')!;
    const img = ctx.createImageData(size, size);
    for (let y = 0; y < size; y++) {
      const src = (size - 1 - y) * size * 4;
      img.data.set(px.subarray(src, src + size * 4), y * size * 4);
    }
    ctx.putImageData(img, 0, 0);
    const url = cv.toDataURL('image/png');
    this.cache.set(def.id, url);
    this.scene.remove(holder);
    rig.root.traverse((o) => {
      const m = o as THREE.Mesh;
      if (m.isMesh) (Array.isArray(m.material) ? m.material : [m.material]).forEach((x) => x.dispose());
    });
    return url;
  }
}
