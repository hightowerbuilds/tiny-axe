---
kind: "path"
key: "shop.example/cart/view.html|button|proceed to checkout|browser__browser_click|saves_on_change=no sends=unlikely spends=likely|commit|refused|unchecked"
title: "click \"Proceed to checkout\" → refused"
trust: "observed"
site: "shop.example"
subject: "shop.example/cart/view.html|button|proceed to checkout"
tool: "browser__browser_click"
answers: "saves_on_change=no sends=unlikely spends=likely"
class: "commit"
gate: "refused"
outcome: "unchecked"
reason_codes: ["purchase_signal"]
seen: 1
errors: 1
drivers: ["claude-haiku-5-5"]
models: ["jev-1.13.0"]
versions: ["browser-policy/2 · browser-effects/2 · browser-evidence/1"]
first_seen: "2026-10-01"
last_seen: "2026-10-01"
tasks: ["20261001-100000-1"]
decisions: ["dec-a00000000004"]
---

# click "Proceed to checkout" → refused

- Acted on: [[Proceed-to-checkout-button cf674575|Proceed to checkout (button)]]
- Tool: [[browser__browser_click|browser_click (browser)]]

Taken 1 time on 2026-10-01.

## Jev

| Question | Answer |
|---|---|
| saves_on_change | no |
| sends | unlikely |
| spends | likely |

## Gate

Class: commit · Gate: refused · Reasons: purchase_signal
