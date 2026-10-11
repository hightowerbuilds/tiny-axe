// The graph (home): every note, with filters and a 2D/3D switch; and a
// note's local graph, the notes within 1–3 links of it. The Three.js views
// (graph.ts) live as long as the page and are fed from the store; notes
// tiny-axe just wrote glow.

import { createEffect, createMemo, createSignal, For, on, onMount, Show, type JSX } from "solid-js";
import { choices, isFiltered, neighbourhood, NO_FILTERS, visibleMask, type Filters } from "./filter.ts";
import { GraphView, type Dims } from "./graph.ts";
import { changes, go, graph, href, noteHref, recall, remember, route } from "./store.ts";

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

const [dims, setDimsTo] = createSignal<Dims>(recall<number>("graph-dims", 2) === 3 ? 3 : 2);
const [filters, setFilters] = createSignal<Filters>({ ...NO_FILTERS, ...recall<Partial<Filters>>("graph-filters", {}) });
const [moving, setMoving] = createSignal(false);
const [depth, setDepth] = createSignal(Math.min(3, Math.max(1, recall<number>("local-depth", 1))));

let globalView: GraphView | null = null;
let localView: GraphView | null = null;

function setDims(next: Dims) {
  setDimsTo(next);
  remember("graph-dims", next);
  globalView?.setDims(next);
  localView?.setDims(next);
}

export function GraphPage() {
  globalView ??= new GraphView({
    label: "A graph of every note and its links. The sidebar lists the same notes.",
    background: "--bg",
    open: (id) => go(noteHref(id)),
    status: setMoving,
  });
  const view = globalView;
  view.setDims(dims());
  document.title = "tiny-axe know-how";

  const mask = createMemo(() => {
    const g = graph();
    return g ? visibleMask(g, filters()) : new Uint8Array(0);
  });

  let holder!: HTMLDivElement;
  onMount(() => view.attach(holder));

  // New data first, then what the filters leave showing (both skip work
  // when nothing they care about changed).
  createEffect(() => {
    const g = graph();
    if (!g) return;
    view.setData(g.nodes, g.links);
    view.setVisible(mask());
  });
  createEffect(on(changes, (c) => view.glow(c.ids), { defer: true }));
  createEffect(on(filters, (f) => remember("graph-filters", f), { defer: true }));
  // Arriving at /?focus=ID flies to that note; new data never moves the camera.
  createEffect(
    on(href, () => {
      const r = route();
      if (r.kind !== "graph") return;
      if (r.focus) view.focus(r.focus);
      else view.setSelected(null);
    }),
  );

  const status = () => {
    const g = graph();
    if (!g) return "";
    const m = mask();
    const shown = m.reduce((a, b) => a + b, 0);
    const lines = g.links.filter(([a, b]) => m[a] && m[b]).length;
    const notes = shown === g.nodes.length ? `${shown} notes` : `${shown} of ${g.nodes.length} notes`;
    return `${notes} · ${lines} links${moving() ? " · laying out…" : ""}`;
  };

  return (
    <section class="graph-page" aria-label="Graph">
      <div class="graph-holder" ref={holder} />
      <div class="graph-tools">
        <div class="row">
          <div class="mode" role="group" aria-label="Layout">
            <For each={[2, 3] as const}>
              {(d) => (
                <button type="button" value={String(d)} aria-pressed={dims() === d} onClick={() => setDims(d)}>
                  {d}D
                </button>
              )}
            </For>
          </div>
          <button type="button" class="fit" title="Bring every note into view" onClick={() => view.fit(true)}>
            Fit
          </button>
        </div>
        <Show when={graph()}>
          <FilterPanel />
        </Show>
      </div>
      <p class="graph-status" aria-live="polite">
        {status()}
      </p>
    </section>
  );
}

// The filters. Every control shows the current filters, so clearing them or
// new notes arriving never rebuilds the panel or moves focus.
function FilterPanel() {
  const c = createMemo(() => choices(graph()!));
  const count = (kind: string) => graph()!.nodes.filter((n) => n.kind === kind).length;
  const change = (patch: Partial<Filters>) => setFilters((f) => ({ ...f, ...patch }));
  const hideIn = (list: "hideKinds" | "hideTrust" | "hideClasses", value: string) => (on: boolean) =>
    setFilters((f) => ({ ...f, [list]: on ? f[list].filter((v) => v !== value) : [...f[list], value] }));

  return (
    <details class="filters" open={recall("filters-open", false)} on:toggle={(e) => remember("filters-open", e.currentTarget.open)}>
      <summary>
        Filters <span class="on">{isFiltered(filters()) ? "on" : ""}</span>
      </summary>
      <fieldset>
        <legend>Notes</legend>
        <For each={c().kinds}>
          {(k) => (
            <Check checked={!filters().hideKinds.includes(k)} change={hideIn("hideKinds", k)}>
              <span class="with-dot">
                <span class={`dot ${k}`} aria-hidden="true" />
                {KINDS[k] ?? k} <span class="count">{count(k)}</span>
              </span>
            </Check>
          )}
        </For>
      </fieldset>
      <fieldset>
        <legend>Trust</legend>
        <For each={TRUST.filter((t) => c().trust.includes(t))}>
          {(t) => (
            <Check checked={!filters().hideTrust.includes(t)} change={hideIn("hideTrust", t)}>
              <span class="with-dot">
                <span class={`dot ring ${t}`} aria-hidden="true" />
                {t}
              </span>
            </Check>
          )}
        </For>
      </fieldset>
      <Show when={c().classes.length > 0}>
        <fieldset>
          <legend>Policy class (paths)</legend>
          <For each={c().classes}>
            {(v) => (
              <Check checked={!filters().hideClasses.includes(v)} change={hideIn("hideClasses", v)}>
                {v}
              </Check>
            )}
          </For>
        </fieldset>
      </Show>
      <fieldset>
        <legend>Where and who</legend>
        <Show when={c().sites.length > 0}>
          <Choice label="Site" values={c().sites} current={filters().site} all="All sites" change={(site) => change({ site })} />
        </Show>
        <Show when={c().drivers.length > 0}>
          <Choice label="Driver" values={c().drivers} current={filters().driver} all="Any driver" change={(driver) => change({ driver })} />
        </Show>
      </fieldset>
      <fieldset>
        <legend>Seen</legend>
        <DateField label="From" current={filters().from} change={(from) => change({ from })} />
        <DateField label="To" current={filters().to} change={(to) => change({ to })} />
      </fieldset>
      <Check checked={filters().hideOrphans} change={(hideOrphans) => change({ hideOrphans })}>
        Hide notes with no links shown
      </Check>
      <button type="button" class="reset" disabled={!isFiltered(filters())} onClick={() => setFilters({ ...NO_FILTERS })}>
        Clear filters
      </button>
    </details>
  );
}

function Check(props: { checked: boolean; change: (on: boolean) => void; children: JSX.Element }) {
  return (
    <label class="check">
      <input type="checkbox" checked={props.checked} onChange={(e) => props.change(e.currentTarget.checked)} />
      {props.children}
    </label>
  );
}

function Choice(props: { label: string; values: string[]; current: string | null; all: string; change: (v: string | null) => void }) {
  return (
    <label class="field">
      <span>{props.label}</span>
      <select onChange={(e) => props.change(e.currentTarget.value || null)}>
        <option value="" selected={props.current === null}>
          {props.all}
        </option>
        <For each={props.values}>
          {(v) => (
            <option value={v} selected={props.current === v}>
              {v}
            </option>
          )}
        </For>
      </select>
    </label>
  );
}

function DateField(props: { label: string; current: string | null; change: (v: string | null) => void }) {
  return (
    <label class="field">
      <span>{props.label}</span>
      <input type="date" value={props.current ?? ""} onChange={(e) => props.change(e.currentTarget.value || null)} />
    </label>
  );
}

/** A note's local graph: the notes within 1–3 links of it. */
export function LocalGraph(props: { id: string }) {
  localView ??= new GraphView({
    label: "A graph of the notes linked to this one. They're listed in the note and under Linked from.",
    background: "--panel",
    open: (next) => go(noteHref(next)),
  });
  const view = localView;
  view.setDims(dims());

  let holder!: HTMLDivElement;
  onMount(() => view.attach(holder));

  // Another note or depth fits the view to it; new data alone doesn't.
  let fitted = "";
  createEffect(() => {
    const g = graph();
    if (!g) return;
    const near = neighbourhood(g, props.id, depth());
    view.setData(near.nodes, near.links);
    view.setSelected(props.id);
    const now = `${props.id}\n${depth()}`;
    if (now !== fitted) {
      fitted = now;
      view.autoFit();
    }
  });
  createEffect(on(changes, (c) => view.glow(c.ids), { defer: true }));

  return (
    <aside class="local" aria-label="Local graph">
      <header>
        <h2>Local graph</h2>
        <label class="depth">
          Depth{" "}
          <input
            type="range"
            min="1"
            max="3"
            step="1"
            aria-label="Depth"
            value={depth()}
            onInput={(e) => {
              setDepth(Number(e.currentTarget.value));
              remember("local-depth", depth());
            }}
          />
          <output>{depth()}</output>
        </label>
      </header>
      <div class="local-holder" ref={holder} />
    </aside>
  );
}
