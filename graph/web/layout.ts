// The force layout, in a worker so a large vault doesn't stall the page.
// The page sends the graph, the filters and drags; the worker sends back
// every node's position. It steps on its own clock, at most 60 times a
// second, so a slow screen doesn't slow the layout down, and sends the latest
// positions whenever the page has drawn the last ones. It rests once the
// layout settles.

import { forceLink, forceManyBody, forceSimulation, forceX, forceY, forceZ, type SimNode } from "d3-force-3d";

export type ToLayout =
  | { type: "graph"; ids: string[]; links: [number, number][]; dims: 2 | 3 }
  | { type: "visible"; mask: Uint8Array }
  | { type: "dims"; dims: 2 | 3 }
  | { type: "drag"; index: number; x: number; y: number; z: number }
  | { type: "release"; index: number }
  | { type: "frame" };

export type FromLayout = { type: "positions"; positions: Float32Array; moving: boolean };

interface Node extends SimNode {
  id: string;
}

const scope = self as unknown as {
  postMessage(message: FromLayout, transfer: Transferable[]): void;
  onmessage: ((event: MessageEvent<ToLayout>) => void) | null;
};

let all: Node[] = [];
let links: [number, number][] = [];
let visible: Uint8Array = new Uint8Array(0);
let dims: 2 | 3 = 2;
let dragging = false;
// Whether the page is waiting for positions (it asks again after drawing),
// and whether it has the latest.
let waiting = true;
let fresh = false;
let timer: ReturnType<typeof setTimeout> | undefined;

const sim = forceSimulation<Node>([], 2).stop();
sim.velocityDecay(0.45);

scope.onmessage = ({ data }) => {
  switch (data.type) {
    case "graph":
      setGraph(data.ids, data.links, data.dims);
      break;
    case "visible":
      visible = data.mask;
      rebuild();
      heat(0.3);
      break;
    case "dims":
      setDims(data.dims);
      heat(0.6);
      break;
    case "drag": {
      const node = all[data.index];
      if (!node) break;
      node.fx = data.x;
      node.fy = data.y;
      node.fz = dims === 3 ? data.z : null;
      dragging = true;
      sim.alphaTarget(0.25);
      break;
    }
    case "release": {
      const node = all[data.index];
      if (node) node.fx = node.fy = node.fz = null;
      dragging = false;
      sim.alphaTarget(0);
      break;
    }
    case "frame":
      waiting = true;
      break;
  }
  if (data.type !== "frame") {
    fresh = true;
    run();
  }
  if (waiting) send();
};

function setGraph(ids: string[], next: [number, number][], d: 2 | 3) {
  const before = new Map(all.map((n) => [n.id, n]));
  const fresh = before.size === 0;
  all = ids.map((id) => before.get(id) ?? { id });
  links = next;
  if (visible.length !== all.length) visible = new Uint8Array(all.length).fill(1);

  // A new note starts beside a note it links to, so a vault that grows
  // while open doesn't fly apart.
  if (!fresh) {
    for (const [a, b] of links) {
      for (const [node, other] of [[all[a], all[b]], [all[b], all[a]]]) {
        if (node.x === undefined && other.x !== undefined) {
          node.x = other.x + (Math.random() - 0.5) * 20;
          node.y = (other.y ?? 0) + (Math.random() - 0.5) * 20;
          node.z = (other.z ?? 0) + (d === 3 ? (Math.random() - 0.5) * 20 : 0);
        }
      }
    }
  }

  setDims(d);
  heat(fresh ? 1 : 0.3);
}

function setDims(d: 2 | 3) {
  // Keep x and y when switching: give z a little spread to unfold into,
  // or flatten it.
  for (const node of all) {
    if (node.x === undefined) continue;
    node.z = d === 3 ? (node.z || (Math.random() - 0.5) * 60) : 0;
    node.vz = 0;
  }
  dims = d;
  sim.numDimensions(d);
  rebuild();
}

function rebuild() {
  const active = all.filter((_, i) => visible[i]);
  const at = new Map(active.map((node, i) => [node, i]));
  const shown = links
    .filter(([a, b]) => visible[a] && visible[b])
    .map(([a, b]) => ({ source: at.get(all[a])!, target: at.get(all[b])! }));

  sim.nodes(active);
  sim.force("link", forceLink<Node, { source: number; target: number }>(shown).distance(36));
  // A coarser approximation for big vaults keeps a step near 15 ms (2D) and
  // 25 ms (3D) at 5,000 notes.
  const theta = active.length > 1000 ? (dims === 3 ? 1.5 : 1.2) : 0.9;
  sim.force("charge", forceManyBody<Node>().strength(-70).theta(theta).distanceMax(1200));
  // A gentle pull to the middle keeps unlinked notes and separate sites in
  // view, as Obsidian's centre force does.
  sim.force("x", forceX<Node>(0).strength(0.04));
  sim.force("y", forceY<Node>(0).strength(0.04));
  sim.force("z", dims === 3 ? forceZ<Node>(0).strength(0.04) : null);
}

function heat(alpha: number) {
  sim.alpha(Math.max(sim.alpha(), alpha));
}

const moving = () => dragging || sim.alpha() >= sim.alphaMin();

function run() {
  if (timer !== undefined || !moving()) return;
  const loop = () => {
    const start = performance.now();
    sim.tick();
    fresh = true;
    if (waiting) send();
    timer = moving() ? setTimeout(loop, Math.max(0, 16 - (performance.now() - start))) : undefined;
  };
  timer = setTimeout(loop, 0);
}

function send() {
  if (!fresh) return;
  const positions = new Float32Array(all.length * 3);
  for (const [i, node] of all.entries()) {
    positions[i * 3] = node.x ?? 0;
    positions[i * 3 + 1] = node.y ?? 0;
    positions[i * 3 + 2] = dims === 3 ? (node.z ?? 0) : 0;
  }
  waiting = fresh = false;
  scope.postMessage({ type: "positions", positions, moving: moving() }, [positions.buffer]);
}
