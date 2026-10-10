// The viewer's page: a sidebar of notes and a note or home view, kept up to
// date as tiny-axe writes the vault. Text from notes always goes in as text;
// the only HTML inserted is a note body the server rendered (render.ts).

type Value = string | number | boolean | null | string[];

interface Entry {
  id: string;
  title: string;
  kind: string;
  trust: string;
  gate: string | null;
  seen: number | null;
  last_seen: string | null;
}

interface Overview {
  summary: Record<"sites" | "pages" | "controls" | "paths" | "blocked" | "tools" | "tasks", number>;
  folders: { name: string; notes: Entry[] }[];
}

interface NoteDetail extends Entry {
  folder: string;
  props: [string, Value][];
  refs: Record<string, { id: string; title: string; kind: string }>;
  html: string;
  backlinks: { folder: string; notes: Entry[] }[];
}

interface Result extends Entry {
  folder: string;
  snippet: string;
}

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const main = $<HTMLElement>("main");
const tree = $<HTMLElement>("tree");
const search = $<HTMLInputElement>("search");

let overview: Overview | null = null;

// Elements, with text set as text.
function h(tag: string, attrs: Record<string, string> = {}, ...children: (Node | string | null)[]) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  for (const child of children) if (child !== null) el.append(child);
  return el;
}

const noteHref = (id: string) => `/note/${encodeURIComponent(id)}`;
const blocked = (e: { kind: string; gate?: string | null }) =>
  e.kind === "path" && (e.gate === "refused" || e.gate === "denied");

function dot(e: Entry) {
  return h("span", { class: `dot ${e.kind} ${e.trust}${blocked(e) ? " blocked" : ""}`, "aria-hidden": "true" });
}

function item(e: Entry, extra: (Node | string | null)[] = []) {
  const a = h("a", { class: "item", href: noteHref(e.id), title: e.title }, dot(e), h("span", { class: "label" }, e.title), ...extra);
  if (location.pathname === noteHref(e.id)) a.setAttribute("aria-current", "page");
  return a;
}

async function get<T>(path: string): Promise<T> {
  const res = await fetch(path, { headers: { Accept: "application/json" } });
  if (res.status === 401) throw new Error("This page needs the address tiny-axe graph printed. Open it again from the terminal.");
  if (!res.ok) throw new Error((await res.json().catch(() => null))?.error ?? `The server said ${res.status}.`);
  return res.json() as Promise<T>;
}

// Sidebar

const ORDER: Record<string, (a: Entry, b: Entry) => number> = {
  Tasks: (a, b) => (a.id < b.id ? 1 : -1),
};
const byTitle = (a: Entry, b: Entry) => a.title.localeCompare(b.title);

function openFolders(): Set<string> {
  try {
    return new Set(JSON.parse(localStorage.getItem("open-folders") ?? '["Sites"]'));
  } catch {
    return new Set(["Sites"]);
  }
}

function rememberFolder(name: string, open: boolean) {
  const folders = openFolders();
  if (open) folders.add(name);
  else folders.delete(name);
  try {
    localStorage.setItem("open-folders", JSON.stringify([...folders]));
  } catch {
    // Remembering open folders is a convenience.
  }
}

function renderSummary() {
  if (!overview) return;
  const s = overview.summary;
  $("summary").textContent =
    `${s.sites} sites · ${s.pages} pages · ${s.paths} paths (${s.blocked} stopped) · ${s.tools} tools · ${s.tasks} tasks`;
}

function renderTree() {
  if (!overview || search.value.trim()) return;
  const open = openFolders();
  tree.replaceChildren(
    ...overview.folders.map(({ name, notes }) => {
      const details = h(
        "details",
        open.has(name) ? { open: "" } : {},
        h("summary", {}, name, h("span", { class: "count" }, String(notes.length))),
        h("ul", {}, ...[...notes].sort(ORDER[name] ?? byTitle).map((e) => h("li", {}, item(e)))),
      ) as HTMLDetailsElement;
      details.addEventListener("toggle", () => rememberFolder(name, details.open));
      return details;
    }),
  );
}

let searching = 0;
async function runSearch() {
  const q = search.value.trim();
  if (!q) return renderTree();
  const mine = ++searching;
  const { results } = await get<{ results: Result[] }>(`/api/search?q=${encodeURIComponent(q)}`);
  if (mine !== searching) return;
  tree.replaceChildren(
    results.length === 0
      ? h("p", { class: "empty" }, "Nothing matches.")
      : h(
          "ul",
          { class: "results" },
          ...results.map((r) =>
            h(
              "li",
              {},
              item(r, [h("span", { class: "where" }, r.folder), r.snippet ? h("span", { class: "snippet" }, r.snippet) : null]),
            ),
          ),
        ),
  );
}

// Views

function showProblem(error: unknown) {
  main.replaceChildren(h("p", { class: "problem" }, (error as Error).message));
}

function renderHome() {
  if (!overview) return;
  document.title = "tiny-axe know-how";
  const s = overview.summary;
  const notes = (folder: string) => overview!.folders.find((f) => f.name === folder)?.notes ?? [];

  const tile = (n: number, what: string, sub?: string) =>
    h("div", { class: "tile" }, h("div", { class: "n" }, String(n)), h("div", { class: "what" }, what), sub ? h("div", { class: "sub" }, sub) : null);

  const list = (entries: Entry[], meta: (e: Entry) => string, empty: string) =>
    entries.length === 0
      ? h("p", { class: "empty" }, empty)
      : h("ul", {}, ...entries.map((e) => h("li", {}, item(e, [h("span", { class: "meta" }, meta(e))]))));

  const sites = [...notes("Sites")].sort((a, b) => (b.seen ?? 0) - (a.seen ?? 0));
  const tasks = [...notes("Tasks")].sort(ORDER.Tasks).slice(0, 10);
  const stopped = notes("Paths").filter(blocked).sort(byTitle);

  main.replaceChildren(
    h(
      "div",
      { class: "home" },
      h("h1", {}, "What tiny-axe knows"),
      h("p", { class: "lede" }, "Every site, page and decision path tiny-axe has used on the web, from its own records."),
      h(
        "div",
        { class: "tiles" },
        tile(s.sites, "sites"),
        tile(s.pages, "pages"),
        tile(s.paths, "decision paths", s.blocked ? `${s.blocked} stopped by the gate` : undefined),
        tile(s.tools, "tools"),
        tile(s.tasks, "tasks"),
      ),
      h("h2", {}, "Sites"),
      list(sites, (e) => `${e.seen ?? 0} actions`, "No sites yet."),
      h("h2", {}, "Recent tasks"),
      list(tasks, (e) => e.last_seen?.slice(0, 10) ?? "", "No tasks yet."),
      h("h2", {}, "Where the gate stopped it"),
      list(stopped, (e) => e.gate ?? "", "Nothing stopped yet."),
    ),
  );
}

function propValue(value: Value, refs: NoteDetail["refs"]): Node {
  if (value === null) return h("span", { class: "null" }, "none");
  const one = (v: string) => (refs[v] ? h("a", { href: noteHref(refs[v].id) }, refs[v].title) : document.createTextNode(v));
  if (Array.isArray(value)) {
    if (value.length === 0) return h("span", { class: "null" }, "none");
    return h("span", {}, ...value.map((v) => h("span", { class: "chip" }, one(v))));
  }
  return typeof value === "string" ? one(value) : document.createTextNode(String(value));
}

async function renderNote(id: string) {
  const note = await get<NoteDetail>(`/api/note?id=${encodeURIComponent(id)}`);
  document.title = `${note.title} · tiny-axe know-how`;

  const body = h("div", { class: "body" });
  body.innerHTML = note.html;

  const props = h(
    "details",
    { class: "props" },
    h("summary", {}, "Properties"),
    h(
      "dl",
      {},
      ...note.props
        .filter(([name]) => !["kind", "title"].includes(name))
        .flatMap(([name, value]) => [h("dt", {}, name), h("dd", {}, propValue(value, note.refs))]),
    ),
  );
  // Under the title, as Obsidian shows them.
  const title = body.querySelector("h1");
  if (title) title.after(props);
  else body.prepend(props);

  const badges = h(
    "div",
    { class: "badges" },
    h("span", { class: "badge" }, note.kind),
    h("span", { class: `badge trust-${note.trust}` }, note.trust),
    note.gate ? h("span", { class: `badge${blocked(note) ? " blocked" : ""}` }, `gate: ${note.gate}`) : null,
  );

  const backlinks =
    note.backlinks.length === 0
      ? null
      : h(
          "section",
          { class: "backlinks" },
          h("h2", {}, "Linked from"),
          ...note.backlinks.flatMap(({ folder, notes }) => [
            h("h3", {}, folder),
            h("ul", {}, ...[...notes].sort(ORDER[folder] ?? byTitle).map((e) => h("li", {}, item(e)))),
          ]),
        );

  main.replaceChildren(h("article", { class: "note" }, h("div", { class: "crumbs" }, note.folder), badges, body, backlinks));
}

// Routing

async function route(scroll = true) {
  try {
    const m = location.pathname.match(/^\/note\/(.+)$/);
    if (m) await renderNote(decodeURIComponent(m[1]));
    else renderHome();
    renderTree();
    if (scroll) {
      window.scrollTo(0, 0);
      main.focus({ preventScroll: true });
    }
  } catch (error) {
    showProblem(error);
  }
}

document.addEventListener("click", (event) => {
  const a = (event.target as Element).closest("a");
  if (!a || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey) return;
  const url = new URL(a.href, location.href);
  if (url.origin !== location.origin || !(url.pathname === "/" || url.pathname.startsWith("/note/"))) return;
  event.preventDefault();
  if (url.pathname !== location.pathname) history.pushState(null, "", url.pathname);
  $("sidebar").classList.remove("open");
  route();
});

window.addEventListener("popstate", () => route());

$("menu").addEventListener("click", () => {
  const open = $("sidebar").classList.toggle("open");
  $("menu").setAttribute("aria-expanded", String(open));
});

let typing: number | undefined;
search.addEventListener("input", () => {
  clearTimeout(typing);
  typing = window.setTimeout(() => runSearch().catch(showProblem), 120);
});

async function load() {
  overview = await get<Overview>("/api/vault");
  renderSummary();
}

// tiny-axe writes notes as tasks finish; show them without a reload.
function listen() {
  const events = new EventSource("/api/events");
  events.addEventListener("vault", async () => {
    try {
      await load();
      if (search.value.trim()) await runSearch();
      await route(false);
    } catch (error) {
      showProblem(error);
    }
  });
}

load()
  .then(() => route(false))
  .then(listen)
  .catch(showProblem);
