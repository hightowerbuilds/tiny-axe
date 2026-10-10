---
kind: "path"
key: "shop.example/:slug/dp/:id|button|add to cart|browser__browser_click|saves_on_change=no sends=no spends=no|local|ran|unchecked"
title: "click \"Add to Cart\" → ran"
trust: "observed"
site: "shop.example"
subject: "shop.example/:slug/dp/:id|button|add to cart"
tool: "browser__browser_click"
answers: "saves_on_change=no sends=no spends=no"
class: "local"
gate: "ran"
outcome: "unchecked"
reason_codes: ["no_external_effect"]
seen: 2
errors: 0
drivers: ["claude-haiku-5-5"]
models: ["jev-1.13.0"]
versions: ["browser-policy/2 · browser-effects/2 · browser-evidence/1"]
first_seen: "2026-10-01"
last_seen: "2026-10-02"
tasks: ["20261001-100000-1","20261002-110000-2"]
decisions: ["dec-a00000000003","dec-b00000000001"]
---

# click "Add to Cart" → ran

- Acted on: [[Add-to-Cart-button 0ec1c8ea|Add to Cart (button)]]
- Tool: [[browser__browser_click|browser_click (browser)]]

Taken 2 times, 2026-10-01 to 2026-10-02.

## Jev

| Question | Answer |
|---|---|
| saves_on_change | no |
| sends | no |
| spends | no |

## Gate

Class: local · Gate: ran · Reasons: no_external_effect

## Led to

- [[shop.example-cart-view.html ce5545df|shop.example/cart/view.html]]
