// What the graph shows: the filters on the home graph, and the notes near
// one note for its local graph. No DOM here, so the tests can run it.

import type { GraphData, ViewNode } from "../src/graph.ts";

export interface Filters {
  /** Kinds, trust levels and policy classes to leave out. */
  hideKinds: string[];
  hideTrust: string[];
  hideClasses: string[];
  site: string | null;
  driver: string | null;
  /** Seen on or after / on or before (YYYY-MM-DD). */
  from: string | null;
  to: string | null;
  /** Leave out notes with nothing shown to link to. */
  hideOrphans: boolean;
}

export const NO_FILTERS: Filters = {
  hideKinds: [],
  hideTrust: [],
  hideClasses: [],
  site: null,
  driver: null,
  from: null,
  to: null,
  hideOrphans: false,
};

export function isFiltered(f: Filters): boolean {
  return JSON.stringify({ ...NO_FILTERS, ...f }) !== JSON.stringify(NO_FILTERS);
}

/**
 * 1 for each note the filters leave showing. A filter on something a note
 * doesn't have (a policy class on a site, a driver on a page) leaves it
 * showing; a site filter keeps only notes that belong to that site.
 */
export function visibleMask(graph: GraphData, f: Filters): Uint8Array {
  const shows = (n: ViewNode) =>
    !f.hideKinds.includes(n.kind) &&
    !f.hideTrust.includes(n.trust) &&
    !(n.class !== null && f.hideClasses.includes(n.class)) &&
    (f.site === null || n.sites.includes(f.site)) &&
    (f.driver === null || n.drivers.length === 0 || n.drivers.includes(f.driver)) &&
    (f.from === null || n.last === null || n.last >= f.from) &&
    (f.to === null || n.first === null || n.first <= f.to);

  const mask = Uint8Array.from(graph.nodes, (n) => (shows(n) ? 1 : 0));
  if (f.hideOrphans) {
    const linked = new Uint8Array(mask.length);
    for (const [a, b] of graph.links) {
      if (mask[a] && mask[b]) linked[a] = linked[b] = 1;
    }
    for (let i = 0; i < mask.length; i++) mask[i] &= linked[i];
  }
  return mask;
}

/** The values each filter can take in this graph, in order. */
export function choices(graph: GraphData) {
  const set = (pick: (n: ViewNode) => (string | null)[]) =>
    [...new Set(graph.nodes.flatMap(pick).filter((v): v is string => v !== null))].sort();
  return {
    kinds: set((n) => [n.kind]),
    trust: set((n) => [n.trust]),
    classes: set((n) => [n.class]),
    sites: set((n) => n.sites),
    drivers: set((n) => n.drivers),
  };
}

/** A note and the notes within `depth` links of it, either direction. */
export function neighbourhood(graph: GraphData, id: string, depth: number): GraphData {
  const start = graph.nodes.findIndex((n) => n.id === id);
  if (start < 0) return { ...graph, nodes: [], links: [] };

  const near: number[][] = graph.nodes.map(() => []);
  for (const [a, b] of graph.links) {
    near[a].push(b);
    near[b].push(a);
  }

  const seen = new Set([start]);
  let ring = [start];
  for (let d = 0; d < depth; d++) {
    const next: number[] = [];
    for (const i of ring) {
      for (const j of near[i]) {
        if (!seen.has(j)) {
          seen.add(j);
          next.push(j);
        }
      }
    }
    ring = next;
  }

  const kept = [...seen].sort((a, b) => a - b);
  const at = new Map(kept.map((i, k) => [i, k]));
  return {
    schema: graph.schema,
    nodes: kept.map((i) => graph.nodes[i]),
    links: graph.links
      .filter(([a, b]) => at.has(a) && at.has(b))
      .map(([a, b]) => [at.get(a)!, at.get(b)!] as [number, number]),
  };
}
