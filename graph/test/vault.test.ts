// The viewer's side of the vault format, against the same fixture the Elixir
// writer is held to (test/fixtures/vault/, docs/vault-format.md).

import { test } from "node:test";
import assert from "node:assert/strict";
import { cp, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { basename, links, parseNote } from "../src/format.ts";
import { readVault } from "../src/vault.ts";

const fixture = join(import.meta.dirname, "../../test/fixtures/vault");
const json = async (name: string) => JSON.parse(await readFile(join(fixture, name), "utf8"));

test("note names match the writer's", async () => {
  for (const { kind, key, title, basename: name } of await json("names.json")) {
    assert.equal(basename(kind, key, title), name, `${kind} ${key}`);
  }
});

test("the fixture vault reads to graph.json", async () => {
  assert.deepEqual(await readVault(join(fixture, "vault")), await json("graph.json"));
});

test("links skip code, escapes and headings", () => {
  const body = "[[a|A]] `[[b]]` [[c#part]]\n```\n[[d]]\n```\n[[e]] \\[[f]]";
  assert.deepEqual(links(body), ["a", "c", "e"]);
});

test("frontmatter is one JSON value per line", () => {
  const note = parseNote('---\nkind: "path"\nseen: 2\nsite: null\ntasks: ["a","b"]\n---\n\n# x\n');
  assert.deepEqual(note.props, [["kind", "path"], ["seen", 2], ["site", null], ["tasks", ["a", "b"]]]);
  assert.equal(note.body, "\n# x\n");
  assert.throws(() => parseNote("# no frontmatter\n"));
});

test("a vault of another schema is refused", async () => {
  const dir = await mkdtemp(join(tmpdir(), "vault-"));
  await cp(join(fixture, "vault"), dir, { recursive: true });
  await writeFile(join(dir, ".tiny-axe/vault.json"), JSON.stringify({ schema: "tiny-axe-vault/2" }));
  await assert.rejects(readVault(dir), /reads tiny-axe-vault\/1/);
});

test("a link to a missing note is reported, not drawn", async () => {
  const dir = await mkdtemp(join(tmpdir(), "vault-"));
  await cp(join(fixture, "vault"), dir, { recursive: true });
  const site = join(dir, "Sites/news.example.md");
  await writeFile(site, (await readFile(site, "utf8")) + "\nSee [[gone 12345678|Gone]].\n");
  const graph = await readVault(dir);
  assert.deepEqual(graph.unresolved, [{ source: "news.example", target: "gone 12345678" }]);
  assert.equal(graph.links.length, 40);
});
