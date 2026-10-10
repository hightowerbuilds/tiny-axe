// A note's Markdown as HTML for the viewer. Labels in notes come from web
// pages, so nothing in a note can become markup: raw HTML is shown as text,
// links go only to web addresses or other notes, and images aren't loaded.

import { Marked, type Tokens } from "marked";

export interface LinkTarget {
  kind: string;
  title: string;
}

export function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

export function noteHref(id: string): string {
  return `/note/${encodeURIComponent(id)}`;
}

interface WikiLink {
  type: "wikilink";
  raw: string;
  target: string;
  text: string;
}

/** A renderer that knows which notes exist, to mark links to missing ones. */
export function renderer(resolve: (id: string) => LinkTarget | undefined): (markdown: string) => string {
  const marked = new Marked({
    gfm: true,
    extensions: [
      {
        name: "wikilink",
        level: "inline",
        start: (src: string) => src.match(/\[\[/)?.index,
        tokenizer(src: string): WikiLink | undefined {
          const m = /^\[\[([^\[\]|\n#]+)(?:#[^\[\]|\n]*)?(?:\|([^\[\]\n]*))?\]\]/.exec(src);
          if (m) return { type: "wikilink", raw: m[0], target: m[1].trim(), text: (m[2] ?? m[1]).trim() };
        },
        renderer(token) {
          const { target, text } = token as unknown as WikiLink;
          const note = resolve(target);
          if (!note) return `<span class="wikilink missing" title="No such note">${escapeHtml(text)}</span>`;
          return `<a class="wikilink kind-${escapeHtml(note.kind)}" href="${noteHref(target)}">${escapeHtml(text)}</a>`;
        },
      },
    ],
    renderer: {
      html: ({ text }: Tokens.HTML | Tokens.Tag) => escapeHtml(text),
      image: ({ text }: Tokens.Image) => escapeHtml(text),
      link(this: { parser: { parseInline(tokens: Tokens.Generic[]): string } }, { href, tokens }: Tokens.Link) {
        const text = this.parser.parseInline(tokens);
        if (!/^(https?:|mailto:)/i.test(href)) return text;
        return `<a class="external" href="${escapeHtml(href)}" rel="noopener noreferrer" target="_blank">${text}</a>`;
      },
    },
  });

  return (markdown) => marked.parse(markdown, { async: false }) as string;
}
