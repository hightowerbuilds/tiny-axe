// The viewer's web server: the page, the vault as JSON, and a stream that
// says when the vault changed. It listens on 127.0.0.1 only, answers only
// requests addressed to it by that name (so another site can't reach it
// through DNS tricks), and only for someone who opened the address with this
// run's token.

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { watch, type FSWatcher } from "node:fs";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { FOLDERS } from "./format.ts";
import { loadVault, type Vault, type VaultNote } from "./vault.ts";
import { graphView } from "./graph.ts";
import { renderer } from "./render.ts";

export interface Options {
  vault: string;
  /** Where the built page is (index.html, app.js, style.css). */
  web: string;
  port: number;
  /** Made fresh for each run unless given (tests give one). */
  token?: string;
}

export interface Running {
  url: string;
  port: number;
  token: string;
  close(): Promise<void>;
}

const HOST = "127.0.0.1";

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".map": "application/json",
  ".svg": "image/svg+xml",
};

const SECURITY_HEADERS = {
  "Content-Security-Policy":
    "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; " +
    "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Cross-Origin-Resource-Policy": "same-origin",
};

export async function start(options: Options): Promise<Running> {
  const token = options.token ?? randomBytes(24).toString("base64url");
  let vault = await loadVault(options.vault);
  let render = rendererFor(vault);
  const streams = new Set<ServerResponse>();
  let port = options.port;
  const cookie = () => `tiny_axe_graph_${port}`;

  const server = createServer((req, res) => {
    handle(req, res).catch((error) => {
      if (!res.headersSent) send(res, 500, "text/plain; charset=utf-8", `Something went wrong: ${error.message}\n`);
      else res.end();
    });
  });

  async function handle(req: IncomingMessage, res: ServerResponse) {
    const url = new URL(req.url ?? "/", `http://${HOST}`);

    if (req.headers.host !== `${HOST}:${port}` && req.headers.host !== `localhost:${port}`) {
      return send(res, 403, "text/plain; charset=utf-8", "This address isn't served here.\n");
    }
    if (req.method !== "GET" && req.method !== "HEAD") {
      return send(res, 405, "text/plain; charset=utf-8", "Read-only.\n");
    }

    // Opening the printed address swaps the token for a cookie, so it leaves
    // the address bar and history.
    const given = url.searchParams.get("t");
    if (given !== null) {
      if (!same(given, token)) return denied(res);
      url.searchParams.delete("t");
      res.writeHead(302, {
        ...SECURITY_HEADERS,
        "Set-Cookie": `${cookie()}=${token}; HttpOnly; SameSite=Strict; Path=/`,
        Location: url.pathname + url.search,
      });
      return res.end();
    }
    if (!same(cookies(req)[cookie()] ?? "", token)) return denied(res);

    const path = url.pathname;
    if (path === "/api/vault") return json(res, overview(vault));
    if (path === "/api/graph") return json(res, graphView(vault));
    if (path === "/api/note") {
      const note = vault.notes.get(url.searchParams.get("id") ?? "");
      return note ? json(res, detail(vault, note, render)) : json(res, { error: "no such note" }, 404);
    }
    if (path === "/api/search") return json(res, { results: search(vault, url.searchParams.get("q") ?? "") });
    if (path === "/api/events") return events(req, res);
    if (path === "/" || path === "/overview" || path.startsWith("/note/")) return file(res, options.web, "index.html");
    if (path.startsWith("/static/")) return file(res, options.web, path.slice("/static/".length));
    return send(res, 404, "text/plain; charset=utf-8", "Not found.\n");
  }

  function events(req: IncomingMessage, res: ServerResponse) {
    res.writeHead(200, {
      ...SECURITY_HEADERS,
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-store",
      Connection: "keep-alive",
    });
    res.write(": connected\n\n");
    streams.add(res);
    req.on("close", () => streams.delete(res));
  }

  // The writer replaces notes by renaming, often several at once: reload
  // once things settle, and keep the last good vault if a read fails.
  let timer: NodeJS.Timeout | undefined;
  const watcher: FSWatcher = watch(options.vault, { recursive: true }, () => {
    clearTimeout(timer);
    timer = setTimeout(async () => {
      try {
        vault = await loadVault(options.vault);
        render = rendererFor(vault);
        for (const res of streams) res.write("event: vault\ndata: {}\n\n");
      } catch (error) {
        console.error(`tiny-axe graph: couldn't reload the vault: ${(error as Error).message}`);
      }
    }, 150);
  });

  const keepalive = setInterval(() => {
    for (const res of streams) res.write(": still here\n\n");
  }, 25_000);

  // A port in use leaves nothing running behind (the MCP mode tries the next).
  try {
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(options.port, HOST, () => resolve());
    });
  } catch (error) {
    clearInterval(keepalive);
    watcher.close();
    throw error;
  }
  port = (server.address() as { port: number }).port;

  return {
    url: `http://${HOST}:${port}/?t=${token}`,
    port,
    token,
    close: async () => {
      clearTimeout(timer);
      clearInterval(keepalive);
      watcher.close();
      for (const res of streams) res.end();
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

function rendererFor(vault: Vault) {
  return renderer((id) => vault.notes.get(id));
}

// What the sidebar and the home page need.
function overview(vault: Vault) {
  const notes = [...vault.notes.values()];
  const count = (kind: string) => notes.filter((n) => n.kind === kind).length;
  const blocked = notes.filter((n) => n.kind === "path" && ["refused", "denied"].includes(String(prop(n, "gate"))));

  const folders = new Map<string, unknown[]>();
  for (const note of notes) {
    if (!folders.has(note.folder)) folders.set(note.folder, []);
    folders.get(note.folder)!.push(entry(note));
  }

  return {
    schema: vault.manifest.schema,
    summary: {
      sites: count("site"),
      pages: count("page"),
      controls: count("control"),
      paths: count("path"),
      blocked: blocked.length,
      tools: count("tool"),
      tasks: count("task"),
    },
    // In the vault's own order (sites first), skipping empty folders.
    folders: Object.values(FOLDERS)
      .filter((name) => folders.has(name))
      .map((name) => ({ name, notes: folders.get(name)! })),
  };
}

function entry(note: VaultNote) {
  return {
    id: note.id,
    title: note.title,
    kind: note.kind,
    trust: note.trust,
    gate: prop(note, "gate") ?? null,
    seen: prop(note, "seen") ?? null,
    last_seen: prop(note, "last_seen") ?? prop(note, "started") ?? null,
  };
}

function detail(vault: Vault, note: VaultNote, render: (md: string) => string) {
  // Values that name another note (a site's key, a task id) become links.
  const refs: Record<string, { id: string; title: string; kind: string }> = {};
  for (const [, value] of note.props) {
    for (const v of Array.isArray(value) ? value : [value]) {
      const id = typeof v === "string" ? vault.byKey.get(v) : undefined;
      const target = id && id !== note.id ? vault.notes.get(id) : undefined;
      if (target) refs[v as string] = { id: target.id, title: target.title, kind: target.kind };
    }
  }

  const grouped = new Map<string, unknown[]>();
  for (const id of vault.backlinks.get(note.id) ?? []) {
    const from = vault.notes.get(id);
    if (!from) continue;
    if (!grouped.has(from.folder)) grouped.set(from.folder, []);
    grouped.get(from.folder)!.push(entry(from));
  }

  return {
    ...entry(note),
    folder: note.folder,
    props: note.props,
    refs,
    html: render(note.body),
    links: note.links.filter((id) => vault.notes.has(id)),
    backlinks: [...grouped].map(([folder, notes]) => ({ folder, notes })),
  };
}

function search(vault: Vault, query: string) {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return [];

  const results = [];
  for (const note of vault.notes.values()) {
    const title = note.title.toLowerCase();
    const text = plain(note.body);
    const lower = text.toLowerCase();
    if (!words.every((w) => title.includes(w) || lower.includes(w))) continue;

    const inTitle = words.every((w) => title.includes(w));
    results.push({ ...entry(note), folder: note.folder, snippet: snippet(text, words), inTitle });
  }

  return results.sort((a, b) => Number(b.inTitle) - Number(a.inTitle)).slice(0, 50);
}

// Up to ~120 characters of the body around the first word it contains (or
// its start), cut at spaces.
function snippet(text: string, words: string[]): string {
  const lower = text.toLowerCase();
  const hits = words.map((w) => lower.indexOf(w)).filter((i) => i >= 0);
  const at = hits.length > 0 ? Math.min(...hits) : 0;
  let from = Math.max(0, at - 40);
  if (from > 0) {
    const space = text.indexOf(" ", from);
    from = space >= 0 && space < at ? space + 1 : at;
  }
  let to = Math.min(text.length, from + 120);
  if (to < text.length) to = text.lastIndexOf(" ", to) > at ? text.lastIndexOf(" ", to) : to;
  return (from > 0 ? "…" : "") + text.slice(from, to).trim() + (to < text.length ? "…" : "");
}

// A body as plain text, without its title: link aliases kept, markup and
// escapes dropped.
function plain(body: string): string {
  return body
    .replace(/^\s*# .*\n/, "")
    .replace(/\[\[[^\[\]|\n]+\|([^\[\]\n]*)\]\]/g, "$1")
    .replace(/\[\[([^\[\]|\n]+)\]\]/g, "$1")
    .replace(/\\(.)/g, "$1")
    .replace(/^#+ |^\d+\. |^- |\|/gm, " ")
    .replace(/\s+/g, " ");
}

function prop(note: VaultNote, name: string) {
  return note.props.find(([n]) => n === name)?.[1];
}

async function file(res: ServerResponse, root: string, name: string) {
  const path = normalize(join(root, name));
  if (!path.startsWith(normalize(root) + "/")) return send(res, 404, "text/plain; charset=utf-8", "Not found.\n");

  try {
    const body = await readFile(path);
    send(res, 200, TYPES[extname(path)] ?? "application/octet-stream", body);
  } catch {
    const hint = name === "index.html" ? " The page hasn't been built: run `npm run build` in graph/." : "";
    send(res, 404, "text/plain; charset=utf-8", `Not found.${hint}\n`);
  }
}

function json(res: ServerResponse, value: unknown, status = 200) {
  send(res, status, "application/json; charset=utf-8", JSON.stringify(value));
}

function send(res: ServerResponse, status: number, type: string, body: string | Buffer) {
  res.writeHead(status, { ...SECURITY_HEADERS, "Content-Type": type, "Cache-Control": "no-store" });
  res.end(res.req.method === "HEAD" ? undefined : body);
}

function denied(res: ServerResponse) {
  send(
    res,
    401,
    "text/plain; charset=utf-8",
    "Open the full address `tiny-axe graph` printed; it includes the key for this run (?t=…).\n",
  );
}

function cookies(req: IncomingMessage): Record<string, string> {
  const out: Record<string, string> = {};
  for (const part of (req.headers.cookie ?? "").split(";")) {
    const at = part.indexOf("=");
    if (at > 0) out[part.slice(0, at).trim()] = part.slice(at + 1).trim();
  }
  return out;
}

function same(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}
