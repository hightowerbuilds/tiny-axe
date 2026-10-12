# Plan: purchases through Claude in Chrome

Status (2026-10-12): P0 done; P1 and P2 built and live-checked (below); P3 (approving on the Chat tab) next. Branch `chrome-purchases` (worktree `../tiny-axe-chrome`).

## What the user asked for

tiny-axe uses Claude in Chrome (the user's real Chrome, with its logged-in
shops) and its main purpose there is to **complete purchases**, from the TUI
and from the site's Chat tab (remote chat) alike.

Everything in `plan-browser-and-cli-models.md` § C still holds (the user
approved it): no model sees or types card details; only a human, typing the
exact total, places an order; caps in code ($100 an order, $200 a day, any
shop); a write-ahead journal; never retried.

## What's true today (checked 2026-10-12)

- `claude -p --chrome` works headless and exposes the 20
  `mcp__claude-in-chrome__*` tools even with tiny-axe's lockdown
  (`--tools ""`, `--strict-mcp-config`, `--setting-sources local`).
- None of them is in `--allowedTools`, so each call would need permission.
  `--permission-prompt-tool <mcp tool>` sends that question to an MCP tool:
  tiny-axe's gate can answer it, call by call.
- The catch: tiny-axe's own browser lets **code** read the checkout page and
  **code** click "Place order". With Claude in Chrome, Claude Code holds the
  browser; tiny-axe can't read or click on its own. So the gate has to see
  what Claude sees and let exactly one click through.

## The shape

```
Haiku (claude -p --chrome)
  │ every Chrome call ──▶ permission tool ──▶ TinyAxe.Tools.Gate: allow / hold / deny
  │ every Chrome result ─▶ PostToolUse hook ─▶ the gate (pages, refs, labels, URLs)
  ▼
your Chrome (Claude in Chrome extension)
```

- **The gate sees each call** (`--permission-prompt-tool mcp__tinyaxe__chrome_permission`):
  the tool and its input (a click's ref or coordinates, a URL, typed text).
- **The gate sees each result** through a `PostToolUse` hook passed with
  `--settings` (a small script that posts the result to the gate's local
  endpoint): page text, `read_page`/`find` refs with their labels, tab URLs.
  So it knows which button a ref is and what page it's on. (Phase 0 checks
  that hooks run under `--setting-sources local`.)

### Classes

| Chrome tool | Class | Asks? |
|---|---|---|
| `tabs_context`, `read_page`, `get_page_text`, `find`, `read_console_messages`, `read_network_requests`, `computer` screenshot/scroll, `list_connected_browsers` | read | never |
| `navigate`, `tabs_create`, `computer` click/type/key, `form_input` | act | no, on the purchase's shop; otherwise a yes |
| a click or key that **commits** (its ref's label matches place order / buy now / pay / submit order / complete purchase, or Enter in a checkout form) | commit | the purchase gate, below |
| `javascript_tool`, `shortcuts_execute`, `gif_creator`, `browser_batch` holding any of the above | refused during a purchase | — |

Clicks on a checkout page must be by ref (from `find`/`read_page`), never by
coordinates, so the gate always knows the label. Typed text that looks like
a card number is refused (`Tools.Redact`), so the model can't type one; it
picks among the saved, masked cards the page shows (Chrome autofill or the
shop's saved card).

### A purchase

1. **Intent**, from the user's words, as now (item, maximum price, shop).
2. **Browse and fill the cart:** reads and acts on the shop run freely.
3. **Held commit.** The gate holds the "Place order" click and answers "read
   the page first": the agent calls `get_page_text`; the hook gives the gate
   the page. Code builds the summary from it (shop from the tab's URL, items,
   total, card as shown) and runs the checks (intent maximum, caps, currency,
   Jev on the items). A failed check can't be approved.
4. **The user types the exact total**: in the TUI's red popup at the
   machine, or on the **Chat tab** for a remote chat (below).
5. **One click, rechecked.** The agent reads the page once more and clicks
   again; the gate lets exactly that click through only if the shop, the
   total and the button's ref and label are unchanged. Otherwise it goes
   back to the user. One permit, one click.
6. **Receipt:** the agent reads the confirmation page; the hook gives it to
   the gate, which journals it (`<state>/purchases/<id>/`), as now.

### Remote: approving on the Chat tab

- A held purchase in the 🌐 chat goes to the page as an approval card: the
  summary, failed checks, and a box to **type the exact total**, plus
  Cancel. It waits up to 10 minutes, then it's refused.
- New edge function `ta-remote-approve` (owner session) saves the answer;
  it reaches tiny-axe on the channel. tiny-axe checks the typed total in
  code, like the TUI does.
- The same card, with Approve / Deny, covers the other "needs a yes" asks in
  remote chats (acts off the shop, commands that change things), so remote
  chats stop refusing everything. That's the start of the security pass.

## P0 findings (2026-10-12, claude 2.1.296, Haiku 5.5, the fixture shop in the user's Chrome)

Run: `claude -p --model claude-haiku-5-5 --setting-sources local --settings
<hooks> --tools "" --strict-mcp-config --mcp-config <gate> --allowedTools
<gate> --permission-prompt-tool <gate tool> --chrome`, from an empty folder.

- **Every Chrome call goes to the permission tool**, reads included, as
  `{tool_name, input, tool_use_id}`. It answers with the text
  `{"behavior":"allow","updatedInput":…}` or `{"behavior":"deny","message":…}`.
  A refusal's message reaches the model, which follows it: held "Place
  order" → it called `get_page_text` → clicked again → allowed.
- **Hooks run** from `--settings` under `--setting-sources local`. PreToolUse
  and PostToolUse get `tool_name`, `tool_input`, `tool_use_id` and (post)
  `tool_response`, a list of text parts:
  - `get_page_text`: `Title:`, `URL:`, then the page text (the summary's
    source);
  - `find`: `- ref_16: button ""Place order"" (button) - …` (ref → label);
  - every result ends with **Tab Context**: each tab's id, title and URL.
- **A click carries its ref and tab:** `computer {"action":"left_click",
  "ref":"ref_16","tabId":…,"action_summary":…}`. So the gate knows the button
  and the page.
- **`browser_batch` hides actions:** the gate sees one call whose
  `input.actions` lists the inner ones (`navigate`, `get_page_text`, …), and
  no PostToolUse came back for it. Haiku used it even when told not to. The
  gate refuses batches ("one call at a time").
- **Waiting works:** a permission answer that took 150 s was waited for. The
  driver also sets `MCP_TOOL_TIMEOUT` high, for remote approvals (10 min).
- The order on the fixture went through only after the gate allowed the
  click (order `TA-1001`).

## P1: what was built (2026-10-12)

- `TinyAxe.Chrome`: `/chrome on|off` (`<state_dir>/chrome.json`), the rules
  (`classify/3`), what results show (`observe/4`), the agent's instructions.
- The gate: tasks opened with `chrome: true` (and driven by Claude) list
  `chrome_permission`; it answers Claude Code's permission questions (reads
  run; acts on a site the user allowed for the task run, else the usual
  y / a / n question, where "a" allows that site for the task; commits are
  refused until P2; batches, scripts, shortcuts, uploads, card numbers and
  clicks by position are refused). `POST /hook/<task>` (the task's token)
  takes in each Chrome result.
- `ClaudeDriver`: `--chrome`, `--permission-prompt-tool
  mcp__tinyaxe__chrome_permission`, and `--settings` with a `PostToolUse`
  hook (curl to `TINYAXE_HOOK_URL` with `TINYAXE_HOOK_TOKEN`).
- `Agent`: with Chrome on and Claude driving, the task gets Chrome (150
  calls, since looking counts too); the router offers "chrome" as a service.

**What the live check found.** The first real run (tiny-axe's agent, Haiku,
the fixture shop) placed the order: Haiku took screenshots instead of
reading the page as text, then clicked "Place order" **by position**, which
looked like any click. Now every click must name a ref the gate has seen
labelled (by position, or an unknown ref, is refused with what to do
instead), Enter is refused on a page tiny-axe hasn't read, and on a
checkout "Continue / Submit / Confirm / Complete" count as placing the order.
The rerun: Haiku found the button, clicked it by ref, the gate held it, and
Haiku told the user it hadn't ordered.

## P2: what was built (2026-10-12)

- `TinyAxe.Chrome.Checkout`: the checkout summary from `get_page_text`'s
  text (a port of the browser server's rules: the grand total line, items,
  ship-to, the card shown), and the order number on a confirmation page.
- The gate, for a commit in Chrome (with buying on):
  1. the page must have been read after the last action on that tab, or
     the click is held with "read the page first";
  2. code builds the summary and runs `Purchases.checks/3` (maximum, caps,
     currency, Jev on the items, how it's paid); a failed check refuses;
  3. the red popup, the user types the total (`{:purchase_approval, …}`);
  4. the click is refused with "the user approved: read the page once more
     and click again"; when it comes back after a fresh read, with the same
     shop, total and card, that one click is let through (`clicking`);
  5. the hook sees the click's result (`clicked`) and then the next read of
     the tab is the receipt (`receipt.txt`, order number, `{:purchased, …}`);
  6. while an order may have gone through, no other is placed in the task.
- **Which card:** Chrome's page text and `read_page` don't say which radio
  is selected (checked in a probe). One card shown is that card; with
  several, the card the agent clicked by its name on that page is the one,
  and with none clicked the order is held until it picks.
- Live (fixture shop, real Haiku, the popup answered "confirm"): held →
  read → popup ($16.00, Mastercard ending in 5555, every check passed) →
  confirm → read → one click → receipt `TA-1001`; journal `intent → summary
  → confirmed → clicking → clicked → receipt`.

## Phases

- **P0, experiments** (no purchases): `--permission-prompt-tool` with
  `-p` (the JSON in and out), `PostToolUse` hooks via `--settings` under
  `--setting-sources local`, the exact inputs and results of `find`,
  `read_page`, `computer` and `form_input`, and whether a click by ref
  carries the ref. Against tiny-axe's fixture shop on 127.0.0.1, opened in
  real Chrome.
- **P1, the gate for Chrome:** the permission tool, the hook endpoint, the
  classes; ordinary browsing in the user's Chrome from the TUI.
- **P2, purchases at the machine:** the held commit, summary, typed total,
  recheck, one permitted click, receipt; end to end on the fixture shop with
  real Haiku.
- **P3, remote approvals:** `ta-remote-approve`, the approval card on the
  Chat tab, the 🌐 chat waiting for it; purchases and other asks from the
  phone.
- **P4, the first real purchase:** with the user there, following § C's
  checklist. The user expects real orders to be $100 or more, so the caps
  must allow that first (below).

## Defaults (change any)

- Acts off the purchase's shop need a yes (at the machine, or on the Chat tab
  remotely).
- Caps in code as now, set by the user (`mix tiny_axe.purchases limits
  --per-order N --daily N`). On 2026-10-12 they're $25 an order and $25 a
  day, which would refuse the $100+ orders the user expects: they need
  raising before P4. Claude in Chrome pays with the card saved at the shop,
  so tiny-axe's own card limits don't apply there; these caps are the limit.
  Journal as now.
- Cards: saved at the shop or in Chrome autofill only; tiny-axe never types
  a card number into Chrome.
- tiny-axe's own browser stays for tasks that don't need your logins;
  "in my Chrome" or a shop you're logged in to uses Claude in Chrome.
