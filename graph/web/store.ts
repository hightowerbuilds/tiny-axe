// What the page shows, kept up to date: the vault's overview and graph
// (fetched again whenever tiny-axe writes notes), where the page is, and
// the conveniences remembered in this browser. Solid signals and a store,
// so each part of the page updates on its own.

import { batch, createSignal } from "solid-js";
import { createStore, reconcile } from "solid-js/store";
import type { GraphData } from "../src/graph.ts";

export type Value = string | number | boolean | null | string[];

export interface Entry {
  id: string;
  title: string;
  kind: string;
  trust: string;
  gate: string | null;
  seen: number | null;
  last_seen: string | null;
}

export interface Overview {
  summary: Record<"sites" | "pages" | "controls" | "paths" | "blocked" | "tools" | "tasks", number>;
  folders: { name: string; notes: Entry[] }[];
}

export interface NoteDetail extends Entry {
  folder: string;
  props: [string, Value][];
  refs: Record<string, { id: string; title: string; kind: string }>;
  html: string;
  backlinks: { folder: string; notes: Entry[] }[];
}

export interface Result extends Entry {
  folder: string;
  snippet: string;
}

export async function get<T>(path: string): Promise<T> {
  const res = await fetch(path, { headers: { Accept: "application/json" } });
  if (res.status === 401) throw new Error("This page needs the address tiny-axe graph printed. Open it again from the terminal.");
  if (!res.ok) throw new Error((await res.json().catch(() => null))?.error ?? `The server said ${res.status}.`);
  return res.json() as Promise<T>;
}

// Remembered in this browser, as a convenience; the page works without.

export function recall<T>(key: string, fallback: T): T {
  try {
    const saved = localStorage.getItem(key);
    return saved === null ? fallback : (JSON.parse(saved) as T);
  } catch {
    return fallback;
  }
}

export function remember(key: string, value: unknown) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // See recall.
  }
}

// The vault

/** The sidebar's and overview's view of the vault. Notes keep their place
 * in it from one update to the next (matched by id), so only what changed
 * is redrawn. */
export const [overview, setOverview] = createStore<{ summary: Overview["summary"] | null; folders: Overview["folders"] }>({
  summary: null,
  folders: [],
});
/** Every note and link, for the graphs: a new object each update. */
export const [graph, setGraph] = createSignal<GraphData | null>(null);
/** The notes the last update changed, and a count of updates. */
export const [changes, setChanges] = createSignal<{ ids: string[]; version: number }>({ ids: [], version: 0 });
export const [problem, setProblem] = createSignal<string | null>(null);

// One fetch at a time; changes that arrive meanwhile wait for one more.
let fetching = false;
let queued: string[] | null = null;

/** Fetches the vault again: `changed` are the notes the server says moved. */
export async function refresh(changed: string[] = []) {
  if (fetching) {
    queued = [...(queued ?? []), ...changed];
    return;
  }
  fetching = true;
  try {
    let ids = changed;
    for (;;) {
      const [o, g] = await Promise.all([get<Overview>("/api/vault"), get<GraphData>("/api/graph")]);
      batch(() => {
        setOverview(reconcile(o, { key: "id" }));
        setGraph(g);
        setChanges((c) => ({ ids, version: c.version + 1 }));
        setProblem(null);
      });
      if (queued === null) break;
      ids = queued;
      queued = null;
    }
  } catch (error) {
    setProblem((error as Error).message);
  } finally {
    fetching = false;
  }
}

/** Whether `ids` changed note `id` or a note linked to it, either way. */
export function touches(id: string, ids: string[]) {
  if (ids.includes(id)) return true;
  const g = graph();
  if (!g || ids.length === 0) return false;
  const at = g.nodes.findIndex((n) => n.id === id);
  const near = new Set(ids);
  return g.links.some(([a, b]) => (a === at && near.has(g.nodes[b].id)) || (b === at && near.has(g.nodes[a].id)));
}

// Where the page is

export type Route = { kind: "graph"; focus: string | null } | { kind: "overview" } | { kind: "note"; id: string };

const here = () => location.pathname + location.search;
// Not deduplicated: following a link to where the page is still counts.
export const [href, setHref] = createSignal(here(), { equals: false });
export const [menuOpen, setMenuOpen] = createSignal(false);

export function route(): Route {
  const url = new URL(href(), location.origin);
  const note = url.pathname.match(/^\/note\/(.+)$/);
  if (note) return { kind: "note", id: decodeURIComponent(note[1]) };
  if (url.pathname === "/overview") return { kind: "overview" };
  return { kind: "graph", focus: url.searchParams.get("focus") };
}

export const ROUTES = (path: string) => path === "/" || path === "/overview" || path.startsWith("/note/");

export function go(to: string) {
  if (to !== here()) history.pushState(null, "", to);
  setMenuOpen(false);
  setHref(here());
  window.scrollTo(0, 0);
  document.getElementById("main")?.focus({ preventScroll: true });
}

window.addEventListener("popstate", () => setHref(here()));

// Small shared pieces

export const noteHref = (id: string) => `/note/${encodeURIComponent(id)}`;
export const graphHref = (id: string) => `/?focus=${encodeURIComponent(id)}`;
export const blocked = (e: { kind: string; gate?: string | null }) =>
  e.kind === "path" && (e.gate === "refused" || e.gate === "denied");

export const ORDER: Record<string, (a: Entry, b: Entry) => number> = {
  Tasks: (a, b) => (a.id < b.id ? 1 : -1),
};
export const byTitle = (a: Entry, b: Entry) => a.title.localeCompare(b.title);
export const sorted = (folder: string, notes: Entry[]) => [...notes].sort(ORDER[folder] ?? byTitle);
