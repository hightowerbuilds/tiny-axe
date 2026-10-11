// The overview and a note, with the sidebar's list items. Text from notes
// always goes in as text; the only HTML inserted is a note body the server
// rendered (render.ts).

import { createEffect, createResource, createSignal, For, Match, on, Show, Switch, type JSX } from "solid-js";
import { LocalGraph } from "./graph-page.tsx";
import {
  blocked,
  byTitle,
  changes,
  get,
  graphHref,
  noteHref,
  ORDER,
  overview,
  route,
  sorted,
  touches,
  type Entry,
  type NoteDetail,
  type Value,
} from "./store.ts";

export function Dot(props: { entry: { kind: string; trust: string; gate?: string | null } }) {
  return <span class={`dot ${props.entry.kind} ${props.entry.trust}${blocked(props.entry) ? " blocked" : ""}`} aria-hidden="true" />;
}

export function Item(props: { entry: Entry; children?: JSX.Element }) {
  const here = () => {
    const r = route();
    return r.kind === "note" && r.id === props.entry.id;
  };
  return (
    <a class="item" href={noteHref(props.entry.id)} title={props.entry.title} aria-current={here() ? "page" : undefined}>
      <Dot entry={props.entry} />
      <span class="label">{props.entry.title}</span>
      {props.children}
    </a>
  );
}

function List(props: { entries: Entry[]; meta: (e: Entry) => string; empty: string }) {
  return (
    <Show when={props.entries.length > 0} fallback={<p class="empty">{props.empty}</p>}>
      <ul>
        <For each={props.entries}>
          {(e) => (
            <li>
              <Item entry={e}>
                <span class="meta">{props.meta(e)}</span>
              </Item>
            </li>
          )}
        </For>
      </ul>
    </Show>
  );
}

export function OverviewPage() {
  document.title = "Overview · tiny-axe know-how";
  const notes = (folder: string) => overview.folders.find((f) => f.name === folder)?.notes ?? [];
  const s = () => overview.summary!;

  return (
    <div class="home">
      <h1>What tiny-axe knows</h1>
      <p class="lede">
        Every site, page and decision path tiny-axe has used on the web, from its own records. <a href="/">Open the graph</a>.
      </p>
      <Show when={overview.summary}>
        <div class="tiles">
          <Tile n={s().sites} what="sites" />
          <Tile n={s().pages} what="pages" />
          <Tile n={s().paths} what="decision paths" sub={s().blocked ? `${s().blocked} stopped by the gate` : undefined} />
          <Tile n={s().tools} what="tools" />
          <Tile n={s().tasks} what="tasks" />
        </div>
      </Show>
      <h2>Sites</h2>
      <List entries={[...notes("Sites")].sort((a, b) => (b.seen ?? 0) - (a.seen ?? 0))} meta={(e) => `${e.seen ?? 0} actions`} empty="No sites yet." />
      <h2>Recent tasks</h2>
      <List entries={[...notes("Tasks")].sort(ORDER.Tasks).slice(0, 10)} meta={(e) => e.last_seen?.slice(0, 10) ?? ""} empty="No tasks yet." />
      <h2>Where the gate stopped it</h2>
      <List entries={notes("Paths").filter(blocked).sort(byTitle)} meta={(e) => e.gate ?? ""} empty="Nothing stopped yet." />
    </div>
  );
}

function Tile(props: { n: number; what: string; sub?: string }) {
  return (
    <div class="tile">
      <div class="n">{props.n}</div>
      <div class="what">{props.what}</div>
      <Show when={props.sub}>
        <div class="sub">{props.sub}</div>
      </Show>
    </div>
  );
}

/** A note, fetched again whenever tiny-axe changes it or a note linked to it. */
export function NotePage(props: { id: string }) {
  const [stamp, setStamp] = createSignal(0);
  createEffect(on(changes, (c) => touches(props.id, c.ids) && setStamp((n) => n + 1), { defer: true }));
  const [note] = createResource(
    () => [props.id, stamp()] as const,
    ([id]) => get<NoteDetail>(`/api/note?id=${encodeURIComponent(id)}`),
  );
  createEffect(() => {
    if (!note.error && note.latest) document.title = `${note.latest.title} · tiny-axe know-how`;
  });

  return (
    <Switch>
      <Match when={note.error}>{(error) => <p class="problem">{(error() as Error).message}</p>}</Match>
      <Match when={note.latest}>
        {(n) => (
          <div class="note-page">
            <article class="note">
              <div class="crumbs">
                <span>{n().folder}</span>
                <a class="button" href={graphHref(n().id)}>
                  Show in graph
                </a>
              </div>
              <div class="badges">
                <span class="badge">{n().kind}</span>
                <span class={`badge trust-${n().trust}`}>{n().trust}</span>
                <Show when={n().gate}>
                  <span class={`badge${blocked(n()) ? " blocked" : ""}`}>gate: {n().gate}</span>
                </Show>
              </div>
              <Body note={n()} />
              <Show when={n().backlinks.length > 0}>
                <section class="backlinks">
                  <h2>Linked from</h2>
                  <For each={n().backlinks}>
                    {(group) => (
                      <>
                        <h3>{group.folder}</h3>
                        <ul>
                          <For each={sorted(group.folder, group.notes)}>
                            {(e) => (
                              <li>
                                <Item entry={e} />
                              </li>
                            )}
                          </For>
                        </ul>
                      </>
                    )}
                  </For>
                </section>
              </Show>
            </article>
            <LocalGraph id={props.id} />
          </div>
        )}
      </Match>
    </Switch>
  );
}

// The server's HTML for the body, with the properties under its title, as
// Obsidian shows them. The properties stay open or closed across updates.
function Body(props: { note: NoteDetail }) {
  let body!: HTMLDivElement;
  const details = (
    <details class="props">
      <summary>Properties</summary>
      <dl>
        <For each={props.note.props.filter(([name]) => !["kind", "title"].includes(name))}>
          {([name, value]) => (
            <>
              <dt>{name}</dt>
              <dd>
                <PropValue value={value} refs={props.note.refs} />
              </dd>
            </>
          )}
        </For>
      </dl>
    </details>
  ) as HTMLDetailsElement;

  createEffect(() => {
    body.innerHTML = props.note.html;
    const title = body.querySelector("h1");
    if (title) title.after(details);
    else body.prepend(details);
  });
  return <div class="body" ref={body} />;
}

function PropValue(props: { value: Value; refs: NoteDetail["refs"] }) {
  const one = (v: string) => {
    const ref = props.refs[v];
    return ref ? <a href={noteHref(ref.id)}>{ref.title}</a> : v;
  };
  return (
    <Switch fallback={<>{String(props.value)}</>}>
      <Match when={props.value === null || (Array.isArray(props.value) && props.value.length === 0)}>
        <span class="null">none</span>
      </Match>
      <Match when={Array.isArray(props.value) && props.value}>
        {(list) => (
          <span>
            <For each={list()}>{(v) => <span class="chip">{one(v)}</span>}</For>
          </span>
        )}
      </Match>
      <Match when={typeof props.value === "string" && props.value}>{(v) => one(v())}</Match>
    </Switch>
  );
}
