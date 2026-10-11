// The viewer's page: a sidebar of notes beside the graph, the overview or a
// note with its local graph, kept up to date as tiny-axe writes the vault.
// Text from notes always goes in as text; the only HTML inserted is a note
// body the server rendered (render.ts).

import type { GraphData } from "../src/graph.ts";
import { choices, isFiltered, neighbourhood, NO_FILTERS, visibleMask, type Filters } from "./filter.ts";
import { GraphView, type Dims } from "./graph.ts";

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
let graph: GraphData | null = null;

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

// Open folders, filters, 2D or 3D and the local graph's depth are
// remembered in this browser, as a convenience; the page works without.
function recall<T>(key: string, fallback: T): T {
  try {
    const saved = localStorage.getItem(key);
    return saved === null ? fallback : (JSON.parse(saved) as T);
  } catch {
    return fallback;
  }
}

function remember(key: string, value: unknown) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // See recall.
  }
}

function openFolders(): Set<string> {
  return new Set(recall<string[]>("open-folders", ["Sites"]));
}

function rememberFolder(name: string, open: boolean) {
  const folders = openFolders();
  if (open) folders.add(name);
  else folders.delete(name);
  remember("open-folders", [...folders]);
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

function renderOverview() {
  if (!overview) return;
  document.title = "Overview · tiny-axe know-how";
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
      h(
        "p",
        { class: "lede" },
        "Every site, page and decision path tiny-axe has used on the web, from its own records. ",
        h("a", { href: "/" }, "Open the graph"),
        ".",
      ),
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

  const crumbs = h(
    "div",
    { class: "crumbs" },
    h("span", {}, note.folder),
    h("a", { class: "button", href: graphHref(note.id) }, "Show in graph"),
  );
  const article = h("article", { class: "note" }, crumbs, badges, body, backlinks);
  main.replaceChildren(h("div", { class: "note-page" }, article, localPanel(note.id)));
}

// The graph (home): every note, with filters and a 2D/3D switch

const KINDS: Record<string, string> = {
  site: "Sites",
  page: "Pages",
  control: "Controls",
  path: "Paths",
  tool: "Tools",
  task: "Tasks",
  workflow: "Workflows",
};
const TRUST = ["observed", "verified", "validated"];

const graphHref = (id: string) => `/?focus=${encodeURIComponent(id)}`;

let dims: Dims = recall<number>("graph-dims", 2) === 3 ? 3 : 2;
let filters: Filters = { ...NO_FILTERS, ...recall<Partial<Filters>>("graph-filters", {}) };
let mask: Uint8Array = new Uint8Array(0);
let moving = false;
let globalView: GraphView | null = null;

const graphHolder = h("div", { class: "graph-holder" });
const graphTools = h("div", { class: "graph-tools" });
const graphStatus = h("p", { class: "graph-status", "aria-live": "polite" });
const graphPage = h("section", { class: "graph-page", "aria-label": "Graph" }, graphHolder, graphTools, graphStatus);

function globalGraph(): GraphView {
  if (!globalView) {
    globalView = new GraphView({
      label: "A graph of every note and its links. The sidebar lists the same notes.",
      background: "--bg",
      open: (id) => go(noteHref(id)),
      status: (now) => {
        moving = now;
        renderStatus();
      },
    });
    globalView.setDims(dims);
    if (graph) {
      globalView.setData(graph.nodes, graph.links);
      applyFilters();
    }
  }
  return globalView;
}

function applyFilters() {
  if (!graph) return;
  mask = visibleMask(graph, filters);
  globalView?.setVisible(mask);
  remember("graph-filters", filters);
  renderStatus();
  const marker = graphTools.querySelector(".filters summary .on");
  if (marker) marker.textContent = isFiltered(filters) ? "on" : "";
  graphTools.querySelector<HTMLButtonElement>(".reset")?.toggleAttribute("disabled", !isFiltered(filters));
}

function renderStatus() {
  if (!graph) return;
  const shown = mask.reduce((a, b) => a + b, 0);
  const lines = graph.links.filter(([a, b]) => mask[a] && mask[b]).length;
  const notes = shown === graph.nodes.length ? `${shown} notes` : `${shown} of ${graph.nodes.length} notes`;
  graphStatus.textContent = `${notes} · ${lines} links${moving ? " · laying out…" : ""}`;
}

function setDims(next: Dims) {
  dims = next;
  remember("graph-dims", dims);
  globalView?.setDims(dims);
  localView?.setDims(dims);
  for (const button of graphTools.querySelectorAll<HTMLButtonElement>(".mode button")) {
    button.setAttribute("aria-pressed", String(button.value === String(dims)));
  }
}

// The controls over the graph, rebuilt when the vault changes. Changing a
// filter updates the graph without rebuilding them, so focus stays put.
function renderTools() {
  if (!graph) return;
  const c = choices(graph);
  const count = (kind: string) => graph!.nodes.filter((n) => n.kind === kind).length;

  const toggle = (label: Node | string, checked: boolean, change: (on: boolean) => void) => {
    const box = h("input", { type: "checkbox" }) as HTMLInputElement;
    box.checked = checked;
    box.addEventListener("change", () => change(box.checked));
    return h("label", { class: "check" }, box, label);
  };
  const hideIn = (list: "hideKinds" | "hideTrust" | "hideClasses", value: string) => (on: boolean) => {
    filters = { ...filters, [list]: on ? filters[list].filter((v) => v !== value) : [...filters[list], value] };
    applyFilters();
  };
  const select = (label: string, values: string[], current: string | null, all: string, change: (v: string | null) => void) => {
    const el = h("select", {}, h("option", { value: "" }, all), ...values.map((v) => h("option", { value: v }, v))) as HTMLSelectElement;
    el.value = current ?? "";
    el.addEventListener("change", () => change(el.value || null));
    return h("label", { class: "field" }, h("span", {}, label), el);
  };
  const date = (label: string, current: string | null, change: (v: string | null) => void) => {
    const el = h("input", { type: "date" }) as HTMLInputElement;
    el.value = current ?? "";
    el.addEventListener("change", () => change(el.value || null));
    return h("label", { class: "field" }, h("span", {}, label), el);
  };
  const group = (legend: string, ...children: (Node | null)[]) =>
    h("fieldset", {}, h("legend", {}, legend), ...children);

  const mode = h(
    "div",
    { class: "mode", role: "group", "aria-label": "Layout" },
    ...([2, 3] as const).map((d) => {
      const b = h("button", { type: "button", value: String(d), "aria-pressed": String(d === dims) }, `${d}D`);
      b.addEventListener("click", () => setDims(d));
      return b;
    }),
  );
  const fit = h("button", { type: "button", class: "fit", title: "Bring every note into view" }, "Fit");
  fit.addEventListener("click", () => globalView?.fit(true));

  const reset = h("button", { type: "button", class: "reset" }, "Clear filters") as HTMLButtonElement;
  reset.disabled = !isFiltered(filters);
  reset.addEventListener("click", () => {
    filters = { ...NO_FILTERS };
    applyFilters();
    renderTools();
  });

  const panel = h(
    "details",
    { class: "filters", ...(recall("filters-open", false) ? { open: "" } : {}) },
    h("summary", {}, "Filters ", h("span", { class: "on" }, isFiltered(filters) ? "on" : "")),
    group(
      "Notes",
      ...c.kinds.map((k) =>
        toggle(
          h("span", { class: "with-dot" }, h("span", { class: `dot ${k}`, "aria-hidden": "true" }), `${KINDS[k] ?? k} `, h("span", { class: "count" }, String(count(k)))),
          !filters.hideKinds.includes(k),
          hideIn("hideKinds", k),
        ),
      ),
    ),
    group(
      "Trust",
      ...TRUST.filter((t) => c.trust.includes(t)).map((t) =>
        toggle(h("span", { class: "with-dot" }, h("span", { class: `dot ring ${t}`, "aria-hidden": "true" }), t), !filters.hideTrust.includes(t), hideIn("hideTrust", t)),
      ),
    ),
    c.classes.length === 0
      ? null
      : group("Policy class (paths)", ...c.classes.map((v) => toggle(v, !filters.hideClasses.includes(v), hideIn("hideClasses", v)))),
    group(
      "Where and who",
      c.sites.length === 0 ? null : select("Site", c.sites, filters.site, "All sites", (site) => ((filters = { ...filters, site }), applyFilters())),
      c.drivers.length === 0
        ? null
        : select("Driver", c.drivers, filters.driver, "Any driver", (driver) => ((filters = { ...filters, driver }), applyFilters())),
    ),
    group(
      "Seen",
      date("From", filters.from, (from) => ((filters = { ...filters, from }), applyFilters())),
      date("To", filters.to, (to) => ((filters = { ...filters, to }), applyFilters())),
    ),
    toggle("Hide notes with no links shown", filters.hideOrphans, (on) => ((filters = { ...filters, hideOrphans: on }), applyFilters())),
    reset,
  ) as HTMLDetailsElement;
  panel.addEventListener("toggle", () => remember("filters-open", panel.open));

  graphTools.replaceChildren(h("div", { class: "row" }, mode, fit), panel);
}

function renderGraph(focus: string | null) {
  document.title = "tiny-axe know-how";
  if (main.firstElementChild !== graphPage) main.replaceChildren(graphPage);
  if (!graphTools.hasChildNodes()) renderTools();
  const view = globalGraph();
  view.attach(graphHolder);
  if (focus) view.focus(focus);
  else view.setSelected(null);
}

// A note's local graph: the notes within 1–3 links of it

let localView: GraphView | null = null;
let depth = Math.min(3, Math.max(1, recall<number>("local-depth", 1)));

function localPanel(id: string) {
  if (!localView) {
    localView = new GraphView({
      label: "A graph of the notes linked to this one. They're listed in the note and under Linked from.",
      background: "--panel",
      open: (next) => go(noteHref(next)),
    });
    localView.setDims(dims);
  }
  const view = localView;
  const show = () => {
    if (!graph) return;
    const near = neighbourhood(graph, id, depth);
    view.setData(near.nodes, near.links);
    view.setSelected(id);
    view.autoFit();
  };

  const slider = h("input", { type: "range", min: "1", max: "3", step: "1", "aria-label": "Depth" }) as HTMLInputElement;
  slider.value = String(depth);
  const shown = h("output", {}, String(depth));
  slider.addEventListener("input", () => {
    depth = Number(slider.value);
    shown.textContent = String(depth);
    remember("local-depth", depth);
    show();
  });

  const holder = h("div", { class: "local-holder" });
  view.attach(holder);
  show();
  return h(
    "aside",
    { class: "local", "aria-label": "Local graph" },
    h("header", {}, h("h2", {}, "Local graph"), h("label", { class: "depth" }, "Depth ", slider, shown)),
    holder,
  );
}

// Routing

type Arrival = "push" | "start" | "reload";

async function route(arrival: Arrival = "push") {
  try {
    const path = location.pathname;
    const note = path.match(/^\/note\/(.+)$/);
    main.classList.toggle("full", !note && path !== "/overview");
    if (note) await renderNote(decodeURIComponent(note[1]));
    else if (path === "/overview") renderOverview();
    else renderGraph(arrival === "reload" ? null : new URLSearchParams(location.search).get("focus"));
    renderTree();
    renderNav();
    if (arrival === "push") {
      window.scrollTo(0, 0);
      main.focus({ preventScroll: true });
    }
  } catch (error) {
    showProblem(error);
  }
}

function renderNav() {
  for (const a of document.querySelectorAll<HTMLAnchorElement>(".views a")) {
    const here = new URL(a.href).pathname === location.pathname;
    if (here) a.setAttribute("aria-current", "page");
    else a.removeAttribute("aria-current");
  }
}

function go(href: string) {
  if (href !== location.pathname + location.search) history.pushState(null, "", href);
  $("sidebar").classList.remove("open");
  route();
}

const ROUTES = (path: string) => path === "/" || path === "/overview" || path.startsWith("/note/");

document.addEventListener("click", (event) => {
  const a = (event.target as Element).closest("a");
  if (!a || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey) return;
  const url = new URL(a.href, location.href);
  if (url.origin !== location.origin || !ROUTES(url.pathname)) return;
  event.preventDefault();
  go(url.pathname + url.search);
});

window.addEventListener("popstate", () => route());

// Dark by default; the switch's choice is remembered in this browser.
function setTheme(theme: "dark" | "light") {
  if (theme === "light") document.documentElement.dataset.theme = "light";
  else delete document.documentElement.dataset.theme;
  $("theme").setAttribute("aria-pressed", String(theme === "dark"));
  remember("theme", theme);
}
setTheme(recall<string>("theme", "dark") === "light" ? "light" : "dark");
$("theme").addEventListener("click", () =>
  setTheme(document.documentElement.dataset.theme === "light" ? "dark" : "light"),
);

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
  [overview, graph] = await Promise.all([get<Overview>("/api/vault"), get<GraphData>("/api/graph")]);
  renderSummary();
  if (globalView) {
    globalView.setData(graph.nodes, graph.links);
    applyFilters();
  }
  renderTools();
}

// tiny-axe writes notes as tasks finish; show them without a reload.
function listen() {
  const events = new EventSource("/api/events");
  events.addEventListener("vault", async () => {
    try {
      await load();
      if (search.value.trim()) await runSearch();
      await route("reload");
    } catch (error) {
      showProblem(error);
    }
  });
}

load()
  .then(() => route("start"))
  .then(listen)
  .catch(showProblem);
