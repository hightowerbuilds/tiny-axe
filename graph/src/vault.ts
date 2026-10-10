// Reads a vault folder into the graph the viewer draws: every note a node,
// every wikilink a line.

import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { FOLDERS, SCHEMA, links, parseNote, type Value } from "./format.ts";

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

export async function readVault(dir: string): Promise<Graph> {
  const manifest = JSON.parse(await readFile(join(dir, ".tiny-axe", "vault.json"), "utf8"));
  if (manifest.schema !== SCHEMA) {
    throw new Error(`this viewer reads ${SCHEMA}, and the vault is ${manifest.schema}`);
  }

  const nodes: GraphNode[] = [];
  const outgoing = new Map<string, string[]>();

  for (const folder of Object.values(FOLDERS)) {
    const files = await readdir(join(dir, folder)).catch(() => [] as string[]);
    for (const file of files.filter((f) => f.endsWith(".md")).sort()) {
      const id = file.slice(0, -3);
      const note = parseNote(await readFile(join(dir, folder, file), "utf8"));
      const props = Object.fromEntries(note.props) as Record<string, Value>;
      nodes.push({
        id,
        kind: String(props.kind),
        title: String(props.title),
        folder,
        trust: String(props.trust),
        seen: typeof props.seen === "number" ? props.seen : null,
      });
      outgoing.set(id, links(note.body));
    }
  }

  nodes.sort((a, b) => compare(a.id, b.id));
  const ids = new Set(nodes.map((n) => n.id));
  const found = new Map<string, { source: string; target: string }>();
  const missing = new Map<string, { source: string; target: string }>();

  for (const [source, targets] of outgoing) {
    for (const target of targets) {
      if (target === source) continue;
      (ids.has(target) ? found : missing).set(`${source}\n${target}`, { source, target });
    }
  }

  const sorted = (m: Map<string, { source: string; target: string }>) =>
    [...m.entries()].sort(([a], [b]) => compare(a, b)).map(([, v]) => v);

  return { schema: SCHEMA, nodes, links: sorted(found), unresolved: sorted(missing) };
}

// Plain string order, as Elixir sorts (note names are ASCII; localeCompare
// would depend on the locale).
function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
