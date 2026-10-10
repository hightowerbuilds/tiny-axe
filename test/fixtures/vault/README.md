# Vault fixture

The worked example of [the vault format](../../../docs/vault-format.md),
shared by the Elixir writer's tests and the TypeScript viewer's tests.

- `journals/tasks/` — two synthetic tasks, in the shape the gate writes
  them (`calls.jsonl`, `decisions.jsonl`), plus the `class` field and
  `task.json` that G1 adds. Sites, people and products are made up.
- `vault/` — the notes those journals must produce, byte for byte (the
  manifest's `generated_at` aside). Every count and link was worked out by
  hand from the journals.
- `graph.json` — what reading `vault/` gives: the nodes and lines the viewer
  draws.
- `names.json`, `templates.json` — note names and URL templates both
  languages must agree on.

Change these only together with the format document, and bump the schema
when an existing name, key or link changes.
