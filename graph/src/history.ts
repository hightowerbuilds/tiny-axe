// Reads tiny-axe's chat history: one JSON file per chat in its state folder
// (docs/plan-history.md). TinyAxe.History writes them; the viewer only reads.
// The folder may not exist yet, and a file that can't be read or isn't a
// chat is left out rather than failing the rest. What reopening a chat gives
// the model (`context`) is dropped as each file is read, so it's never sent.

import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { compare } from "./vault.ts";

/** The time a chat (or a session) started, UTC, and four hex digits. */
export const CHAT_ID = /^\d{8}-\d{6}-[0-9a-f]{4}$/;

const VERSION = 1;
const KINDS = new Set(["user", "assistant", "meta"]);

export interface ChatEntry {
  kind: "user" | "assistant" | "meta";
  text: string;
}

export interface Chat {
  id: string;
  session: string;
  title: string;
  started: string;
  updated: string;
  folder: string;
  entries: ChatEntry[];
}

export interface History {
  /** Every chat that can be read. */
  all(): Promise<Chat[]>;
  /** One chat, or null if `id` isn't a chat id or there's no such chat. */
  one(id: string): Promise<Chat | null>;
}

/** A chat's id from a name the watcher reports, or null for anything else
 * (the writer's temporary files). */
export function chatId(file: string): string | null {
  const id = file.endsWith(".json") ? file.slice(0, -5) : "";
  return CHAT_ID.test(id) ? id : null;
}

/** A session's start, from its id; null if the id isn't one. */
export function sessionStart(session: string): string | null {
  const m = /^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-[0-9a-f]{4}$/.exec(session);
  return m ? `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}Z` : null;
}

// Files are read again only when they change, so listing and searching a
// long history doesn't read all of it each time. Without a folder there are
// no chats.
export function history(folder: string | undefined): History {
  if (!folder) return { all: async () => [], one: async () => null };
  const dir = folder;
  const cache = new Map<string, { mtime: number; size: number; chat: Chat | null }>();

  async function load(id: string): Promise<Chat | null> {
    const path = join(dir, `${id}.json`);
    try {
      const { mtimeMs, size } = await stat(path);
      const known = cache.get(id);
      if (known && known.mtime === mtimeMs && known.size === size) return known.chat;
      const chat = parse(id, await readFile(path, "utf8"));
      cache.set(id, { mtime: mtimeMs, size, chat });
      return chat;
    } catch {
      cache.delete(id);
      return null;
    }
  }

  return {
    async all() {
      const files = await readdir(dir).catch(() => [] as string[]);
      const ids = files.map(chatId).filter((id) => id !== null);
      const present = new Set(ids);
      for (const id of cache.keys()) if (!present.has(id)) cache.delete(id);
      const chats = await Promise.all(ids.sort(compare).map(load));
      return chats.filter((c) => c !== null);
    },
    one: (id) => (CHAT_ID.test(id) ? load(id) : Promise.resolve(null)),
  };
}

// A chat file, or null if it isn't one this viewer reads. Entries of a kind
// it doesn't know are left out.
function parse(id: string, text: string): Chat | null {
  let doc;
  try {
    doc = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof doc !== "object" || doc === null || doc.version !== VERSION || doc.id !== id) return null;
  const strings = ["session", "title", "started", "updated", "folder"].every((k) => typeof doc[k] === "string");
  if (!strings || !Array.isArray(doc.entries)) return null;

  const entries: ChatEntry[] = doc.entries
    .filter((e: any) => typeof e === "object" && e !== null && KINDS.has(e.kind) && typeof e.text === "string")
    .map((e: ChatEntry) => ({ kind: e.kind, text: e.text }));
  return { id, session: doc.session, title: doc.title, started: doc.started, updated: doc.updated, folder: doc.folder, entries };
}
