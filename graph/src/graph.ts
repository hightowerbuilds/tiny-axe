// The graph as the page draws it: every note a node, every wikilink between
// two notes a line, with what the filters need on each node. Lines are pairs
// of node indexes, which keeps a 5,000-note vault's graph small to send.

import type { Value } from "./format.ts";
import type { Vault, VaultNote } from "./vault.ts";

export interface ViewNode {
  id: string;
  kind: string;
  title: string;
  folder: string;
  trust: string;
  /** Times used, for the dot's size; null for notes that don't count. */
  seen: number | null;
  /** A path's gate decision and policy class. */
  gate: string | null;
  class: string | null;
  /** The sites a note belongs to; a tool's are the sites it was used on. */
  sites: string[];
  /** Who drove: a task's driver, a path's drivers. */
  drivers: string[];
  /** First and last day seen (YYYY-MM-DD). */
  first: string | null;
  last: string | null;
}

export interface GraphData {
  schema: string;
  nodes: ViewNode[];
  /** [from, to] as indexes into `nodes`. */
  links: [number, number][];
}

export function graphView(vault: Vault): GraphData {
  const notes = [...vault.notes.values()];
  const index = new Map(notes.map((note, i) => [note.id, i]));

  const links: [number, number][] = [];
  for (const [i, note] of notes.entries()) {
    for (const target of note.links) {
      const j = index.get(target);
      if (j !== undefined) links.push([i, j]);
    }
  }

  const nodes = notes.map((note): ViewNode => {
    const p = props(note);
    const day = (v: Value | undefined) => (typeof v === "string" ? v.slice(0, 10) : null);
    return {
      id: note.id,
      kind: note.kind,
      title: note.title,
      folder: note.folder,
      trust: note.trust,
      seen: typeof p.seen === "number" ? p.seen : null,
      gate: note.kind === "path" ? str(p.gate) : null,
      class: note.kind === "path" ? str(p.class) : null,
      sites: note.kind === "site" ? strs(p.key) : note.kind === "task" ? strs(p.sites) : strs(p.site),
      drivers: note.kind === "task" ? strs(p.driver) : strs(p.drivers),
      first: day(p.first_seen ?? p.started),
      last: day(p.last_seen ?? p.started),
    };
  });

  // A tool belongs to the sites of the paths that used it.
  for (const [i, note] of notes.entries()) {
    if (note.kind !== "tool") continue;
    const sites = new Set<string>();
    for (const from of vault.backlinks.get(note.id) ?? []) {
      const j = index.get(from);
      if (j !== undefined && nodes[j].kind === "path") for (const s of nodes[j].sites) sites.add(s);
    }
    nodes[i].sites = [...sites].sort();
  }

  return { schema: String(vault.manifest.schema), nodes, links };
}

function props(note: VaultNote): Record<string, Value> {
  return Object.fromEntries(note.props);
}

function str(v: Value | undefined): string | null {
  return typeof v === "string" ? v : null;
}

function strs(v: Value | undefined): string[] {
  if (typeof v === "string") return [v];
  return Array.isArray(v) ? v.filter((x) => typeof x === "string") : [];
}
