# Plan: the leash, automatic purchases, and dead ends

Status (2026-10-12): planned. This work is on branch `leash` (worktree `../tiny-axe-leash`), which is built on `chrome-purchases` with `main` merged in, so both browsers get it.

## Why

No purchase has gone through yet, and the friction is a big part of that. In the 2026-10-12 Musician's Friend run (chat `20261012-201107-9f5d`), the right items reached the cart, then:

- the user's email, address and phone went to the local model as plain questions (and it said it had acted when it hadn't)
- typing into a search box and every checkout click asked for approval
- an unconfirmed "Guest Checkout" click stopped the run
- the caps ($25 per order, $25 a day) would have refused the $35 order anyway

The user wants a wider leash and fewer interruptions, with the existing protections kept. They also want paths that don't work to be remembered and not tried again.

## What the user chose (2026-10-12)

- **A session-wide leash:** `/leash on` means every browser action that isn't the final purchase runs without asking, on any site, for this session. It is off by default at each start.
- **Automatic purchases within budget:** with the leash on, an order is placed without asking when every purchase check passes: what you asked for, the caps, the shop, the payment, and the card's rules. If any check fails, tiny-axe asks you as it does now. A card locked with a PIN still needs the PIN typed. Every order still shows a receipt line.
- **Dead ends: warn ahead, block repeats.** The agent is told a site's known dead ends before it acts there. Repeating one within the same task is refused.
- **Caps:** $150 per order and $300 a day.

## What doesn't change

- The model never sees or types card details.
- The caps, the card's allowed shops and purpose, and the currency still apply.
- Pages are re-read before the order click, and that click is checked again.
- Everything is still journaled.
- The 🌐 remote chat keeps refusing anything that would ask, even with the leash on. Leashing remote chat is a separate decision.

## Steps

- **L1 leash.** Add `TinyAxe.Leash` (on or off for the session) and `/leash on|off`, shown in the status bar. With the leash on, the gate passes outward browser actions in tiny-axe's browser and in the user's Chrome. Shell commands and other MCP servers' outward tools still ask.
- **L2 automatic purchases.** With the leash on, when every check passes and nothing needs typing, the gate places the order without asking. A purchase request that names no maximum gets the per-order cap as its maximum. Set the caps to $150 and $300.
- **L3 dead ends.** Add `TinyAxe.Browser.DeadEnds`. Failed and unresolved action records are kept per site in `<state_dir>/dead_ends.json`, keyed by host, the page's path pattern, the action and the control's label, and they expire after 30 days. Jev judges each failure: a real dead end, or a one-off. A path judged a dead end, or one that failed twice, is listed for the agent when it first opens that site. An action matching one that already failed in this task is refused. `mix tiny_axe.dead_ends` lists and forgets them. We measure it by counting, in the journal, how often known dead ends are repeated.
- **L4 one task, not one message.** After an agent run, the router asks Jev whether the next message continues that run (an answer to its question, such as an address or "yes"). If it does, the message goes back to the agent with the browser, not to the local model.
