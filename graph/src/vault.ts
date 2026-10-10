// Reads a vault folder: every note, its links and what links to it, and the
// graph the viewer draws from them (every note a node, every wikilink a line).

import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { FOLDERS, SCHEMA, links, parseNote, type Value } from "./format.ts";

export interface VaultNote {
  id: string;
  kind: string;
  folder: string;
  title: string;
  trust: string;
  props: [string, Value][];
  body: string;
  /** Basenames this note links to, without repeats or itself. */
  links: string[];
}

export interface Vault {
  dir: string;
  manifest: Record<string, unknown>;
  /** By basename, in name order. */
  notes: Map<string, VaultNote>;
  /** Basename → the notes that link to it. */
  backlinks: Map<string, string[]>;
  /** A note's key (`shop.example`, a task id, ...) → its basename. */
  byKey: Map<string, string>;
}

export interface GraphNode {
  id: string;
  kind: string;
  title: string;
  folder: string;
  trust: string;
  seen: number | null;
}

export interface Graph {
  schema: string;
  nodes: GraphNode[];
  links: { source: string; target: string }[];
  /** Links to notes that aren't there, as `{source, target}`. */
  unresolved: { source: string; target: string }[];
}

export async function loadVault(dir: string): Promise<Vault> {
  const manifest = JSON.parse(await readFile(join(dir, ".tiny-axe", "vault.json"), "utf8"));
  if (manifest.schema !== SCHEMA) {
    throw new Error(`this viewer reads ${SCHEMA}, and the vault is ${manifest.schema}`);
  }

  const found: VaultNote[] = [];

  for (const folder of Object.values(FOLDERS)) {
    const files = await readdir(join(dir, folder)).catch(() => [] as string[]);
    for (const file of files.filter((f) => f.endsWith(".md"))) {
      const id = file.slice(0, -3);
      const note = parseNote(await readFile(join(dir, folder, file), "utf8"));
      const props = Object.fromEntries(note.props) as Record<string, Value>;
      found.push({
        id,
        kind: String(props.kind),
        folder,
        title: String(props.title),
        trust: String(props.trust),
        props: note.props,
        body: note.body,
        links: [...new Set(links(note.body))].filter((target) => target !== id),
      });
    }
  }

  found.sort((a, b) => compare(a.id, b.id));
  const notes = new Map(found.map((n) => [n.id, n]));
  const backlinks = new Map<string, string[]>();
  const byKey = new Map<string, string>();

  for (const note of found) {
    const key = note.props.find(([name]) => name === "key")?.[1];
    if (typeof key === "string") byKey.set(key, note.id);
    for (const target of note.links) {
      if (!backlinks.has(target)) backlinks.set(target, []);
      backlinks.get(target)!.push(note.id);
    }
  }

  return { dir, manifest, notes, backlinks, byKey };
}

export function toGraph(vault: Vault): Graph {
  const nodes: GraphNode[] = [];
  const linked: { source: string; target: string }[] = [];
  const unresolved: { source: string; target: string }[] = [];

  for (const note of vault.notes.values()) {
    const seen = note.props.find(([name]) => name === "seen")?.[1];
    nodes.push({
      id: note.id,
      kind: note.kind,
      title: note.title,
      folder: note.folder,
      trust: note.trust,
      seen: typeof seen === "number" ? seen : null,
    });

    for (const target of [...note.links].sort(compare)) {
      (vault.notes.has(target) ? linked : unresolved).push({ source: note.id, target });
    }
  }

  return { schema: SCHEMA, nodes, links: linked, unresolved };
}

export async function readVault(dir: string): Promise<Graph> {
  return toGraph(await loadVault(dir));
}

// Plain string order, as Elixir sorts (note names are ASCII; localeCompare
// would depend on the locale).
export function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
