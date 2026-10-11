// A graph of notes drawn with Three.js: every note a dot, every link a line,
// laid out by forces in a worker (layout.ts). The home page's global graph
// and each note's local graph are both one of these.
//
// Dots are one instanced mesh and lines one set of segments, so a vault of
// thousands of notes is two draw calls. Labels are drawn as text on a 2D
// canvas over the top, fading in as you zoom. It draws only when something
// moved.

import {
  BufferAttribute,
  BufferGeometry,
  Color,
  InstancedBufferAttribute,
  InstancedBufferGeometry,
  LinearSRGBColorSpace,
  LineBasicMaterial,
  LineSegments,
  Mesh,
  MOUSE,
  OrthographicCamera,
  PerspectiveCamera,
  Plane,
  PlaneGeometry,
  Raycaster,
  Scene,
  ShaderMaterial,
  TOUCH,
  Vector2,
  Vector3,
  WebGLRenderer,
} from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import type { ViewNode } from "../src/graph.ts";
import type { FromLayout, ToLayout } from "./layout.ts";

export type Dims = 2 | 3;

export interface GraphOptions {
  /** A short description for screen readers. */
  label: string;
  /** The CSS colour the graph is drawn on. */
  background: string;
  open(id: string): void;
  /** Told when the layout starts and stops moving. */
  status?(moving: boolean): void;
}

type RGB = [number, number, number];

interface Palette {
  bg: RGB;
  text: RGB;
  line: RGB;
  accent: RGB;
  blocked: RGB;
  kinds: Record<string, RGB>;
  trust: Record<string, RGB | null>;
}

const NODE_VERTEX = /* glsl */ `
  attribute vec3 aCenter;
  attribute float aRadius;
  attribute vec3 aFill;
  attribute vec3 aRing;
  attribute float aRingOn;
  attribute float aAlpha;
  varying vec2 vUv;
  varying vec3 vFill;
  varying vec3 vRing;
  varying float vRingOn;
  varying float vAlpha;
  void main() {
    vec4 mv = modelViewMatrix * vec4(aCenter, 1.0);
    mv.xy += position.xy * 2.0 * aRadius;
    gl_Position = projectionMatrix * mv;
    vUv = position.xy * 2.0;
    vFill = aFill;
    vRing = aRing;
    vRingOn = aRingOn;
    vAlpha = aAlpha;
  }
`;

const NODE_FRAGMENT = /* glsl */ `
  uniform vec3 uBg;
  varying vec2 vUv;
  varying vec3 vFill;
  varying vec3 vRing;
  varying float vRingOn;
  varying float vAlpha;
  void main() {
    float d = length(vUv);
    float aa = max(fwidth(d), 0.001);
    float edge = 1.0 - smoothstep(1.0 - aa, 1.0, d);
    if (edge * vAlpha < 0.01) discard;
    vec3 colour = vFill;
    if (vRingOn > 0.5) {
      // Fill, a gap of background, then the ring.
      float gap = smoothstep(0.62 - aa, 0.62, d);
      float ring = smoothstep(0.76 - aa, 0.76, d);
      colour = mix(mix(vFill, uBg, gap), vRing, ring);
    }
    gl_FragColor = vec4(mix(uBg, colour, vAlpha), edge);
  }
`;

// How long a note tiny-axe just wrote glows.
const GLOW_MS = 2500;

// The same notes, in the same order, with the same links.
function same(a: ViewNode[], b: ViewNode[], aLinks: [number, number][], bLinks: [number, number][]) {
  if (a.length === 0 || a.length !== b.length || aLinks.length !== bLinks.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i].id !== b[i].id) return false;
  for (let k = 0; k < aLinks.length; k++) {
    if (aLinks[k][0] !== bLinks[k][0] || aLinks[k][1] !== bLinks[k][1]) return false;
  }
  return true;
}

function sameMask(a: Uint8Array, b: Uint8Array) {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

const reducedMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
const ease = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);
const smoothstep = (a: number, b: number, x: number) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};

export class GraphView {
  readonly element: HTMLElement;

  private options: GraphOptions;
  private renderer: WebGLRenderer;
  private labels: HTMLCanvasElement;
  private context: CanvasRenderingContext2D;
  private scene = new Scene();
  private ortho = new OrthographicCamera(-1, 1, 1, -1, -100000, 100000);
  private perspective = new PerspectiveCamera(50, 1, 1, 200000);
  private camera: OrthographicCamera | PerspectiveCamera = this.ortho;
  private controls: OrbitControls;
  private worker: Worker;
  private dims: Dims = 2;
  private palette!: Palette;
  private font = "12px sans-serif";

  private nodes: ViewNode[] = [];
  private links: [number, number][] = [];
  private neighbours: number[][] = [];
  private radius = new Float32Array(0);
  private positions: Float32Array = new Float32Array(0);
  private visible: Uint8Array = new Uint8Array(0);
  /** Each node on screen: x, y in CSS pixels and its radius in pixels (0 if off screen). */
  private screen = new Float32Array(0);

  private dots: Mesh<InstancedBufferGeometry, ShaderMaterial>;
  private lines: LineSegments<BufferGeometry, LineBasicMaterial>;

  private hovered = -1;
  private selected = -1;
  /** A note the camera stays on while the layout moves (after focus). */
  private following = -1;
  private width = 1;
  private height = 1;
  private dirty = true;
  private styleDirty = true;
  // Notes tiny-axe just wrote, by id: when they started to glow.
  private glows = new Map<string, number>();
  // The filter mask the layout was last sent.
  private sentMask: Uint8Array | null = null;
  private looping = false;
  private placed = false;
  private moving = false;
  private ack = false;
  /** Until the user moves the camera, keep everything in view as it lays out. */
  private autofit = true;
  private flight: { start: number; duration: number; from: View; to: () => View } | null = null;
  private drag: { index: number; x: number; y: number; moved: boolean; plane: Plane } | null = null;
  private pointer: { x: number; y: number } | null = null;
  private resize: ResizeObserver;

  constructor(options: GraphOptions) {
    this.options = options;
    this.element = document.createElement("div");
    this.element.className = "graph-canvas";

    this.renderer = new WebGLRenderer({ antialias: true });
    this.renderer.outputColorSpace = LinearSRGBColorSpace;
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
    const canvas = this.renderer.domElement;
    canvas.setAttribute("role", "img");
    canvas.setAttribute("aria-label", options.label);
    this.labels = document.createElement("canvas");
    this.labels.className = "graph-labels";
    this.labels.setAttribute("aria-hidden", "true");
    this.context = this.labels.getContext("2d")!;
    this.element.append(canvas, this.labels);

    this.dots = new Mesh(new InstancedBufferGeometry(), new ShaderMaterial({
      vertexShader: NODE_VERTEX,
      fragmentShader: NODE_FRAGMENT,
      uniforms: { uBg: { value: new Vector3() } },
      transparent: true,
      depthTest: false,
      depthWrite: false,
    }));
    this.dots.frustumCulled = false;
    this.dots.renderOrder = 1;
    this.lines = new LineSegments(
      new BufferGeometry(),
      new LineBasicMaterial({ vertexColors: true, transparent: true, depthTest: false, depthWrite: false }),
    );
    this.lines.frustumCulled = false;
    this.scene.add(this.lines, this.dots);

    // Before the camera controls, so pressing on a dot drags it instead of
    // panning.
    canvas.addEventListener("pointerdown", (e) => this.down(e));
    canvas.addEventListener("pointermove", (e) => this.move(e));
    canvas.addEventListener("pointerup", (e) => this.up(e));
    canvas.addEventListener("pointercancel", (e) => this.up(e));
    canvas.addEventListener("pointerleave", () => {
      this.pointer = null;
      if (!this.drag) this.hover(-1);
    });
    canvas.addEventListener("dblclick", (e) => {
      if (this.pick(e) < 0) this.fit(true);
    });
    this.controls = this.makeControls();

    this.worker = new Worker("/static/layout.js", { type: "module" });
    this.worker.onmessage = ({ data }: MessageEvent<FromLayout>) => this.positioned(data);

    this.resize = new ResizeObserver(() => this.sized());
    this.resize.observe(this.element);
    this.recolour();
    // The sidebar's dark/light switch sets data-theme on the page.
    new MutationObserver(() => this.recolour()).observe(document.documentElement, { attributeFilter: ["data-theme"] });
  }

  /** The graph to draw. Notes already drawn keep their places. */
  setData(nodes: ViewNode[], links: [number, number][]) {
    const before = this.nodes;
    // Only counts changed (a running task's notes, again and again): resize,
    // and leave the layout be.
    if (same(before, nodes, this.links, links)) {
      this.nodes = nodes;
      this.sizes();
      this.restyle();
      return;
    }

    const keep = new Map<string, number>(before.map((n, i) => [n.id, i]));
    const hovered = this.hovered >= 0 ? before[this.hovered]?.id : undefined;
    const selected = this.selected >= 0 ? before[this.selected]?.id : undefined;

    const positions = new Float32Array(nodes.length * 3);
    for (const [i, node] of nodes.entries()) {
      const j = keep.get(node.id);
      if (j !== undefined) positions.set(this.positions.subarray(j * 3, j * 3 + 3), i * 3);
    }

    this.nodes = nodes;
    this.links = links;
    this.positions = positions;
    this.visible = new Uint8Array(nodes.length).fill(1);
    this.sentMask = null;
    this.screen = new Float32Array(nodes.length * 3);
    this.neighbours = nodes.map(() => []);
    for (const [a, b] of links) {
      this.neighbours[a].push(b);
      this.neighbours[b].push(a);
    }
    this.sizes();
    this.hovered = hovered ? this.indexOf(hovered) : -1;
    this.selected = selected ? this.indexOf(selected) : -1;
    this.following = -1;
    if (before.length === 0) this.placed = false;

    this.buffers();
    this.post({ type: "graph", ids: nodes.map((n) => n.id), links, dims: this.dims });
    this.element.dataset.nodes = String(nodes.length);
    this.element.dataset.links = String(links.length);
    this.restyle();
  }

  /** Which notes the filters leave showing (1 shown, 0 hidden). */
  setVisible(mask: Uint8Array) {
    // The same mask again (the vault changed, the filters didn't): the
    // layout already has it.
    if (this.sentMask && sameMask(this.sentMask, mask)) return;
    this.sentMask = mask.slice();
    this.visible = mask;
    if (this.hovered >= 0 && !mask[this.hovered]) this.hovered = -1;
    this.post({ type: "visible", mask: mask.slice() });
    this.element.dataset.shown = String(mask.reduce((a, b) => a + b, 0));
    this.restyle();
  }

  setDims(dims: Dims) {
    if (dims === this.dims) return;
    const target = this.controls.target.clone();
    this.dims = dims;
    this.camera = dims === 2 ? this.ortho : this.perspective;
    this.controls.dispose();
    this.controls = this.makeControls();
    this.controls.target.copy(target);
    this.flight = null;
    this.following = -1;
    this.autofit = true;
    this.sized();
    if (this.placed) this.apply(this.fitted());
    this.post({ type: "dims", dims });
    this.element.dataset.dims = String(dims);
  }

  /** Make notes glow for a moment: what tiny-axe just wrote. */
  glow(ids: string[]) {
    const now = performance.now();
    for (const id of ids) this.glows.set(id, now);
    this.restyle();
  }

  /** Ring a note in the accent colour (the open note, in a local graph). */
  setSelected(id: string | null) {
    this.selected = id === null ? -1 : this.indexOf(id);
    this.restyle();
  }

  /** Fly the camera to a note and keep it ringed. */
  focus(id: string) {
    const index = this.indexOf(id);
    if (index < 0) return;
    this.selected = this.following = index;
    this.autofit = false;
    this.restyle();
    this.fly(() => this.viewOf(index), 900);
  }

  /** Keep every shown note in view while the layout moves, until the user moves the camera. */
  autoFit() {
    this.autofit = true;
    this.following = -1;
    this.flight = null;
  }

  /** Bring every shown note into view. */
  fit(animate: boolean) {
    this.autofit = false;
    this.following = -1;
    if (animate) this.fly(() => this.fitted(), 600);
    else this.apply(this.fitted());
  }

  attach(parent: HTMLElement) {
    if (this.element.parentElement !== parent) parent.append(this.element);
    this.dirty = true;
    if (!this.looping) {
      this.looping = true;
      requestAnimationFrame(() => this.frame());
    }
  }

  // Drawing

  private frame() {
    if (!this.element.isConnected) {
      this.looping = false;
      return;
    }
    requestAnimationFrame(() => this.frame());

    if (this.flight) {
      const t = Math.min(1, (performance.now() - this.flight.start) / this.flight.duration);
      this.apply(lerp(this.flight.from, this.flight.to(), ease(t)));
      if (t >= 1) this.flight = null;
    } else if (this.placed && this.moving && this.following >= 0) {
      this.apply(lerp(this.current(), this.viewOf(this.following), 0.15));
    } else if (this.placed && this.moving && this.autofit) {
      this.apply(lerp(this.current(), this.fitted(), 0.12));
    }

    if (this.glows.size > 0) this.restyle();
    if (this.styleDirty) this.style();
    if (this.dirty) {
      this.renderer.render(this.scene, this.camera);
      this.project();
      this.drawLabels();
      this.dirty = false;
    }
    // Ask the layout for its next step only once this one is drawn.
    if (this.ack) {
      this.ack = false;
      this.post({ type: "frame" });
    }
  }

  private positioned({ positions, moving }: FromLayout) {
    if (positions.length !== this.positions.length) return; // from a graph since replaced
    this.positions = positions;
    const centres = this.dots.geometry.getAttribute("aCenter") as InstancedBufferAttribute;
    (centres.array as Float32Array).set(positions);
    centres.needsUpdate = true;

    const ends = this.lines.geometry.getAttribute("position") as BufferAttribute;
    const out = ends.array as Float32Array;
    for (const [k, [a, b]] of this.links.entries()) {
      out.set(positions.subarray(a * 3, a * 3 + 3), k * 6);
      out.set(positions.subarray(b * 3, b * 3 + 3), k * 6 + 3);
    }
    ends.needsUpdate = true;

    if (!this.placed) {
      this.placed = true;
      this.apply(this.following >= 0 ? this.viewOf(this.following) : this.fitted());
    }
    if (moving !== this.moving) {
      this.moving = moving;
      this.options.status?.(moving);
    }
    if (this.drag) this.dragTo();
    this.dirty = true;
    this.ack = true;
  }

  private buffers() {
    const n = this.nodes.length;
    const quad = new PlaneGeometry(1, 1);
    const geometry = new InstancedBufferGeometry();
    geometry.index = quad.index;
    geometry.setAttribute("position", quad.getAttribute("position"));
    geometry.setAttribute("aCenter", new InstancedBufferAttribute(this.positions.slice(), 3));
    geometry.setAttribute("aRadius", new InstancedBufferAttribute(new Float32Array(n), 1));
    geometry.setAttribute("aFill", new InstancedBufferAttribute(new Float32Array(n * 3), 3));
    geometry.setAttribute("aRing", new InstancedBufferAttribute(new Float32Array(n * 3), 3));
    geometry.setAttribute("aRingOn", new InstancedBufferAttribute(new Float32Array(n), 1));
    geometry.setAttribute("aAlpha", new InstancedBufferAttribute(new Float32Array(n), 1));
    geometry.instanceCount = n;
    this.dots.geometry.dispose();
    this.dots.geometry = geometry;

    const lines = new BufferGeometry();
    lines.setAttribute("position", new BufferAttribute(new Float32Array(this.links.length * 6), 3));
    lines.setAttribute("color", new BufferAttribute(new Float32Array(this.links.length * 8), 4));
    this.lines.geometry.dispose();
    this.lines.geometry = lines;
  }

  private restyle() {
    this.styleDirty = true;
    this.dirty = true;
  }

  // Colours, sizes and dimming: who's shown, hovered and selected.
  private style() {
    this.styleDirty = false;
    const p = this.palette;
    const g = this.dots.geometry;
    const radius = g.getAttribute("aRadius").array as Float32Array;
    const fill = g.getAttribute("aFill").array as Float32Array;
    const ring = g.getAttribute("aRing").array as Float32Array;
    const ringOn = g.getAttribute("aRingOn").array as Float32Array;
    const alpha = g.getAttribute("aAlpha").array as Float32Array;
    const lit = this.lit();
    const now = performance.now();
    const still = reducedMotion();
    for (const [id, start] of this.glows) if (now - start > GLOW_MS) this.glows.delete(id);

    for (const [i, node] of this.nodes.entries()) {
      const shown = this.visible[i] === 1;
      // A glow swells the note and rings it, then fades (no swelling when
      // motion is reduced).
      const since = this.glows.get(node.id);
      const glow = since === undefined ? 0 : 1 - (now - since) / GLOW_MS;
      const swell = still ? 1 : 1 + 0.6 * glow * glow;
      radius[i] = shown ? this.radius[i] * (i === this.hovered ? 1.25 : 1) * swell : 0;
      const blocked = node.kind === "path" && (node.gate === "refused" || node.gate === "denied");
      fill.set(blocked ? p.blocked : (p.kinds[node.kind] ?? p.kinds.task), i * 3);
      const trust = i === this.selected || glow > 0 ? p.accent : p.trust[node.trust] ?? null;
      ring.set(trust ?? p.bg, i * 3);
      ringOn[i] = trust ? 1 : 0;
      alpha[i] = !shown ? 0 : lit && !lit.has(i) ? 0.18 : 1;
    }
    for (const name of ["aRadius", "aFill", "aRing", "aRingOn", "aAlpha"]) g.getAttribute(name).needsUpdate = true;

    const colours = this.lines.geometry.getAttribute("color") as BufferAttribute;
    const c = colours.array as Float32Array;
    for (const [k, [a, b]] of this.links.entries()) {
      const shown = this.visible[a] === 1 && this.visible[b] === 1;
      const near = this.hovered >= 0 && (a === this.hovered || b === this.hovered);
      const [r, gr, bl] = near ? p.accent : p.line;
      const al = !shown ? 0 : near ? 0.9 : lit ? 0.06 : 0.45;
      c.set([r, gr, bl, al, r, gr, bl, al], k * 8);
    }
    colours.needsUpdate = true;
    (this.dots.material.uniforms.uBg.value as Vector3).set(...p.bg);
    // Colours here are the page's own sRGB values, drawn as they are.
    this.renderer.setClearColor(new Color().setRGB(...p.bg, LinearSRGBColorSpace), 1);
  }

  // Size by use: how often a note was seen, or how many links it has.
  private sizes() {
    this.radius = Float32Array.from(this.nodes, (n, i) =>
      Math.min(18, 3 + 2.2 * Math.log1p(n.seen ?? this.neighbours[i].length)),
    );
  }

  /** While hovering: the hovered note and its neighbours. */
  private lit(): Set<number> | null {
    if (this.hovered < 0) return null;
    return new Set([this.hovered, ...this.neighbours[this.hovered]]);
  }

  // Where each note is on screen, for labels and picking.
  private project() {
    const v = new Vector3();
    const halfW = this.width / 2;
    const halfH = this.height / 2;
    const perspective = this.camera instanceof PerspectiveCamera;
    const unit = perspective
      ? halfH / Math.tan(((this.perspective.fov / 2) * Math.PI) / 180)
      : this.ortho.zoom;
    const direction = this.camera.getWorldDirection(new Vector3());
    const eye = this.camera.position;
    const offset = new Vector3();

    for (let i = 0; i < this.nodes.length; i++) {
      const s = i * 3;
      if (!this.visible[i]) {
        this.screen[s + 2] = 0;
        continue;
      }
      v.fromArray(this.positions, s);
      let scale = unit;
      if (perspective) {
        const depth = offset.subVectors(v, eye).dot(direction);
        if (depth <= 1) {
          this.screen[s + 2] = 0;
          continue;
        }
        scale = unit / depth;
      }
      v.project(this.camera);
      this.screen[s] = (v.x + 1) * halfW;
      this.screen[s + 1] = (1 - v.y) * halfH;
      this.screen[s + 2] = this.radius[i] * scale;
    }
  }

  // Labels fade in as dots grow on screen; the hovered note and its
  // neighbours are always labelled. Bigger notes win when labels collide.
  private drawLabels() {
    const ctx = this.context;
    const ratio = this.renderer.getPixelRatio();
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.clearRect(0, 0, this.width, this.height);

    const lit = this.lit();
    // A small graph is labelled throughout.
    const few = this.visible.reduce((a, b) => a + b, 0) <= 40;
    const candidates: { i: number; alpha: number; rank: number }[] = [];
    for (let i = 0; i < this.nodes.length; i++) {
      const r = this.screen[i * 3 + 2];
      if (r <= 0) continue;
      const x = this.screen[i * 3];
      const y = this.screen[i * 3 + 1];
      if (x < -100 || x > this.width + 100 || y < -20 || y > this.height + 20) continue;
      const forced = i === this.selected || (lit?.has(i) ?? false);
      const alpha = forced ? 1 : (few ? 1 : smoothstep(5, 9, r)) * (lit ? 0.25 : 1);
      if (alpha > 0.02) candidates.push({ i, alpha, rank: (forced ? 1000 : 0) + r });
    }
    candidates.sort((a, b) => b.rank - a.rank);

    ctx.font = this.font;
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    const taken: [number, number, number, number][] = [];
    const [r, g, b] = this.palette.text.map((v) => Math.round(v * 255));
    for (const { i, alpha } of candidates.slice(0, 400)) {
      const text = short(this.nodes[i].title);
      const w = ctx.measureText(text).width;
      const x = this.screen[i * 3];
      const y = this.screen[i * 3 + 1] + this.screen[i * 3 + 2] + 4;
      const box: [number, number, number, number] = [x - w / 2 - 2, y - 1, x + w / 2 + 2, y + 15];
      if (taken.some((t) => box[0] < t[2] && box[2] > t[0] && box[1] < t[3] && box[3] > t[1])) continue;
      taken.push(box);
      ctx.fillStyle = `rgba(${r}, ${g}, ${b}, ${alpha})`;
      ctx.fillText(text, x, y);
    }
  }

  private sized() {
    const rect = this.element.getBoundingClientRect();
    this.width = Math.max(1, rect.width);
    this.height = Math.max(1, rect.height);
    this.renderer.setSize(this.width, this.height);
    const ratio = this.renderer.getPixelRatio();
    this.labels.width = Math.round(this.width * ratio);
    this.labels.height = Math.round(this.height * ratio);
    this.labels.style.width = `${this.width}px`;
    this.labels.style.height = `${this.height}px`;

    Object.assign(this.ortho, { left: -this.width / 2, right: this.width / 2, top: this.height / 2, bottom: -this.height / 2 });
    this.ortho.updateProjectionMatrix();
    this.perspective.aspect = this.width / this.height;
    this.perspective.updateProjectionMatrix();
    this.dirty = true;
  }

  private recolour() {
    const css = getComputedStyle(document.documentElement);
    const get = (name: string) => hexToRgb(css.getPropertyValue(name));
    this.palette = {
      bg: get(this.options.background),
      text: get("--text"),
      line: get("--faint"),
      accent: get("--accent"),
      blocked: get("--blocked"),
      kinds: Object.fromEntries(["site", "page", "control", "path", "tool", "task"].map((k) => [k, get(`--${k}`)])),
      trust: { observed: null, verified: get("--verified"), validated: get("--validated") },
    };
    this.font = `12px ${css.getPropertyValue("--sans")}`;
    this.restyle();
  }

  // The camera

  private makeControls() {
    const controls = new OrbitControls(this.camera, this.renderer.domElement);
    controls.zoomToCursor = true;
    controls.screenSpacePanning = true;
    controls.minZoom = 0.02;
    controls.maxZoom = 20;
    controls.minDistance = 5;
    controls.maxDistance = 100000;
    if (this.dims === 2) {
      controls.enableRotate = false;
      controls.mouseButtons = { LEFT: MOUSE.PAN, MIDDLE: MOUSE.DOLLY, RIGHT: MOUSE.PAN };
      controls.touches = { ONE: TOUCH.PAN, TWO: TOUCH.DOLLY_PAN };
    }
    controls.addEventListener("start", () => {
      this.autofit = false;
      this.following = -1;
      this.flight = null;
    });
    controls.addEventListener("change", () => (this.dirty = true));
    return controls;
  }

  private current(): View {
    return { target: this.controls.target.clone(), position: this.camera.position.clone(), zoom: this.ortho.zoom };
  }

  private apply(view: View) {
    this.controls.target.copy(view.target);
    this.camera.position.copy(view.position);
    if (this.camera === this.ortho) {
      this.ortho.zoom = view.zoom;
      this.ortho.updateProjectionMatrix();
    }
    this.camera.lookAt(view.target);
    this.controls.update();
    this.dirty = true;
  }

  // Before the first positions there's nowhere to fly from; the first
  // positions place the camera instead (see positioned).
  private fly(to: () => View, duration: number) {
    this.flight = null;
    if (!this.placed) return;
    if (reducedMotion()) this.apply(to());
    else this.flight = { start: performance.now(), duration, from: this.current(), to };
  }

  // A view with every shown note in it.
  private fitted(): View {
    const min = new Vector3(Infinity, Infinity, Infinity);
    const max = new Vector3(-Infinity, -Infinity, -Infinity);
    const v = new Vector3();
    let any = false;
    for (let i = 0; i < this.nodes.length; i++) {
      if (!this.visible[i]) continue;
      v.fromArray(this.positions, i * 3);
      min.min(v.clone().subScalar(this.radius[i]));
      max.max(v.clone().addScalar(this.radius[i]));
      any = true;
    }
    if (!any) return this.current();
    const centre = min.clone().add(max).multiplyScalar(0.5);
    const size = max.clone().sub(min);
    return this.viewAt(centre, Math.max(size.x, size.y, this.dims === 3 ? size.z : 0) / 2 + 30, size);
  }

  // Close in on one note, with room for its neighbours.
  private viewOf(index: number): View {
    const centre = new Vector3().fromArray(this.positions, index * 3);
    return this.viewAt(centre, 120);
  }

  private viewAt(centre: Vector3, reach: number, size?: Vector3): View {
    if (this.dims === 2) {
      const w = (size?.x ?? reach * 2) + 60;
      const h = (size?.y ?? reach * 2) + 60;
      const zoom = Math.min(8, Math.max(0.02, Math.min(this.width / w, this.height / h)));
      return { target: centre.clone(), position: new Vector3(centre.x, centre.y, 1000), zoom };
    }
    const fov = (this.perspective.fov * Math.PI) / 180;
    const fit = Math.min(fov, 2 * Math.atan(Math.tan(fov / 2) * this.perspective.aspect));
    const distance = reach / Math.sin(fit / 2);
    const away = this.camera.position.clone().sub(this.controls.target);
    if (away.lengthSq() < 1e-6) away.set(0, 0, 1);
    return { target: centre.clone(), position: centre.clone().add(away.normalize().multiplyScalar(distance)), zoom: 1 };
  }

  // The pointer: hover to light a note's neighbours, click to open it,
  // drag to move it.

  private pick(e: PointerEvent | MouseEvent): number {
    const rect = this.element.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    let best = -1;
    let bestDistance = Infinity;
    for (let i = 0; i < this.nodes.length; i++) {
      const r = this.screen[i * 3 + 2];
      if (r <= 0) continue;
      const d = Math.hypot(this.screen[i * 3] - x, this.screen[i * 3 + 1] - y);
      if (d <= Math.max(r, 6) + 2 && d < bestDistance) {
        best = i;
        bestDistance = d;
      }
    }
    return best;
  }

  private down(e: PointerEvent) {
    if (e.button !== 0) return;
    const index = this.pick(e);
    if (index < 0) return;
    this.controls.enabled = false;
    this.renderer.domElement.setPointerCapture(e.pointerId);
    const normal = this.camera.getWorldDirection(new Vector3());
    const at = new Vector3().fromArray(this.positions, index * 3);
    this.drag = { index, x: e.clientX, y: e.clientY, moved: false, plane: new Plane().setFromNormalAndCoplanarPoint(normal, at) };
    this.pointer = { x: e.clientX, y: e.clientY };
    this.hover(index);
  }

  private move(e: PointerEvent) {
    this.pointer = { x: e.clientX, y: e.clientY };
    if (this.drag) {
      if (!this.drag.moved && Math.hypot(e.clientX - this.drag.x, e.clientY - this.drag.y) > 4) {
        this.drag.moved = true;
        this.element.classList.add("dragging");
      }
      if (this.drag.moved) this.dragTo();
      return;
    }
    const index = this.pick(e);
    this.hover(index);
  }

  private dragTo() {
    if (!this.drag?.moved || !this.pointer) return;
    const rect = this.element.getBoundingClientRect();
    const ndc = new Vector2(
      ((this.pointer.x - rect.left) / this.width) * 2 - 1,
      -((this.pointer.y - rect.top) / this.height) * 2 + 1,
    );
    const ray = new Raycaster();
    ray.setFromCamera(ndc, this.camera);
    const hit = ray.ray.intersectPlane(this.drag.plane, new Vector3());
    if (hit) this.post({ type: "drag", index: this.drag.index, x: hit.x, y: hit.y, z: hit.z });
  }

  private up(e: PointerEvent) {
    const drag = this.drag;
    if (!drag) return;
    this.drag = null;
    this.controls.enabled = true;
    this.element.classList.remove("dragging");
    if (this.renderer.domElement.hasPointerCapture(e.pointerId)) this.renderer.domElement.releasePointerCapture(e.pointerId);
    if (drag.moved) this.post({ type: "release", index: drag.index });
    else if (e.type === "pointerup") this.options.open(this.nodes[drag.index].id);
  }

  private hover(index: number) {
    if (index === this.hovered) return;
    this.hovered = index;
    this.element.classList.toggle("over-node", index >= 0);
    this.element.title = index >= 0 ? this.nodes[index].title : "";
    this.restyle();
  }

  private indexOf(id: string) {
    return this.nodes.findIndex((n) => n.id === id);
  }

  private post(message: ToLayout) {
    this.worker.postMessage(message);
  }
}

interface View {
  target: Vector3;
  position: Vector3;
  zoom: number;
}

function lerp(a: View, b: View, t: number): View {
  return {
    target: a.target.clone().lerp(b.target, t),
    position: a.position.clone().lerp(b.position, t),
    zoom: a.zoom * (b.zoom / a.zoom) ** t,
  };
}

function short(title: string) {
  return title.length > 48 ? `${title.slice(0, 47)}…` : title;
}

function hexToRgb(value: string): RGB {
  const hex = value.trim().replace(/^#/, "");
  const full = hex.length === 3 ? [...hex].map((c) => c + c).join("") : hex.padEnd(6, "0");
  const n = Number.parseInt(full.slice(0, 6), 16) || 0;
  return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
}
