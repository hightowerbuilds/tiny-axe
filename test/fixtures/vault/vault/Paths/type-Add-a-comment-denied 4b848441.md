---
kind: "path"
key: "news.example/:id/:id/:id/city-council-votes|textbox|add a comment|browser__browser_type|saves_on_change=no sends=yes spends=no|outward|denied|unchecked"
title: "type \"Add a comment\" → denied"
trust: "observed"
site: "news.example"
subject: "news.example/:id/:id/:id/city-council-votes|textbox|add a comment"
tool: "browser__browser_type"
answers: "saves_on_change=no sends=yes spends=no"
class: "outward"
gate: "denied"
outcome: "unchecked"
reason_codes: ["sends_signal"]
seen: 1
errors: 1
drivers: ["claude-haiku-5-5"]
models: ["jev-1.13.0"]
versions: ["browser-policy/2 · browser-effects/2 · browser-evidence/1"]
first_seen: "2026-10-02"
last_seen: "2026-10-02"
tasks: ["20261002-110000-2"]
decisions: ["dec-b00000000002"]
---

# type "Add a comment" → denied

- Acted on: [[Add-a-comment-textbox 4f1d042e|Add a comment (textbox)]]
- Tool: [[browser__browser_type|browser_type (browser)]]

Taken 1 time on 2026-10-02.

## Jev

| Question | Answer |
|---|---|
| saves_on_change | no |
| sends | yes |
| spends | no |

## Gate

Class: outward · Gate: denied · Reasons: sends_signal
