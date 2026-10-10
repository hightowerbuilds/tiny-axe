// Writes a made-up vault of about N notes, shaped like the writer's (sites,
// their pages and controls, paths, tasks and shared tools), for trying the
// viewer at size:
//
//   node scripts/sample-vault.ts 5000 /tmp/big-vault
//   node dist/server.js --vault /tmp/big-vault
//
// Every name and label is invented (*.example sites).

import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { basename, FOLDERS, SCHEMA } from "../src/format.ts";

const [count = "5000", dir] = process.argv.slice(2);
if (!dir) {
  console.error("usage: node scripts/sample-vault.ts COUNT FOLDER");
  process.exit(2);
}

// A fixed seed, so the same count gives the same vault.
let seed = 42;
const random = () => ((seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
const pick = <T>(list: T[]) => list[Math.floor(random() * list.length)];

type Props = [string, unknown][];
const notes: { kind: string; props: Props; body: string; name: string }[] = [];
const link = (n: { name: string; title: string }) => `[[${n.name}|${n.title}]]`;

function note(kind: string, key: string, title: string, extra: Props, body: string[]) {
  const name = basename(kind, key, title);
  notes.push({ kind, name, props: [["kind", kind], ["key", key], ["title", title], ["trust", "observed"], ...extra], body: [`# ${title}`, "", ...body].join("\n") });
  return { name, title };
}

const day = (d: number) => `2026-${String(9 + Math.floor(d / 30)).padStart(2, "0")}-${String((d % 30) + 1).padStart(2, "0")}`;
const words = ["Search", "Add to Cart", "Checkout", "Sign in", "Next", "Reply", "Save", "Filter", "Sort", "Details", "Share", "Subscribe"];
const roles = ["button", "link", "textbox", "searchbox", "checkbox"];
const classes = ["read", "local", "outward", "commit"];
const drivers = ["claude-haiku-5-5", "jev-1.13.0"];

const tools = ["click", "type", "navigate", "snapshot", "select_option", "press_key", "hover", "scroll"].map((t) =>
  note("tool", `browser__browser_${t}`, `browser_${t} (browser)`, [["server", "browser"], ["name", `browser_${t}`]], ["Used by the browser."]),
);

const sites = Math.max(1, Math.round(Number(count) / 125));
for (let s = 0; s < sites; s++) {
  const host = `site-${s}.example`;
  const site = note("site", host, host, [["seen", 0]], ["A made-up site."]);
  const pages = Array.from({ length: 12 }, (_, p) =>
    note("page", `${host}/p${p}/:id`, `${host}/p${p}/:id`, [["site", host]], [`- Site: ${link(site)}`]),
  );
  const controls = Array.from({ length: 30 }, (_, c) => {
    const page = pick(pages);
    const label = `${pick(words)} ${c}`;
    const role = pick(roles);
    return note("control", `${host}|${role}|${label}`, `${label} (${role})`, [["site", host], ["role", role], ["label", label]], [`- On: ${link(page)}`]);
  });
  const paths = Array.from({ length: 60 }, (_, k) => {
    const control = pick(controls);
    const tool = pick(tools);
    const cls = pick(classes);
    const gate = cls === "commit" && random() < 0.5 ? "refused" : cls === "outward" && random() < 0.3 ? "denied" : "ran";
    const first = Math.floor(random() * 50);
    return note(
      "path",
      `${host}|${k}|${tool.name}|${gate}`,
      `${tool.title.split(" ")[0]} "${control.title}" → ${gate}`,
      [["site", host], ["class", cls], ["gate", gate], ["seen", 1 + Math.floor(random() * 20)], ["drivers", [pick(drivers)]], ["first_seen", day(first)], ["last_seen", day(first + Math.floor(random() * 10))]],
      [`- Acted on: ${link(control)}`, `- Tool: ${link(tool)}`, `- Led to: ${link(pick(pages))}`],
    );
  });
  for (let t = 0; t < 20; t++) {
    const id = `2026${String(s).padStart(4, "0")}-${String(t).padStart(6, "0")}-1`;
    const steps = Array.from({ length: 3 + Math.floor(random() * 5) }, () => `1. ${link(pick(paths))}`);
    note("task", id, id, [["driver", pick(drivers)], ["started", `${day(Math.floor(random() * 60))}T10:00:00Z`], ["sites", [host]]], ["Steps", ...steps]);
  }
}

await rm(dir, { recursive: true, force: true });
await mkdir(join(dir, ".tiny-axe"), { recursive: true });
await writeFile(join(dir, ".tiny-axe", "vault.json"), JSON.stringify({ schema: SCHEMA }) + "\n");
for (const folder of Object.values(FOLDERS)) await mkdir(join(dir, folder), { recursive: true });
for (const n of notes) {
  const front = n.props.map(([k, v]) => `${k}: ${JSON.stringify(v)}`).join("\n");
  await writeFile(join(dir, (FOLDERS as Record<string, string>)[n.kind], `${n.name}.md`), `---\n${front}\n---\n\n${n.body}\n`);
}
console.log(`wrote ${notes.length} notes to ${dir}`);
