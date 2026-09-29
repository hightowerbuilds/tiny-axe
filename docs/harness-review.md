# Harness review: methodology, reliability, and local model performance

Review date: 2026-09-28  
Code baseline: `b30ebcf7445da187301bdb9643333e4f22bb0a3b`  
Status: assessment and proposed work; recommendations are not implemented by this document.

## Assessment

tiny-axe is a promising harness for small, bounded tasks, with thoughtful recovery
engineering. Its clearest strength is turning a model's proposals into structured
operations that software can validate, present for approval, execute, and recover.
Its weakest methodological assumption is that repeated model judgments establish
that an answer is correct.

The architecture should help small local models with explicit file operations,
short documents, and isolated code. Substantial repository changes remain limited
by context discovery, whole-file editing, and the absence of a general project
validation and repair loop. Adding more judgment stages alone could increase
latency without increasing correctness.

The development principle should be:

> Let the model propose; let software check what software can check. Use model
> judgments as measured decision signals, and represent uncertainty explicitly.

## Scope and evidence

This review covers the source, configuration, documentation, and test coverage.
The primary model comparison is the configured `gemma4:e4b-it-qat` and the
documented alternative `qwen3.5:4b`. Gemma 12B was also installed on the reviewed
machine, but was not evaluated.

Three kinds of evidence must remain distinct:

| Evidence | What this review establishes |
| --- | --- |
| Source inspection | Current control flow, thresholds, validation behavior, context selection, and recovery design |
| Runtime inspection | A snapshot of hardware, installed models, and current Ollama placement |
| Model documentation | Supported modes and vendor guidance; not measured performance in tiny-axe |

No task-success benchmark, end-to-end latency benchmark, calibration experiment,
or new test-suite execution was performed for the review. Expected performance
below is an engineering assessment, not a measured success rate. Existing tests
provide useful coverage of mechanics; their presence does not establish model
quality or prove every advertised guarantee.

Source links are relative to this document and refer to the current checkout.
Function names identify the reviewed behavior even if line numbers change.

## Current architecture

The main request flow is implemented in
[`TinyAxe.Pipeline`](../lib/tiny_axe/pipeline.ex):

1. Ask the decider seven routing questions: task kind, web, files, changes,
   organization, another location, and commands.
2. Optionally choose another folder from real candidates.
3. Optionally search the web and attach source material.
4. Dispatch to the answer pipeline, organizer, or commander.

The branches differ materially:

| Branch | Generation and validation | Execution |
| --- | --- | --- |
| Answer | Attach selected files; generate; compile/doctest supported snippets; ask a verifier; retry within a limit | Proposed whole-file edits go to individual approval dialogs |
| Organizer | Generate a fixed JSON plan; expand and simulate operations; review steps; generate document contents | Approved plans run through the journal and operation runner |
| Commander | Generate commands; check working folder and command patterns; review commands | Approved commands run in bubblewrap, then their output is judged |

The answer editor and organizer are separate write paths. The organizer's
journal, backups, and undo should not be assumed to cover ordinary answer edits
or shell commands.

[`TinyAxe.Session`](../lib/tiny_axe/session.ex) preserves conversation state across
a TUI process restart within the running application. That is distinct from the
on-disk operation journal, which supports recovery after an application restart.

## What is working well conceptually

### Structured planning reduces the burden on small models

[`Organizer`](../lib/tiny_axe/organizer.ex) uses explicit lists for folders,
copies, moves, trash operations, and writes. This reduces the number of formatting
and sequencing decisions the model must make. Separating document generation
from operation planning also prevents one response from carrying every concern.

JSON shape enforcement does not prove semantic correctness, but it makes
deterministic checking possible. That is an appropriate use of a harness.

### Execution feedback gives retries new information

[`CodeCheck`](../lib/tiny_axe/code_check.ex) supplies actual compiler and doctest
output. Feeding that output into a repair attempt is a defensible improvement
over asking for another answer with no explanation of the failure.

Similarly, checking that an operation's source exists, that a destination is
available, or that a plan remains valid after earlier steps supplies facts a
model cannot reliably infer from its own answer.

### Recovery is a substantial part of the product

[`Ops`](../lib/tiny_axe/ops.ex), [`Runner`](../lib/tiny_axe/ops/runner.ex), and
[`Journal`](../lib/tiny_axe/ops/journal.ex) implement simulation, staged writes,
backups, before/after journal events, recovery choices, and undo records.
Recovery tests include interrupted tasks, runner failure, application restart,
and torn journal lines.

These mechanisms improve the consequences of mistakes independently of model
intelligence. They deserve to remain central as capabilities expand.

### Code owns location and execution

[`Location`](../lib/tiny_axe/location.ex) gives the application a persistent
current folder and lets routing choose from real folder candidates. Explicit
`cd` and `pwd` avoid unnecessary inference. Approval separates proposed work
from executed work.

The OTP supervision structure is a sensible fit: UI state, conversation state,
and operation execution have different lifetimes and recovery requirements.

## Findings and recommended changes

### F1. Label probabilities are being treated as correctness probabilities

**Priority: P0 for missing-evidence behavior; P1 for calibration and display.**

In [`Decider.Local.label_distribution/2`](../lib/tiny_axe/decider/local.ex), the
returned top-token probabilities are filtered to valid labels and normalized.
This expresses preference among the captured labels. It does not establish the
probability that the selected decision is correct.

For example, if the returned tokens contain a small probability for `Yes` and
none for `No`, the normalized result can be 100% `Yes`. The omitted label may
have probability outside the returned top-token set. The implementation records
`coverage`, but the routing and acceptance decisions do not use it.

When no valid label appears, the implementation returns a uniform distribution.
For a binary question this is 0.5. Several decisions activate at `>= 0.5`; if
command and organization both receive that fallback, command planning wins the
tie. Approval still prevents automatic command execution, but missing evidence
has been converted into an actionable classification.

The entropy-based `confidence` for choices measures concentration of the
distribution, not factual correctness. The same distinction applies to the
percentages displayed by the TUI.

Recommended changes:

- Represent unavailable or insufficient evidence as `unknown`, separate from a
  valid score. Do not invent a neutral numeric score for transport/parser errors.
- Use label coverage and response validity to decide whether a score is usable.
  Select cutoffs through evaluation rather than assuming a universal threshold.
- Validate first-token and label behavior for each exact model/template/backend.
- Give unknown results an explicit fallback: a bounded retry, a better-informed
  decision, or clarification when intent is required for an action.
- Label uncalibrated values as model scores rather than implying measured odds
  of correctness.

Acceptance criteria: a zero-coverage result cannot activate command, write,
organization, or navigation intent by crossing a numeric threshold; invalid and
unknown decisions remain distinguishable in logs and UI state.

### F2. Verification often adds an opinion without adding evidence

**Priority: P1.**

By default the local generator and decider reuse the same model. Their errors can
be correlated: the model may approve the misconception that produced its answer.
Generated doctests can also encode the same mistaken interpretation as the code.

In `Pipeline.verify_and_finish/6`, low scores without a false-execution claim
lead to another generation at a higher temperature, without specific criticism.
The compiler-error path does provide concrete feedback and is methodologically
stronger.

The highest-rated attempt is only a useful choice if the judge can discriminate
between correct and incorrect candidates. The default acceptance threshold is a
retry target, not a correctness guarantee. At the attempt limit, the pipeline can
return a below-threshold candidate. If code fails on the last attempt and there
is no earlier verified candidate, it can return that failed-code answer too.

Organizer and commander reviews also permit proposals to reach user approval
after review uncertainty or failure. Human approval is still present, but an
unavailable review should not look like a successfully completed review.

Recommended changes:

- Separate evidence states: passed deterministic checks, failed checks, skipped
  checks, model-reviewed, and review unavailable.
- Prefer independent expected results, existing tests, and observable task
  postconditions over another generic correctness question.
- Make semantic retry feedback identify a missing requirement or a concrete
  contradiction when possible.
- Evaluate whether retries improve final outcomes, including cases where a
  correct initial answer is replaced by a worse answer.
- Preserve failure and uncertainty when presenting a best-effort final answer.

Jev supplies a separate judgment backend and may improve decisions. Its
calibration and error-detection performance on tiny-axe tasks remain unmeasured;
switching backends does not by itself validate the percentages.

### F3. Context discovery limits repository work

**Priority: P1.**

`Pipeline.pick_files/3` shortlists by words in file paths. With the local
decider's 16-option limit and the reserved `(none)` option, only 15 candidate
files reach the choice question. Up to three are attached based on a single
choice distribution and the configured minimum probability.

A task can require a caller, implementation, type definition, configuration, and
test simultaneously. A single-choice distribution divides probability between
complementary files. Files with generic names can disappear during shortlisting
before the model has seen their contents.

The answer branch does not implement a general inspect/search/edit/test/repair
loop. Its code checker evaluates standalone Elixir/Python snippets, and checks
can be skipped when required packages are unavailable. Whole-file replacements
increase output length and the chance of dropping unrelated code.

Recommended changes:

- Add bounded content and symbol search, reference lookup, and focused reads.
- Track which files and ranges were inspected and why they are relevant.
- Evaluate independent file relevance or explicit multi-file selection rather
  than treating all relevant files as mutually exclusive choices.
- Introduce targeted edits with version checks and reviewable diffs.
- Validate changes using the project's actual build and relevant existing tests.
- Feed real project failures back into a bounded repair loop.

Acceptance criteria: fixture tasks requiring several related files succeed
without relying on filenames alone, and generated changes are checked in their
project context. Missing dependencies must remain a skipped check, not a pass.

### F4. Routing and verification lose conversational intent

**Priority: P1.**

`Pipeline.run/3` routes using only the latest request and current folder.
It does not supply history or a conversation summary. Requests such as “now run
it,” “put those there,” or “make the same change in the other file” can therefore
be misrouted before the generator receives conversation context.

The answer verifier receives the constructed request and attached evidence, but
not the full relevant conversation. Organizer and commander planning receive
limited recent history; their reviews do not consistently receive equivalent
intent context.

Recommended changes:

- Construct a bounded request context shared across routing, generation, and
  review: original request, relevant recent turns, summary, location, and known
  execution results.
- Preserve exact paths and referents when resolving follow-ups.
- Keep ambiguous intent explicit rather than inventing what a pronoun means.
- Treat quoted source material and command output as evidence, not instructions
  that can authorize new actions.

Acceptance criteria: multi-turn fixtures cover pronouns, repeated changes,
location changes, and requests referring to actual prior command results.

### F5. Conversation compaction is not a complete request budget

**Priority: P1.**

[`Context`](../lib/tiny_axe/context.ex) estimates conversation size and
[`Compactor`](../lib/tiny_axe/compactor.ex) summarizes older turns. A complete
request also includes system instructions, file listings, file contents, web
pages, retry messages, and space for the answer.

At the configured 8,192-token window, the 12,000-character file budget plus web
material and conversation can become tight. `Pipeline.attach/1` also gives each
file at least 2,000 characters, so many explicit mentions can exceed the nominal
shared file budget. Document generation has separate per-source reads.

Recommended changes:

- Budget every assembled request before sending it, including planning,
  verification, retries, and document generation.
- Reserve output space and, when enabled, a reasoning allowance.
- Prioritize relevant excerpts and report omitted/truncated evidence.
- Compact or reduce inputs before an oversized request, not only after answers.
- Measure estimates against actual usage and record truncation/length failures.

A larger context window may help, but it does not fix irrelevant retrieval or
missing evidence and has runtime costs that must be measured.

### F6. The current-folder exception bypasses a command boundary

**Priority: P0.**

[`Commander.workable?/1`](../lib/tiny_axe/commander.ex) accepts a folder when it
equals `Files.root()` or satisfies `Ops.changeable?/1`. `Files.root()` is the
current folder. Since the application can start in home, home can pass through
the current-folder exception despite the stated prohibition. A hidden current
folder can similarly bypass the hidden-folder rule.

[`Shell.args/2`](../lib/tiny_axe/shell.ex) overlays home and then bind-mounts the
working directory writable. If home itself is selected, that final mount
undermines the intended restriction on persistent changes elsewhere in home.

Recommended changes:

- Apply explicit forbidden-root and hidden-folder checks before any project
  exception.
- Revalidate the approved execution boundary immediately before execution.
- Add regression cases where home or a hidden folder is the current project.
- Test filesystem containment separately from model routing and approval.

This is a source-confirmed policy bypass, not a demonstrated malicious exploit.
User approval is still required. The shell sandbox also permits network access
and visibility of home contents; write containment must not be described as
complete data-access isolation.

### F7. Ordinary edits capture their comparison version too late

**Priority: P0.**

[`Files.proposed_edits/1`](../lib/tiny_axe/files.ex) reads the old contents when
processing the generated response. `Files.write/3` then compares the file against
that value. This catches changes made after the proposal was created, but can
miss changes made while the model was generating from an earlier version.

Example: the model reads version A, an editor saves version B during generation,
and the proposal records B as its old contents. The write check accepts B even
though the generated replacement was based on A. The diff is still shown for
approval, but the advertised stale-input protection is incomplete.

Recommended changes:

- Capture file identity and contents/hash when attaching it to model context.
- Carry that snapshot through generation, proposal review, and application.
- Refuse stale edits and require a fresh read and proposal.
- Define separate behavior for new files and files never read by the model.

Acceptance criteria: a file changed after attachment but before generation
finishes cannot be overwritten under the original proposal. This finding concerns
ordinary answer edits; organizer writes have a different old-content/hash path.

## Realistic performance with Gemma and Qwen

### Model configuration matters

The baseline configuration uses `gemma4:e4b-it-qat`, an 8K context, and
`think: false`. The local decider explicitly disables thinking and requests one
output token. Switching the generation model also switches the local judge unless
`decider_model` is configured separately.

Both Gemma 4 and Qwen3.5 document thinking modes. Disabling thinking is a reasonable
latency hypothesis for simple classification, but planning and code generation
should be evaluated separately. Their sampling guidance also differs; the shared
low-temperature settings are not a demonstrated optimum for both models.
See the [Gemma model card](https://ai.google.dev/gemma/docs/core/model_card_4) and
[Qwen3.5-4B model card](https://huggingface.co/Qwen/Qwen3.5-4B).

Those model cards establish that both are credible coding candidates, not that
either wins in this harness. Published results do not reproduce these exact
quantizations, prompts, retrieval, thinking settings, or verification policy.
Vendor sampling recommendations should be treated as experimental starting points,
not blindly copied into deterministic classification.

### Expected task suitability

These expectations apply to either primary model with the current workflow.

| Task | Expected suitability | Main limiting factor |
| --- | --- | --- |
| Explicit moves, copies, and renames | Strong candidate for useful results | Correct interpretation and operation boundaries |
| Short documents from identified sources | Useful with review | Omissions, truncation, and unsupported statements |
| Small standalone functions | Useful with independent checks | Weak or self-confirming tests |
| Familiar setup/build commands | Useful with approval | Environment assumptions and lack of iterative repair |
| Follow-ups across several turns | Inconsistent | Missing intent context in routing and review |
| Substantial repository changes | Limited | Retrieval, whole-file edits, and project validation |
| Open-ended autonomous development | Not established | No general evidence-driven development loop |

Do not convert this table into success percentages without measurements. Even
simple file tasks need fixtures for ambiguity, name collisions, and changed state.

### Observed machine snapshot

The review observed:

- NVIDIA GeForce GTX 1080 with 8,192 MiB VRAM.
- Ollama version 0.34.4.
- Installed primary models: Gemma E4B QAT and Qwen3.5 4B.
- `ollama ps` reported Gemma E4B at 100% GPU placement, with an 8,192-token
  context and a displayed size of 3.1 GB.

This is encouraging for the current Gemma configuration, but it establishes
neither latency nor comparative throughput. Model download size is not equivalent
to runtime GPU allocation. Qwen placement, cold-start behavior, and Gemma 12B
performance were not measured. The snapshot may change with other workloads.

### Request count is a likely latency bottleneck

For a basic answer with local decisions and no optional retrieval or navigation:

| Stage | Ollama requests |
| --- | ---: |
| Seven routing questions | 7 |
| One answer generation | 1 |
| Two verification questions | 2 |
| Total for a first-attempt answer | 10 |

This is request count, not sequential round-trip count. Local decision questions
run concurrently, but Elixir task concurrency does not guarantee equal GPU
parallelism. One-token outputs still incur input processing and scheduling costs.
Prefix caching may reduce repeated input work; it should be measured.

Retrieval, navigation, planning reviews, retries, document generation, and
compaction add more requests. Changing decider models may introduce residency or
reload costs. Jev changes the latency and resource profile by moving decisions to
a remote backend; it introduces its own network/service behavior.

Measure time to the first useful answer and time to final accepted output. A fast
token-generation rate can coexist with a slow user experience if orchestration
dominates the turn.

## Evaluation plan

### Build a reproducible fixture set

Start with approximately 60–100 tasks, with a separate development subset for
threshold tuning and a held-out subset for final comparison. Include realistic
requests and deliberately difficult boundary cases.

| Category | Example cases | Independent evidence |
| --- | --- | --- |
| File operations | Wildcards, collisions, move versus copy, interrupted plans | Exact before/after trees, hashes, and recovery results |
| Documents | Required facts from sources, absent facts, conflicting sources | Requirement checklist and human review |
| Standalone code | Normal inputs, edge cases, ambiguous requirements | Tests authored independently of generated code |
| Repository edits | Related files, generic filenames, existing failures | Existing tests, targeted regression tests, diff review |
| Commands | Successful build, nonzero exit, zero exit with cancellation | Artifacts and expected postconditions |
| Conversation | “Run it,” changed location, repeated edits | Explicit intended route, referents, and scope |
| Decision failures | Missing labels, malformed responses, unavailable judge | Expected unknown/error behavior |

Run mutation cases in disposable fixtures, never real user folders. Replace
interactive approval with a recorded fixture policy only inside the evaluation
runner; do not remove approval from the application. Record whether a dangerous
proposal was offered separately from whether a test policy allowed execution.

### Compare configurations that isolate causes

For each primary model, compare:

1. Direct generation with equivalent supplied evidence.
2. Generation plus deterministic feedback and bounded repair.
3. The full harness with local routing and verification.
4. The full harness with Jev, if configured and within an agreed evaluation budget.

Separately compare bounded thinking versus no thinking for planning/generation,
and only then consider alternative generator/judge pairings. Keep task fixtures,
available evidence, output limits, and total retry budgets comparable. For ordinary
Q&A, direct chat is a useful baseline; for action tasks, the baseline must still
use the same validated executor and approval policy.

Use two experiment types: fixed-evidence tests to isolate generation/judging, and
end-to-end tests to measure retrieval and routing as well. Otherwise a context
selection failure may be incorrectly attributed to model capability.

Repeat stochastic cases and report variability. Hold runtime versions and model
digests fixed. Record warm/cold state and avoid concurrent unrelated workloads.
Do not tune thresholds on the held-out results.

### Record outcomes and costs

Each run should record task ID, source revision, model digest, backend, quantization,
context size, thinking/sampling settings, attempt count, selected files, decision
scores/coverage, validation outcomes, and final result.

Measure:

- Final task success, reported separately by category.
- Route accuracy and unknown/clarification rate.
- False acceptance: incorrect candidates approved by the verifier.
- False rejection: correct candidates rejected by the verifier.
- Retry benefit and retry regressions, comparing first and final candidates.
- Unsafe proposals, out-of-scope changes, and containment failures.
- Median and tail latency, including time to first useful output.
- Request count, input/output tokens, load time, and prompt/generation time.
- Recovery correctness and preservation of files changed independently.

Ollama exposes timing and token fields suitable for this instrumentation; the
current client reports only part of that information to the application.
See the [Ollama chat API](https://docs.ollama.com/api/chat).

For calibration, compare score bins with independently labeled correctness and
show sample counts. Until a score is validated as a probability, call this an
empirical score-to-correctness relationship. A small pilot can expose gross
problems but cannot substantiate fine-grained confidence claims.

Collect enough trace information to explain failures without retaining secrets
or real user documents by default. Store aggregate results and reproducible
fixture references in the repository; keep sensitive/raw traces out of it.

## Prioritized implementation plan

| Order | Work | Completion evidence |
| --- | --- | --- |
| P0 | Enforce command boundaries independently of the current folder (F6) | Home/hidden-current-folder regressions and sandbox containment checks |
| P0 | Preserve the model's input file snapshot (F7) | Concurrent-edit regression refuses stale proposals |
| P0 | Represent invalid/unknown decisions explicitly (F1) | Zero coverage and backend failure cannot masquerade as actionable scores |
| P1 | Add shared conversational request context (F4) | Multi-turn routing/review fixtures |
| P1 | Budget complete requests (F5) | Oversized context cases reduce inputs predictably and preserve essential evidence |
| P1 | Add instrumentation and the evaluation baseline | Reproducible results with per-stage latency and independent correctness |
| P1 | Improve retrieval, targeted edits, and project validation (F3) | Multi-file tasks validated against actual project tests |
| P1 | Make verification and retry outcomes evidence-aware (F2) | Measured improvement over deterministic-feedback-only baseline |
| P2 | Tune routing calls, model settings, and backend combinations | Lower latency without unacceptable correctness regressions |

This order prioritizes known correctness issues before architectural expansion.
The evaluation set should grow alongside fixes, not wait until all features are
complete. Avoid changing model, prompts, thresholds, retrieval, and retry policy
simultaneously in one experiment.

## Release and product claims

Before describing the harness as reliably handling broad filesystem or repository
work, require evidence appropriate to that claim:

- Known boundary and stale-edit cases have deterministic regression coverage.
- The user can distinguish checked, failed, skipped, uncertain, and best-effort
  outcomes.
- Local and remote decision modes each have measured task outcomes.
- Recovery behavior is tested independently of the happy path.
- Repository changes are validated in the actual project context.

The current strongest product direction is a supervised local assistant for
bounded tasks, especially structured file operations. Expanding that direction
should be driven by better evidence, context, and validation. More model calls
are justified only when they demonstrably improve the final outcome.

## References

- [Runtime defaults](../config/config.exs)
- [Pipeline](../lib/tiny_axe/pipeline.ex), [local decider](../lib/tiny_axe/decider/local.ex), and [Jev backend](../lib/tiny_axe/decider/jev.ex)
- [Files](../lib/tiny_axe/files.ex), [organizer](../lib/tiny_axe/organizer.ex), and [operation design](plan-file-operations.md)
- [Commander](../lib/tiny_axe/commander.ex), [shell sandbox](../lib/tiny_axe/shell.ex), and [code checker](../lib/tiny_axe/code_check.ex)
- [Existing tests](../test/tiny_axe/)
- [Google Gemma 4 model card](https://ai.google.dev/gemma/docs/core/model_card_4)
- [Qwen3.5-4B model card](https://huggingface.co/Qwen/Qwen3.5-4B)
- [Ollama chat API](https://docs.ollama.com/api/chat)
