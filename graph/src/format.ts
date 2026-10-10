// The rules of the know-how vault's format (docs/vault-format.md), as the
// viewer needs them. TinyAxe.Vault.Format is the writer's copy; both are
// checked against test/fixtures/vault/.

import { createHash } from "node:crypto";

export const SCHEMA = "tiny-axe-vault/1";

export type Kind = "site" | "page" | "control" | "path" | "tool" | "task" | "workflow";

export const FOLDERS: Record<Kind, string> = {
  site: "Sites",
  page: "Pages",
  control: "Controls",
  path: "Paths",
  tool: "Tools",
  task: "Tasks",
  workflow: "Workflows",
};

const PLAIN_KINDS = new Set<string>(["site", "tool", "task"]);

/** A note's file name, without `.md`. */
export function basename(kind: string, key: string, title: string): string {
  return PLAIN_KINDS.has(kind) && slug(key) === key ? key : `${slug(title)} ${hash8(kind, key)}`;
}

/** Letters, digits, `.`, `_` and `-` only, at most 60 characters. */
export function slug(text: string): string {
  const trim = (s: string) => s.replace(/^[-.]+/, "").replace(/[-.]+$/, "");
  const ascii = text.normalize("NFKD").replace(/[^\x00-\x7F]/g, "");
  const s = trim(trim(ascii.replace(/[^A-Za-z0-9._-]+/g, "-")).slice(0, 60));
  return s === "" ? "note" : s;
}

export function hash8(kind: string, key: string): string {
  return createHash("sha256").update(`${kind}\n${key}`).digest("hex").slice(0, 8);
}

export type Value = string | number | boolean | null | string[];

export interface Note {
  /** Frontmatter, in file order. */
  props: [string, Value][];
  body: string;
}

/** Splits a note into its frontmatter and body. Throws on a malformed note. */
export function parseNote(text: string): Note {
  if (!text.startsWith("---\n")) throw new Error("no frontmatter");
  const end = text.indexOf("\n---\n", 3);
  if (end < 0) throw new Error("frontmatter isn't closed");
  const head = text.slice(4, end);
  const props: [string, Value][] = head.split("\n").map((line) => {
    const at = line.indexOf(": ");
    if (at < 0) throw new Error(`bad frontmatter line: ${line}`);
    return [line.slice(0, at), JSON.parse(line.slice(at + 2)) as Value];
  });
  return { props, body: text.slice(end + 5) };
}

const LINK = /(?<!\\)\[\[([^\[\]|\n#]+)(?:#[^\[\]|\n]*)?(?:\|[^\[\]\n]*)?\]\]/g;

/** The basenames a body links to, in order, skipping code. */
export function links(body: string): string[] {
  const text = body.replace(/^```[\s\S]*?^```/gm, "").replace(/`[^`\n]*`/g, "");
  return [...text.matchAll(LINK)].map((m) => m[1].trim());
}
