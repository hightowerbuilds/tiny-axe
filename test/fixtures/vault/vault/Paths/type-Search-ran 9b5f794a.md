---
kind: "path"
key: "shop.example/|searchbox|search|browser__browser_type|saves_on_change=no sends=no spends=no|local|ran|unchecked"
title: "type \"Search\" → ran"
trust: "observed"
site: "shop.example"
subject: "shop.example/|searchbox|search"
tool: "browser__browser_type"
answers: "saves_on_change=no sends=no spends=no"
class: "local"
gate: "ran"
outcome: "unchecked"
reason_codes: ["no_external_effect"]
seen: 1
errors: 0
drivers: ["claude-haiku-5-5"]
models: ["jev-1.13.0"]
versions: ["browser-policy/2 · browser-effects/2 · browser-evidence/1"]
first_seen: "2026-10-01"
last_seen: "2026-10-01"
tasks: ["20261001-100000-1"]
decisions: ["dec-a00000000001"]
---

# type "Search" → ran

- Acted on: [[Search-searchbox 83200247|Search (searchbox)]]
- Tool: [[browser__browser_type|browser_type (browser)]]

Taken 1 time on 2026-10-01.

## Jev

| Question | Answer |
|---|---|
| saves_on_change | no |
| sends | no |
| spends | no |

## Gate

Class: local · Gate: ran · Reasons: no_external_effect

## Led to

- [[shop.example-s 3af4d7bb|shop.example/s]]
