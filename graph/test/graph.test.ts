// The graph the page draws, its filters and local graphs, against the
// fixture vault.

import { test } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { loadVault } from "../src/vault.ts";
import { graphView, type GraphData } from "../src/graph.ts";
import { choices, isFiltered, neighbourhood, NO_FILTERS, visibleMask, type Filters } from "../web/filter.ts";

const vault = await loadVault(join(import.meta.dirname, "../../test/fixtures/vault/vault"));
const graph = graphView(vault);

const at = (id: string) => graph.nodes.findIndex((n) => n.id === id);
const node = (id: string) => graph.nodes[at(id)];
const ids = (g: GraphData, mask?: Uint8Array) => g.nodes.filter((_, i) => !mask || mask[i]).map((n) => n.id);
const only = (f: Partial<Filters>) => visibleMask(graph, { ...NO_FILTERS, ...f });

const PATH = "click-Add-to-Cart-ran 694659fe";
const REFUSED = "click-Proceed-to-checkout-refused 16be154f";

test("every line is a link in a note, and every link between notes is a line", () => {
  const lines = new Set(graph.links.map(([a, b]) => `${graph.nodes[a].id} → ${graph.nodes[b].id}`));
  const written = new Set(
    [...vault.notes.values()].flatMap((n) => n.links.filter((t) => vault.notes.has(t)).map((t) => `${n.id} → ${t}`)),
  );
  assert.deepEqual(lines, written);
  assert.equal(graph.nodes.length, 28);
  assert.equal(graph.links.length, 40);
});

test("nodes carry what the filters need", () => {
  assert.deepEqual(
    { ...node(PATH) },
    {
      id: PATH,
      kind: "path",
      title: 'click "Add to Cart" → ran',
      folder: "Paths",
      trust: "observed",
      seen: 2,
      gate: "ran",
      class: "local",
      sites: ["shop.example"],
      drivers: ["claude-haiku-5-5"],
      first: "2026-10-01",
      last: "2026-10-02",
    },
  );
  assert.deepEqual(node("shop.example").sites, ["shop.example"]);
  assert.deepEqual(node("20261001-100000-1").drivers, ["claude-haiku-5-5"]);
  assert.equal(node("20261001-100000-1").first, "2026-10-01");
  // A tool belongs to the sites it was used on.
  assert.deepEqual(node("browser__browser_type").sites, ["news.example", "shop.example"]);
  assert.deepEqual(node("browser__browser_click").sites, ["shop.example"]);
});

test("no filters, everything shows", () => {
  assert.equal(isFiltered(NO_FILTERS), false);
  assert.equal(only({}).reduce((a, b) => a + b, 0), 28);
  assert.deepEqual(choices(graph), {
    kinds: ["control", "page", "path", "site", "task", "tool"],
    trust: ["observed"],
    classes: ["commit", "local", "outward", "read"],
    sites: ["news.example", "shop.example"],
    drivers: ["claude-haiku-5-5"],
  });
});

test("a site filter keeps that site's notes, and the tools used there", () => {
  const shown = ids(graph, only({ site: "news.example" }));
  assert.ok(shown.length > 0);
  assert.ok(shown.includes("news.example"));
  assert.ok(!shown.includes("shop.example"));
  assert.ok(!shown.includes(PATH));
  assert.ok(shown.includes("browser__browser_type"));
  assert.ok(!shown.includes("browser__browser_click"));
  for (const id of shown) assert.ok(node(id).sites.includes("news.example"), id);
});

test("class, driver and kind filters leave out only what they name", () => {
  const noCommit = ids(graph, only({ hideClasses: ["commit"] }));
  assert.ok(!noCommit.includes(REFUSED));
  assert.ok(noCommit.includes(PATH));
  assert.ok(noCommit.includes("shop.example"));

  const otherDriver = ids(graph, only({ driver: "someone-else" }));
  assert.ok(!otherDriver.includes(PATH));
  assert.ok(!otherDriver.includes("20261001-100000-1"));
  assert.ok(otherDriver.includes("shop.example"));

  const noPaths = ids(graph, only({ hideKinds: ["path"] }));
  assert.ok(noPaths.every((id) => node(id).kind !== "path"));
  assert.ok(isFiltered({ ...NO_FILTERS, hideKinds: ["path"] }));
});

test("dates keep notes seen within the range", () => {
  const second = ids(graph, only({ from: "2026-10-02" }));
  assert.ok(!second.includes("20261001-100000-1"));
  assert.ok(second.includes("20261002-110000-2"));
  assert.ok(second.includes(PATH)); // seen on both days
  const first = ids(graph, only({ to: "2026-10-01" }));
  assert.ok(first.includes("20261001-100000-1"));
  assert.ok(!first.includes("20261002-110000-2"));
});

test("hiding orphans drops notes left with nothing to link to", () => {
  const shown = ids(graph, only({ hideKinds: ["page", "control", "task", "tool"], hideOrphans: true }));
  // Paths link to controls and tools, sites to nothing: all left alone.
  assert.deepEqual(shown, []);
});

test("a local graph is the notes within depth links, either way", () => {
  const one = neighbourhood(graph, PATH, 1);
  assert.deepEqual(
    ids(one).sort(),
    [
      PATH,
      "20261001-100000-1",
      "20261002-110000-2",
      "Add-to-Cart-button 0ec1c8ea",
      "browser__browser_click",
      "shop.example-cart-view.html ce5545df",
    ].sort(),
  );
  // Its lines are the fixture's lines between those notes.
  for (const [a, b] of one.links) {
    assert.ok(graph.links.some(([x, y]) => graph.nodes[x].id === one.nodes[a].id && graph.nodes[y].id === one.nodes[b].id));
  }
  const two = neighbourhood(graph, PATH, 2);
  assert.ok(two.nodes.length > one.nodes.length);
  assert.ok(ids(two).includes("shop.example-slug-dp-id 7323d50c"));
  assert.deepEqual(neighbourhood(graph, "nope", 2).nodes, []);
});
