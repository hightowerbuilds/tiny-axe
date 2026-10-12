# Plan for local chat memory and Gemma search

Status: background review implemented, 12 October 2026. Full local indexing, terminal search, source viewing, bounded Gemma answers, and optional background Gemma search notes are built. An evaluation of additional local judging and automatic recall in ordinary conversations remain later milestones. Accounts for the graph removal in commit `e3e9deb`.

Implemented commands include `/memory`, `search`, `ask`, `next`, `open N`, `status`, and `rebuild`. Search runs independently of Ollama. Memory opens a dedicated local-only conversation, persists that policy, bypasses global agents and deciders, and excludes the conversation from website sync. Historical command output that was never saved remains unrecoverable; new output is persisted in version 2 files.

`/memory review on` enables persistent background review, initially off. `/memory review off` stops the active review request while retaining completed notes; `/memory review retry` clears failed attempts without turning a paused queue on. Status separates searchable entries from prepared passages, completed notes, failed passages, and entries still awaiting preparation. New entries are prepared incrementally; each entry is split into Unicode-safe passages of about 1,100 bytes covering its entire text. An unusually large single grapheme can exceed that size and will be rejected by the model context budget if necessary, rather than silently truncated.

Notes retain the configured model name, prompt version, passage hash, and entry span. Appending to a chat preserves notes for unchanged entries. Changed/deleted entries lose their notes, and late results must match the current original passage before being stored. Changing the configured model or prompt version queues replacement notes and excludes old versions from retrieval. Rebuilding the index discards notes as well as lexical rows; saved transcripts and the review on/off setting survive.

The review worker runs one inference task at a time in each app process. Foreground TUI tasks and explicit memory questions interrupt it; cancellation leaves the passage pending. Failed calls trigger at least a minute of worker cooldown and ten minutes per failed passage, with three attempts before manual retry. This coordinates tiny-axe's requests, not unrelated Ollama clients or other app processes. Closing the local request does not guarantee instantaneous preemption inside Ollama. Review never enters a hosted model adapter.

The fixed synthetic evaluation in [scripts/memory-review-eval.exs](../scripts/memory-review-eval.exs) uses five passages, four target queries, and one negative control. With local `gemma4:e4b-it-qat`, generated notes improved target retrieval from **1/4 to 3/4**: “authentication” found FIDO2/YubiKey and “migration” found the PostgreSQL switchover. “Photo backup” still missed the JPEG/restic passage. There were no unrelated hits on these queries or hits for the negative control. Generating five notes took **about 12 seconds** on each of two runs, and Ollama reported 100% GPU use with an 8,192-token context. The second run also returned a source-checked answer to “What is the laptop authentication plan?” This small vocabulary check supports an optional feature, not a general semantic-recall accuracy claim. Exact transcript search is unaffected; generated notes only add candidates to `/memory ask`, and only checked original passages enter its answer prompt.

A real smoke test with `gemma4:e4b-it-qat` found a decision in the middle of a long synthetic chat, answered with a verified quotation in 2.3 seconds, and correctly distinguished a decision to buy from a completed purchase. `ollama ps` reported 100% GPU residency with an 8192-token context. These are observations on this machine, not a general latency guarantee.

The full suite during this milestone ran 782 tests and 3 doctests and exposed one memory UI failure after application recovery. The recovery test temporarily changes the state directory; History followed the restored configuration while memory kept the temporary location. Memory now follows History's configured location, keeps explicit archive overrides fixed, and rejects background results from a previously selected archive. The focused recovery and memory rerun passed all 35 tests. Regression coverage also checks recovery after an inaccessible archive location. The rebuilt production release passed checks for FTS5 notes, exact search, and original-source opening; it has not been installed over the existing launcher.

Final validation: `mix test --exclude browser --seed 423884 --max-cases 1` passed **700 tests and 3 doctests**, with 86 browser-tagged tests excluded from that final rerun. The preceding full run covered those browser tests. Intermediate parallel runs encountered a remote-websocket handshake timeout and interference between separate suites using the shared fake-keyring directory; the serial run passed these checks too. Formatting and diff checks pass. Do not run separate suites concurrently without isolating their shared test fixtures.

Scale check: all 10,000 synthetic chats and 100,000 entries indexed successfully, with all 100 expected phrase matches found. With the new review schema, 12 searches on the warmed archive measured **230 ms median and 298 ms p95**, including rereading and hashing saved files for freshness. This measures lexical search with generated review still off, not the GPU cost of reviewing 100,000 entries. These are local observations, not an unconditional service guarantee.

The implementation currently uses up to three Gemma-planned queries and up to eight source passages. Source opening includes adjacent entries. It does not yet provide an iterative model-controlled search/read tool loop. The design below remains the target for later milestones.

Build a simple, persistent memory bank of tiny-axe chats. Every saved message should be searchable by word, phrase, or literal text. Gemma should use that search engine, read the matching passages, and answer questions with references back to the original conversation. Gemma should also be able to build useful local summaries as chats accumulate.

The complete transcript is the memory. The search index makes it accessible. Gemma helps interpret and retrieve it. A generated summary must never determine which original words remain searchable.

## Requirements and scope

The user has specified a simple memory bank, search across all chats, local Gemma running on the GPU, and no graph display. This feature must not use Claude or any other off-machine model. Jev is welcome where it can help within that constraint. These restrictions cover indexing assistance, query planning, review, answer generation, and fallback behavior.

For the first release, “all chats” means every readable chat stored in tiny-axe's local history, across sessions and project folders, plus new chats as they are saved. This does not automatically include conversations held only on a website or inside other applications. Those would need explicit import support later.

The proposed default is local storage and local processing, without an account requirement or automatic website upload for this workflow. Whether to retain an explicitly enabled website archive elsewhere in the app remains a separate product choice. It cannot silently receive memory queries, retrieved excerpts, or answers.

This is retrieval and local inference. It does not train or fine-tune Gemma's weights. The database and search run on the CPU and disk; Gemma's reading and reasoning use the GPU through Ollama.

## What the existing code gives us

| Existing component | Useful foundation | Required change |
| --- | --- | --- |
| [History](../lib/tiny_axe/history.ex) | Atomic local JSON files, persistent chat IDs, saved transcript entries, reopening | Add a searchable index and reliable indexing notifications after successful saves. |
| [History commands](../lib/tiny_axe/tui/chat_history.ex) | Lists and reopens previous chats | Show matching passages, page through results, and open the cited position. |
| [Site](../lib/tiny_axe/site.ex) | Existing agent operations named `chat_search` and `chat_read` | These use the remote website; supply independent local operations for memory. |
| [Ollama](../lib/tiny_axe/ollama.ex) | Local generation and structured response support | Give memory its own pinned local model configuration and bounded requests. |
| [Local decider](../lib/tiny_axe/decider/local.ex) | Typed decisions using a local Ollama model | Evaluate reuse for relevance and evidence checks without inheriting the global backend. |
| [Sync](../lib/tiny_axe/sync.ex) | Existing upload lifecycle | Prevent the local memory workflow from entering automatic upload paths. |

Current history search scans JSON files and checks whether each space-separated fragment appears anywhere in a chat. It does not implement a proper phrase search or identify the matching message. The newly introduced site search travels over HTTP to the account's website, so it cannot serve as the offline search engine.

Commit `e3e9deb` removed the graph, vault, and old review module. The earlier review cut long conversations to their first and last 3,000 characters, then generated a summary and tags with local Gemma and the configured, potentially remote decider. That approach could lose everything in the middle. The replacement should retain the useful idea of incremental local reading without reviving that coverage limit or the graph.

The persistence contract needs an audit too. History currently serializes user, assistant, and meta entries represented as two-element tuples. Command output represented as a four-element tuple is not serialized by that function. The plan must preserve visible tool output going forward, with a versioned, backward-compatible representation. Historical text that was never saved cannot be recovered by indexing. Existing redaction also means the bank contains saved, redacted text, not an unmodified recording of every original input.

## Storage and indexing

Keep the existing JSON history as the canonical record. Add one rebuildable SQLite database at `<state_dir>/memory.sqlite3`. Deleting or rebuilding the index must leave the original chat files intact.

Use SQLite FTS5 for ordinary word and phrase retrieval. It supports full-text queries and phrase matching without a separate search server. Select an Elixir driver during implementation and verify FTS5 support in the packaged release before depending on it. [SQLite FTS5 documentation](https://www.sqlite.org/fts5.html)

Store chat metadata and one indexed row per saved entry. Each row needs the chat ID, entry position, speaker or entry kind, original saved text, and source revision hash. Store indexing status separately from Gemma's enrichment status. A chat can be fully searchable while its optional generated description is still pending.

Index the full text of every eligible entry. Do not index only titles, tags, compacted model context, or the subset that fits Gemma's context window. Index full entries before cutting passages for inference, so an artificial passage boundary cannot hide a phrase.

Use a source hash to replace a changed chat's rows in one transaction. Reopening and extending a chat should update the same chat, without duplicating its old messages. Changes to the model or enrichment prompt should invalidate generated annotations without forcing a rebuild of unchanged transcript text.

After each successful atomic history save, enqueue that chat for indexing. On startup, reconcile the history directory against indexed revisions so a missed notification or crash does not leave permanent gaps. Remove derived rows when a source chat is deleted. Ignore temporary files and report unreadable or malformed chats individually.

Queries need an explicit freshness boundary: wait for the initiating chat's pending save, process known changes, and search a consistent index snapshot. Report pending or failed indexing instead of claiming there are no matches in a complete archive. Startup reconciliation and periodic checks should also detect changes made by another app process. Use transaction serialization and bounded lock retries rather than assuming only one terminal can be running.

## Search behavior

Keep direct search predictable. The proposed interface is:

| Example | Meaning |
| --- | --- |
| `/memory search tractor` | Find the whole word, regardless of case. |
| `/memory search graphics card` | Find entries containing both words, in any order. |
| `/memory search "graphics card"` | Find those words consecutively, in that order. |
| `/memory search --literal "C++"` | Find the exact characters, including case and punctuation. |
| `/memory ask What GPU did we decide to buy?` | Let local Gemma search, read, and answer with citations. |
| `/memory open 2` | Open result 2 from the current result list at its matching entry. |
| `/memory status` | Show archive coverage, indexing failures, and local model status. |
| `/memory rebuild` | Rebuild derived search data from saved chats. |

Quoted phrases mean consecutive words within one entry. Whitespace and separating punctuation do not establish different words; literal mode preserves those distinctions. FTS5 phrase matching operates on token sequences, so it must not be presented as byte-for-byte text matching. [SQLite phrase semantics](https://www.sqlite.org/fts5.html#fts5_phrases)

Configure ordinary search without stemming, stop-word removal, or accent stripping. Preserve the difference between separate messages: words spoken by different people must not be assembled into a quotation. The literal path must handle paths, flags, symbols, very long identifiers, and one- or two-character searches. Start with an exhaustive comparison against stored entry text where token indexing cannot guarantee the requested match. Optimizing that path comes after correctness measurements.

Treat search text as data. Bind SQL parameters and separately escape the full-text query grammar; binding a parameter alone does not turn FTS operators into literal words. Gemma gets structured search options, never arbitrary SQL, shell commands, or unrestricted database access.

Show a short original excerpt with highlights, speaker, chat title, and date. Older files have chat timestamps rather than individual message timestamps; label dates accordingly. Offer pagination and a visible match count. Ranking can determine display order, but a result limit must not silently redefine “all chats” as the first twenty recent conversations.

Keep `/history` for browsing and reopening. Explicit `/memory search` separates numeric searches from result selection and gives the new behavior a clear contract.

## How Gemma uses the memory

The local recall flow is:

1. Accept a memory question through the dedicated local command path.
2. Ask Gemma for a small structured search plan, preserving any exact words or quoted phrase the user supplied.
3. Run the search engine and return original passages with source IDs.
4. Allow a bounded follow-up search or a read of neighboring entries when the first results need context.
5. Ask Gemma to answer from those passages and attach their source references.
6. Validate references and quoted text before displaying the answer.

Expose only two read operations to this flow: search saved entries and read a bounded range from an identified chat. Start with at most three search rounds and eight evidence passages per answer, with an explicit context budget. These are inference limits, not limits on what the search engine indexes or what the user can browse.

Natural language retrieval can suggest alternative terms: a question about a graphics card might also search “GPU” and a model name. Keep expanded searches distinguishable from exact matches. An answer about a purchase should distinguish discussing a product, choosing it, and actually buying it; an assistant's earlier suggestion is not evidence that the user acted on it.

Each citation should identify the chat, source revision, entry, and quoted span. Resolve it against the original saved text. If that source changed, refresh the result or mark it stale. Never open an unrelated entry because its ordinal moved. Citation validation proves where text came from; it does not prove that Gemma interpreted it correctly.

Retrieved conversations are historical evidence. Instructions contained inside them must not become current commands. If evidence conflicts, show the conflicting passages and their order. If Gemma cannot find enough evidence, say so and expose the search results. Avoid the stronger claim that something was never discussed merely because a bounded set of model-chosen queries found nothing.

Initial access should be explicit through `/memory`. Automatic recall during ordinary chat can follow once routing and data handling are proven. Injecting old private passages into every ordinary prompt would be especially problematic while other app workflows can use remote models.

## How Gemma builds useful memory over time

Automatic indexing should happen without waiting for a model. Then a separate local background queue can let Gemma read new or changed passages and attach a short description, named topics, and suggested questions those passages could answer.

Process long chats in bounded sections that collectively cover the full saved conversation. Record the source spans each annotation describes. Do not repeat the removed first-and-last-only review. Process one background job at a time and give foreground questions priority, so building the archive does not monopolize the GPU.

Generated annotations are navigation aids. Label them as generated, keep their model and prompt version, and link them to the original entries. They must not overwrite source text or become evidence for a fact on their own. Search should distinguish a match in an annotation from a match in the conversation. Store them with the new memory data, not in the retired `reviews.jsonl` path that the current installer removes.

This gives Gemma a real ongoing role: it helps organize the bank and formulate better searches while the archive retains complete lexical coverage. Keep enrichment only if a fixed set of recall questions demonstrates that it improves retrieval enough to justify its latency and GPU use.

## Where Jev can help

The present [Jev adapter](../lib/tiny_axe/decider/jev.ex) posts conversation state and questions to `https://api.typesafe.ai/v1/systemone`. Using that adapter would send memory content off the machine. It therefore cannot participate under the stated restriction, even if the rest of the app has a Jev key configured.

There is no local Jev runtime wired into this repository. TypeSafe's enterprise page lists on-premises deployment as a question, but that is not enough to establish an installable model compatible with this GPU. Treat an actual local Jev installation as a conditional integration, not a prerequisite or a promised capability. [TypeSafe enterprise information](https://typesafe.ai/enterprise)

If an on-machine Jev runtime becomes available and is verified to operate without forwarding requests, evaluate it for three narrow jobs: ranking whether a retrieved passage addresses a question, detecting when evidence is insufficient, and flagging disagreement between cited passages. It must never remove exact matches from the user's results or decide what source text gets retained.

Meanwhile, the existing local decider offers the same general typed-question approach using Ollama. Evaluate that with the pinned local Gemma model; do not describe it as Jev itself or assume equivalent calibration. An unavailable or uncertain judgment should produce “unknown” and preserve access to the original evidence. Compare any additional judging step against Gemma alone before making it mandatory.

## Enforcing local operation

Memory needs its own explicit inference dependency. Do not route it through the globally configured decider, agent escalation, or the website's `chat_search` and `chat_read` tools. Runtime configuration currently selects hosted Jev when a key exists; the memory path must remain local regardless of that setting.

Use a locally installed Gemma model through a verified loopback Ollama endpoint. Validate the configured model is served locally; a loopback URL pointing to a cloud-forwarding service does not meet the requirement. Disable external redirects and cloud fallback. If local inference is unavailable, keep ordinary search working and explain why an interpreted answer is unavailable.

Keep queries, excerpts, answers, annotations, and their logs out of website sync, remote agents, and remote review. This needs attention to persistence too: saving a local answer into an otherwise automatically synced transcript would send it away later. Define and enforce a local-only conversation policy for memory sessions, including later reopening and model selection, rather than checking only the immediate API call. Export would be a separate explicit action. Existing historical uploads are not erased by changing future behavior.

Keep the index, its temporary files, and generated annotations under the private state directory with owner-only permissions. Reuse saved redacted text and avoid recording full passages in diagnostic logs. Account setup, a graph connection, and internet access must not be required for memory search. Installing model weights and dependencies is a separate setup step; normal operation should succeed with external networking blocked.

Verify GPU residency during a real local answer instead of assuming that using Ollama proves GPU execution. Ollama documents `ollama ps` and its processor field for checking this. Model sizing should follow measurements on this machine. [Ollama GPU verification](https://docs.ollama.com/faq#how-can-i-tell-if-my-model-was-loaded-onto-the-gpu)

## Implementation sequence

### First make the archive complete and searchable

Audit forward transcript persistence, including tool output, and establish the local conversation policy. Add the rebuildable index, initial backfill, incremental updates, freshness reporting, and direct word, phrase, and literal search. Add result excerpts and opening the source position. This milestone must work with Ollama stopped and without an account.

### Then let Gemma retrieve and answer

Add the dedicated local recall path, bounded search and read operations, evidence budgeting, citations, and understandable failure states. Enforce local model selection independently of all global model settings. Demonstrate a question answered from an old passage in the middle of a long chat.

### Then add background review and evaluate the decider

Add incremental Gemma enrichment as the useful successor to the removed graph-oriented review. Evaluate the local decider's contribution to relevance and insufficient-evidence checks. Add actual Jev only if its local deployment is independently established. Backfill from original saved transcripts; retired review artifacts are neither required nor sufficient.

### Finish migration and release checks

Update help and historical planning notes so they no longer promise website or graph dependencies for this workflow. Verify the packaged application's database support, recovery behavior, GPU use, and operation with external networking disabled. Ensure installation preserves the new memory data while existing legacy cleanup remains separate. No graph UI, vector database, embedding service, model training, or unrelated app rewrite is needed for this release.

## Acceptance criteria

| Area | Evidence required before release |
| --- | --- |
| Search coverage | Find known words and phrases in old chats, middle sections beyond the current review cutoff, long entries, and newly saved turns. Compare deterministic search results against an independent exhaustive scan. |
| Text semantics | Exercise case, accents, repeated words, punctuation, quotes, code identifiers, symbols, short literals, and phrase boundaries. Exact searches must not fabricate a match across messages. |
| Persistence | Restart, reopen and extend a chat, replace a revision, delete a source, interrupt indexing, and rebuild. No duplicates, stale citations, or silently omitted corrupt files. |
| Local isolation | Set the app's global backend to hosted Jev or Claude, then run memory tasks with those adapters configured to fail if called. Confirm zero invocations, zero uploads, and successful operation with external networking blocked. |
| Model failure | Stop Ollama, fill the GPU, return malformed query plans, and exhaust the search budget. Direct search remains available and no remote fallback occurs. |
| Answer quality | Use fixed questions with known evidence, conflicting claims, and unanswerable questions. Check citations and whether answers are supported; a model score alone is insufficient. |
| Responsiveness | Measure indexing cost and search p50/p95 on representative archives, including 10,000 chats. Target ordinary warmed searches below 250 ms on this machine; record actual results and slower literal scans separately. |
| GPU operation | Observe the intended local Gemma model using the GPU while answering. Confirm background review yields to foreground work. |

The release demonstration is simple: save a distinctive phrase in the middle of an old conversation, restart the app, find it directly, ask Gemma what was decided around it, open the cited original passage, and repeat with the internet unavailable. Add a new conversation and show it becoming searchable. The bank is useful when those actions are dependable.
