# Plan: the panel, the permission popup, and the route line

Status (2026-10-12): P1–P3 built on branch `panels` (worktree `../tiny-axe-panels`).

Merged into main 2026-10-12 without the panel popup: the main tabs (Chat, Wallet, Gemma Search, Tokens, Remote; `TUI.MainTabs`, `TUI.FeaturePanels`) had replaced it. The permission popup and `/route` were kept.

This responds to review section 08 (`docs/reviews/tiny-axe-review-2026-10-12.html`): the interface shows a lot of internal detail. The review asks that the default view say what's happening, what tiny-axe needs from you, and what has been verified, with details available when you ask for them. The account step stays as it is (the user's choice).

## What the user chose

- **Panel:** one popup over the chat with tabs: Remote, Token, Wallet, Search. Each slash command opens it on its own tab: `/remote`, `/token`, `/wallet` (with `/credit-card` as an alias) and `/search`. `tab`, `shift+tab`, `←` and `→` switch tabs, and `esc` closes the panel.
- **Permission popup:** keeps priority over everything else, including the panel. Every question (tool call, shell command, purchase, bigger model, browser handoff) uses one layout:
  - a risk banner: green for read only, yellow for changes something or leaves this machine, red for spends money or can't be undone
  - what the question is and who is asking
  - details such as arguments behind `d`
  - the keys
  - every question waiting behind it, as a list
- **Route line:** hidden by default. `/route on|off` shows or hides it, and the choice is remembered across starts in `tui.json` in the state folder.

## Steps

- **P1 route line:** add `TinyAxe.TUI.Prefs` and `/route`.
- **P2 panel:** add `TinyAxe.TUI.Panel` (its state, keys and rendering) and fold `/token` into it.
  - **Remote tab:** shows the connection, the message being answered and the queue. `enter` turns remote chat on or off; `/remote on|off` still works.
  - **Wallet tab:** lists cards (masked). `a` adds a card (the existing card flow), and `f` then `y` forgets the selected card. `/credit-card list` and `/credit-card forget` still work.
  - **Search tab:** type a search, `enter` searches, `↑` and `↓` choose a chat, and `enter` opens it. It uses `TinyAxe.History.list(query:)` for now. The local chat-memory work (`docs/plan-local-memory.md`) can swap in its own search behind `Panel.search/1`.
- **P3 permissions:** one renderer in `TinyAxe.TUI.Overlays`, with risk by class, `d` for details, and the waiting questions listed.
