import * as THREE from 'three';

export interface ParticleParams {
  x: number;
  y: number;
  z: number;
  vx: number;
  vy: number;
  vz: number;
  life: number;
  size0: number;
  size1: number;
  r0: number;
  g0: number;
  b0: number;
  a0: number;
  r1: number;
  g1: number;
  b1: number;
  a1: number;
  drag: number;
  gravity: number;
}

const vertexShader = /* glsl */ `
  attribute float size;
  attribute vec4 pcolor;
  uniform float uScale;
  varying vec4 vColor;
  #include <fog_pars_vertex>
  void main() {
    vColor = pcolor;
    vec4 mvPosition = modelViewMatrix * vec4(position, 1.0);
    gl_PointSize = size * uScale / max(0.1, -mvPosition.z);
    gl_Position = projectionMatrix * mvPosition;
    #include <fog_vertex>
  }
`;

const fragmentShader = /* glsl */ `
  uniform sampler2D map;
  varying vec4 vColor;
  #include <fog_pars_fragment>
  void main() {
    vec4 t = texture2D(map, gl_PointCoord);
    gl_FragColor = vec4(vColor.rgb * t.rgb, vColor.a * t.a);
    if (gl_FragColor.a < 0.004) discard;
    #include <fog_fragment>
  }
`;

/**
 * A pool of CPU-simulated point sprites rendered in one draw call.
 * Several layers exist (additive glow, sparks, smoke, dark smoke).
 */
export class ParticleLayer {
  readonly points: THREE.Points;
  private readonly geo: THREE.BufferGeometry;
  private readonly pos: Float32Array;
  private readonly col: Float32Array;
  private readonly size: Float32Array;
  private readonly vel: Float32Array;
  private readonly life: Float32Array;
  private readonly maxLife: Float32Array;
  private readonly s0: Float32Array;
  private readonly s1: Float32Array;
  private readonly c0: Float32Array;
  private readonly c1: Float32Array;
  private readonly phys: Float32Array;
  count = 0;
  readonly material: THREE.ShaderMaterial;

  constructor(public readonly max: number, texture: THREE.Texture, blending: THREE.Blending) {
    this.pos = new Float32Array(max * 3);
    this.col = new Float32Array(max * 4);
    this.size = new Float32Array(max);
    this.vel = new Float32Array(max * 3);
    this.life = new Float32Array(max);
    this.maxLife = new Float32Array(max);
    this.s0 = new Float32Array(max);
    this.s1 = new Float32Array(max);
    this.c0 = new Float32Array(max * 4);
    this.c1 = new Float32Array(max * 4);
    this.phys = new Float32Array(max * 2);
    this.geo = new THREE.BufferGeometry();
    this.geo.setAttribute('position', new THREE.BufferAttribute(this.pos, 3).setUsage(THREE.DynamicDrawUsage));
    this.geo.setAttribute('pcolor', new THREE.BufferAttribute(this.col, 4).setUsage(THREE.DynamicDrawUsage));
    this.geo.setAttribute('size', new THREE.BufferAttribute(this.size, 1).setUsage(THREE.DynamicDrawUsage));
    this.geo.setDrawRange(0, 0);
    this.material = new THREE.ShaderMaterial({
      uniforms: THREE.UniformsUtils.merge([THREE.UniformsLib.fog, { map: { value: texture }, uScale: { value: 400 } }]),
      vertexShader,
      fragmentShader,
      blending,
      transparent: true,
      depthWrite: false,
      fog: true,
    });
    this.material.uniforms.map.value = texture;
    this.points = new THREE.Points(this.geo, this.material);
    this.points.frustumCulled = false;
    this.points.renderOrder = blending === THREE.AdditiveBlending ? 5 : 4;
  }

  spawn(p: ParticleParams): void {
    let i: number;
    if (this.count < this.max) i = this.count++;
    else i = Math.floor(Math.random() * this.max); // recycle when saturated
    const i3 = i * 3;
    const i4 = i * 4;
    this.pos[i3] = p.x;
    this.pos[i3 + 1] = p.y;
    this.pos[i3 + 2] = p.z;
    this.vel[i3] = p.vx;
    this.vel[i3 + 1] = p.vy;
    this.vel[i3 + 2] = p.vz;
    this.life[i] = 0;
    this.maxLife[i] = Math.max(0.01, p.life);
    this.s0[i] = p.size0;
    this.s1[i] = p.size1;
    this.c0[i4] = p.r0;
    this.c0[i4 + 1] = p.g0;
    this.c0[i4 + 2] = p.b0;
    this.c0[i4 + 3] = p.a0;
    this.c1[i4] = p.r1;
    this.c1[i4 + 1] = p.g1;
    this.c1[i4 + 2] = p.b1;
    this.c1[i4 + 3] = p.a1;
    this.phys[i * 2] = p.drag;
    this.phys[i * 2 + 1] = p.gravity;
  }

  private kill(i: number): void {
    const last = --this.count;
    if (i === last) return;
    const copy = (arr: Float32Array, n: number) => {
      for (let k = 0; k < n; k++) arr[i * n + k] = arr[last * n + k];
    };
    copy(this.pos, 3);
    copy(this.vel, 3);
    copy(this.col, 4);
    copy(this.c0, 4);
    copy(this.c1, 4);
    copy(this.phys, 2);
    this.life[i] = this.life[last];
    this.maxLife[i] = this.maxLife[last];
    this.s0[i] = this.s0[last];
    this.s1[i] = this.s1[last];
    this.size[i] = this.size[last];
  }

  update(dt: number, scale: number): void {
    this.material.uniforms.uScale.value = scale;
    for (let i = this.count - 1; i >= 0; i--) {
      this.life[i] += dt;
      const t = this.life[i] / this.maxLife[i];
      if (t >= 1) {
        this.kill(i);
        continue;
      }
      const i3 = i * 3;
      const i4 = i * 4;
      const drag = Math.max(0, 1 - this.phys[i * 2] * dt);
      this.vel[i3] *= drag;
      this.vel[i3 + 1] = this.vel[i3 + 1] * drag - this.phys[i * 2 + 1] * dt;
      this.vel[i3 + 2] *= drag;
      this.pos[i3] += this.vel[i3] * dt;
      this.pos[i3 + 1] += this.vel[i3 + 1] * dt;
      this.pos[i3 + 2] += this.vel[i3 + 2] * dt;
      this.size[i] = this.s0[i] + (this.s1[i] - this.s0[i]) * t;
      // Fade in quickly, then interpolate to end colour.
      const fin = Math.min(1, t * 12);
      this.col[i4] = this.c0[i4] + (this.c1[i4] - this.c0[i4]) * t;
      this.col[i4 + 1] = this.c0[i4 + 1] + (this.c1[i4 + 1] - this.c0[i4 + 1]) * t;
      this.col[i4 + 2] = this.c0[i4 + 2] + (this.c1[i4 + 2] - this.c0[i4 + 2]) * t;
      this.col[i4 + 3] = (this.c0[i4 + 3] + (this.c1[i4 + 3] - this.c0[i4 + 3]) * t) * fin;
    }
    this.geo.setDrawRange(0, this.count);
    (this.geo.attributes.position as THREE.BufferAttribute).needsUpdate = true;
    (this.geo.attributes.pcolor as THREE.BufferAttribute).needsUpdate = true;
    (this.geo.attributes.size as THREE.BufferAttribute).needsUpdate = true;
  }

  clear(): void {
    this.count = 0;
    this.geo.setDrawRange(0, 0);
  }
}
