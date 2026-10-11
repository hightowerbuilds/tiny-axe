// The chat history as the viewer serves it, from a folder of chat files
// like the ones TinyAxe.History writes: grouped and searched, one at a time
// with nothing in a chat becoming markup, never what reopening it gives the
// model, and pushed to open pages as tiny-axe writes.

import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { request, type IncomingMessage } from "node:http";
import { cp, mkdir, mkdtemp, rename, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { start, type Running } from "../src/server.ts";

const fixture = join(import.meta.dirname, "../../test/fixtures/vault/vault");
const web = join(import.meta.dirname, "../dist/web");
const TOKEN = "test-token-0123456789";
const SECRET = "only-the-model-sees-this";

const OLD = "20261010-090000-aaaa";
const NEW = "20261011-150000-bbbb";

function chat(id: string, session: string, entries: [string, string][], extra: Record<string, unknown> = {}) {
  return {
    version: 1,
    id,
    session,
    started: `${id.slice(0, 4)}-${id.slice(4, 6)}-${id.slice(6, 8)}T${id.slice(9, 11)}:${id.slice(11, 13)}:${id.slice(13, 15)}Z`,
    updated: `${id.slice(0, 4)}-${id.slice(4, 6)}-${id.slice(6, 8)}T23:00:00Z`,
    title: entries[0][1].split("\n")[0].slice(0, 80),
    folder: "~/Desktop/Projects",
    entries: entries.map(([kind, text]) => ({ kind, text })),
    context: { history: [{ role: "user", content: SECRET }], summary: { text: SECRET, turns: 2 } },
    ...extra,
  };
}

const CHATS = [
  chat("20261010-090105-0001", OLD, [
    ["user", "how much free space do I have?"],
    ["meta", '🔧 shell_run {"command":"df -h"} (only reads)'],
    ["assistant", "You have **105G** free on `/`."],
  ]),
  chat(
    "20261010-091500-0002",
    OLD,
    [
      ["user", "tidy my downloads"],
      ["assistant", "Moved 12 files into folders by type."],
    ],
    { updated: "2026-10-11T08:00:00Z" },
  ),
  chat("20261011-150210-0003", NEW, [
    ["user", "<img src=x onerror=alert(1)> what does\nthis do?"],
    ["meta", "<b>not bold</b>"],
    ["assistant", "```js\nconsole.log('<script>')\n```\n\n[click](javascript:alert(1)) and [docs](https://example.com/docs) ![pixel](http://evil.example/p.png)"],
  ]),
];

let running: Running;
let folder: string;

before(async () => {
  const vault = await mkdtemp(join(tmpdir(), "vault-"));
  await cp(fixture, vault, { recursive: true });
  const state = await mkdtemp(join(tmpdir(), "state-"));
  folder = join(state, "history");
  await mkdir(folder);
  for (const c of CHATS) await writeFile(join(folder, `${c.id}.json`), JSON.stringify(c));

  // What isn't a chat this viewer reads is left out.
  await writeFile(join(folder, "20261011-160000-0004.json"), "{not json");
  await writeFile(join(folder, "20261011-160000-0005.json"), JSON.stringify({ ...chat("20261011-160000-0005", NEW, [["user", "v2"]]), version: 2 }));
  await writeFile(join(folder, "20261011-160000-0006.json"), JSON.stringify(chat("20261011-160000-0099", NEW, [["user", "renamed"]])));
  await writeFile(join(folder, "20261011-160000-0007.json.tmp"), JSON.stringify(chat("20261011-160000-0007", NEW, [["user", "half"]])));
  await writeFile(join(folder, "notes.json"), JSON.stringify(chat("notes", NEW, [["user", "notes"]])));
  // And nothing outside the folder can be asked for.
  await writeFile(join(state, "outside.json"), JSON.stringify(chat("outside", NEW, [["user", "outside"]])));

  running = await start({ vault, history: folder, web, port: 0, token: TOKEN });
});

after(() => running.close());

interface Reply {
  status: number;
  body: string;
}

function get(path: string, { cookie = true, server = running } = {}): Promise<Reply> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = { Host: `127.0.0.1:${server.port}` };
    if (cookie) headers.Cookie = `tiny_axe_graph_${server.port}=${TOKEN}`;
    const req = request({ host: "127.0.0.1", port: server.port, path, headers }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => (body += chunk));
      res.on("end", () => resolve({ status: res.statusCode!, body }));
    });
    req.on("error", reject);
    req.end();
  });
}

const api = async (path: string, server = running) => {
  const reply = await get(path, { server });
  assert.equal(reply.status, 200, reply.body);
  assert.doesNotMatch(reply.body, new RegExp(SECRET));
  assert.doesNotMatch(reply.body, /"context"/);
  return JSON.parse(reply.body);
};

// An open page's event stream, and the next `history` event on it.
async function stream(server = running) {
  const events = await new Promise<IncomingMessage>((resolve, reject) => {
    request(
      {
        host: "127.0.0.1",
        port: server.port,
        path: "/api/events",
        headers: { Host: `127.0.0.1:${server.port}`, Cookie: `tiny_axe_graph_${server.port}=${TOKEN}` },
      },
      resolve,
    )
      .on("error", reject)
      .end();
  });
  events.setEncoding("utf8");
  const next = () =>
    new Promise<string[]>((resolve) => {
      const seen = (chunk: string) => {
        const at = chunk.indexOf("event: history\ndata: ");
        if (at < 0) return;
        events.off("data", seen);
        resolve(JSON.parse(chunk.slice(at).split("\n")[1].slice("data: ".length)).changed);
      };
      events.on("data", seen);
    });
  return { next, close: () => events.destroy() };
}

// Written the way the writer writes: a temporary name, then renamed.
async function save(dir: string, c: ReturnType<typeof chat>) {
  await writeFile(join(dir, `${c.id}.json.tmp`), JSON.stringify(c));
  await rename(join(dir, `${c.id}.json.tmp`), join(dir, `${c.id}.json`));
}

const ids = (list: { sessions: { id: string; chats: { id: string }[] }[] }) =>
  list.sessions.map((s) => [s.id, s.chats.map((c) => c.id)]);

test("without the token, no chat is served", async () => {
  for (const path of ["/api/chats", "/api/chats?q=free", "/api/chat?id=20261010-090105-0001", "/chats", "/chats/20261010-090105-0001"]) {
    const reply = await get(path, { cookie: false });
    assert.equal(reply.status, 401, path);
    assert.doesNotMatch(reply.body, /free space/);
  }
});

test("the chat pages are the page", async () => {
  for (const path of ["/chats", "/chats/20261010-090105-0001"]) {
    const reply = await get(path);
    assert.equal(reply.status, 200);
    assert.match(reply.body, /<script type="module" src="\/static\/app.js">/);
  }
});

test("chats come grouped by session, newest first, without what isn't a chat", async () => {
  const list = await api("/api/chats");
  assert.equal(list.total, 3);
  assert.deepEqual(ids(list), [
    [NEW, ["20261011-150210-0003"]],
    [OLD, ["20261010-091500-0002", "20261010-090105-0001"]],
  ]);
  assert.equal(list.sessions[1].started, "2026-10-10T09:00:00Z");
  assert.deepEqual(list.sessions[1].chats[0], {
    id: "20261010-091500-0002",
    title: "tidy my downloads",
    started: "2026-10-10T09:15:00Z",
    updated: "2026-10-11T08:00:00Z",
    folder: "~/Desktop/Projects",
    messages: 2,
  });
  assert.equal(list.sessions[1].chats[1].messages, 2);
});

test("search keeps the chats with every word, each with a snippet", async () => {
  const free = await api("/api/chats?q=FREE%20space");
  assert.equal(free.total, 3);
  assert.deepEqual(ids(free), [[OLD, ["20261010-090105-0001"]]]);
  assert.equal(free.sessions[0].chats[0].snippet, "how much free space do I have?");

  // Markdown's marks don't get in the way, and the words can be in different messages.
  const marked = await api("/api/chats?q=105g%20downloads");
  assert.deepEqual(ids(marked), []);
  assert.equal((await api("/api/chats?q=105g")).sessions[0].chats[0].snippet, "You have 105G free on /.");
  assert.equal((await api("/api/chats?q=tidy%20folders")).sessions[0].chats[0].snippet, "tidy my downloads");
  assert.equal((await api("/api/chats?q=df")).sessions[0].chats[0].snippet, '🔧 shell_run {"command":"df -h"} (only reads)');

  assert.deepEqual((await api("/api/chats?q=zzzz-nothing")).sessions, []);
  // What only the model sees isn't searched either.
  assert.deepEqual((await api(`/api/chats?q=${SECRET}`)).sessions, []);
  assert.deepEqual(ids(await api("/api/chats?q=%20")), ids(await api("/api/chats")));
});

test("a chat comes with its messages as HTML and its activity as text", async () => {
  const one = await api("/api/chat?id=20261010-090105-0001");
  assert.deepEqual(Object.keys(one), ["id", "session", "title", "started", "updated", "folder", "entries"]);
  assert.equal(one.session, OLD);
  assert.deepEqual(one.entries, [
    { kind: "user", text: "how much free space do I have?", html: "<p>how much free space do I have?</p>\n" },
    { kind: "meta", text: '🔧 shell_run {"command":"df -h"} (only reads)' },
    { kind: "assistant", text: "You have **105G** free on `/`.", html: "<p>You have <strong>105G</strong> free on <code>/</code>.</p>\n" },
  ]);
});

test("nothing in a chat becomes markup or loads anything", async () => {
  const { entries } = await api("/api/chat?id=20261011-150210-0003");
  const [user, meta, assistant] = entries;
  assert.equal(user.html, "<p>&lt;img src=x onerror=alert(1)&gt; what does<br>this do?</p>\n");
  assert.equal(meta.html, undefined);
  assert.equal(meta.text, "<b>not bold</b>");
  assert.doesNotMatch(assistant.html, /<img|<script|javascript:/);
  assert.match(assistant.html, /<pre><code class="language-js">console.log\(&#39;&lt;script&gt;&#39;\)\n<\/code><\/pre>/);
  assert.match(assistant.html, /click and <a class="external" href="https:\/\/example.com\/docs" rel="noopener noreferrer" target="_blank">docs<\/a> pixel/);
});

test("only a chat id names a chat", async () => {
  for (const id of [
    "",
    "../outside",
    "..%2Foutside",
    "notes",
    "20261011-160000-0007.json.tmp",
    "20261010-090105-0001.json",
    "20261010-090105-000G",
    "20261010-090105-0001/../20261010-090105-0001",
    `${folder}/20261010-090105-0001`,
    // Files that look like chats but aren't ones this viewer reads.
    "20261011-160000-0004",
    "20261011-160000-0005",
    "20261011-160000-0006",
    "20261011-160000-0099",
    // Well formed, but not there.
    "20261011-160000-ffff",
  ]) {
    const reply = await get(`/api/chat?id=${encodeURIComponent(id)}`);
    assert.equal(reply.status, 404, id);
    assert.deepEqual(JSON.parse(reply.body), { error: "There's no such chat in the history." });
  }
});

test("a chat written to the history is pushed to open pages, by id", async () => {
  const events = await stream();
  const pushed = events.next();
  await save(folder, chat("20261011-170000-0008", NEW, [["user", "a brand new chat"]]));
  assert.deepEqual(await pushed, ["20261011-170000-0008"]);

  // Written again, it's announced again, and read again.
  const again = events.next();
  await save(folder, chat("20261011-170000-0008", NEW, [["user", "a brand new chat"], ["assistant", "and its reply"]]));
  assert.deepEqual(await again, ["20261011-170000-0008"]);
  events.close();

  assert.deepEqual(ids(await api("/api/chats"))[0], [NEW, ["20261011-170000-0008", "20261011-150210-0003"]]);
  assert.equal((await api("/api/chat?id=20261011-170000-0008")).entries.length, 2);
});

test("a history that isn't there yet has no chats, until it is", async () => {
  const vault = await mkdtemp(join(tmpdir(), "vault-"));
  await cp(fixture, vault, { recursive: true });
  const missing = join(await mkdtemp(join(tmpdir(), "state-")), "history");
  const server = await start({ vault, history: missing, web, port: 0, token: TOKEN });
  try {
    assert.deepEqual(await api("/api/chats", server), { total: 0, sessions: [] });
    assert.equal((await get("/api/chat?id=20261010-090105-0001", { server })).status, 404);

    // tiny-axe saves its first chat: the page hears of it within a few seconds.
    const events = await stream(server);
    const pushed = events.next();
    await mkdir(missing);
    await save(missing, CHATS[0]);
    assert.deepEqual(await pushed, ["20261010-090105-0001"]);
    events.close();
    assert.equal((await api("/api/chats", server)).total, 1);
  } finally {
    await server.close();
  }
});

test("without a history folder there are no chats", async () => {
  const vault = await mkdtemp(join(tmpdir(), "vault-"));
  await cp(fixture, vault, { recursive: true });
  const server = await start({ vault, web, port: 0, token: TOKEN });
  try {
    assert.deepEqual(await api("/api/chats", server), { total: 0, sessions: [] });
    assert.equal((await get("/api/chat?id=20261010-090105-0001", { server })).status, 404);
  } finally {
    await server.close();
  }
});
