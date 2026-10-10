defmodule TinyAxe.Browser.Examples do
  @moduledoc """
  Validated memory for the browser agent: a small, versioned set of
  reviewed lessons, a few of which are retrieved for the task at hand and
  shown to the driver, the same way for every driver. Advice only: nothing
  here is consulted by assessment, approvals, holds, verification,
  completion or purchases (`TinyAxe.Browser.Decisions`,
  `TinyAxe.Tools.BrowserPolicy`, `TinyAxe.Purchases`), so no example can
  change a policy, a threshold, an approval or a purchase control, and
  switching retrieval off leaves every check as it was.

  ## A lesson

  Each example (`browser-example/1`) is one chain, in this order:

  > objective and constraints → observed evidence → candidate actions →
  > Jev answers → policy disposition → executed action → verified result →
  > correction

  with the workflows and signals it's retrieved for, how it was validated
  (`label`), and the versions it was learned under (evidence schema,
  policy, question versions). It names no element ref and no decision,
  action or observation id: those belong to one page and one task, and an
  example is never a way to reuse them.

  ## What makes an example trusted

    * **validated** — only an independent fixture assertion (a
      development task's own state check passed; never a holdout task) or
      a person's review (`mix tiny_axe.browser_examples promote`). The
      user's approval, a tool's success, Jev agreeing, or an agent saying
      it worked are not labels, and are refused as such
    * **settled** — its verified result is succeeded, failed or not done;
      anything unresolved or pending stays out until it's resolved
    * **its lesson is ours** — a correction is written by a curator, a
      reviewer, or taken from fixed templates keyed by the harness's own
      reason codes; never from page text or an agent's words. A captured
      candidate keeps page text only as quoted evidence
    * **current** — learned under the versions in use now; an example from
      older questions or evidence is never retrieved

  ## Retrieval

  `config :tiny_axe, :browser_examples` is `:off`, `:shadow` (the default
  until measured: retrieved and recorded in the task journal, never shown)
  or `:on`. It's separate from `:browser_choose`. When on:

    * at the start of a task, up to two examples for its workflow (from the
      user's own words: shopping, booking, settings, messaging...) go into
      the shared system prompt (`briefing/1`)
    * after a browser call, the harness's own facts about it (reason codes,
      what the action came to, what verification said, whether the user said
      no) become signals; up to two examples for them, not yet shown in this
      task, are added to that call's result (`render/2`), with a compact
      record of this task's failed and unresolved actions (`attempts/1`)

  At most #{4} examples per task.

  ## Keeping, inspecting and forgetting

  See `TinyAxe.Browser.Examples.Store` (files and versions) and
  `mix tiny_axe.browser_examples` (list, show, delete, restore, expire,
  rollback, candidates, promote). Reusable content from real sessions is
  kept only with `config :tiny_axe, :browser_examples_persist, true`
  (default false): then a finished task's lesson-worthy actions become
  candidates, with their redacted evidence kept apart from the journals for
  `:browser_examples_retention_days` (30); a candidate is never retrieved
  until a person promotes it.
  """

  require Logger

  alias TinyAxe.Browser.{Evidence, Outcomes}
  alias TinyAxe.Browser.Examples.Store
  alias TinyAxe.Tools.{BrowserPolicy, Redact}

  @schema "browser-example/1"
  @version "browser-examples/1"
  @journal "browser-examples-use/1"

  @per_step 2
  @at_start 2
  @per_task 4

  @labels ~w(fixture_assertion human_review)
  # What is never a label: approval, a tool's success, Jev agreeing, an
  # agent's own report.
  @not_labels ~w(user_approval tool_success jev_agreement agent_report)
  @lesson_sources ~w(curator human_review template)
  @settled ~w(succeeded failed not_executed)

  @top ~w(schema id rev title origin workflows signals label versions chain created_at expires_at)
  @chain ~w(objective constraints observed candidates answers disposition executed verified correction)

  @workflows ~w(shopping booking settings messaging publishing forms search)
  @signals ~w(autosave lost_response repeat_held stale_target user_declined purchase_blocked
              uncertain value_mismatch site_rejected not_observed)

  @text_chars 400
  @candidate_chars 160

  # Refs from a snapshot (e12, f1e12, re3) and gate ids (asm-, act-, ver-,
  # cho-, dec-, obs-): never part of a lesson.
  @refs ~r/\b(?:f\d+)?r?e\d+\b|\bref=|\b(?:asm|act|ver|cho|dec|obs)-[0-9a-f]{3,}/i

  # The user's own words, without addresses, name the workflow. Set on the
  # development tasks' objectives.
  @workflow_words [
    {"shopping", ~r/\b(cart|trolley|basket|buy|order|purchase|checkout)\b/i},
    {"booking", ~r/\b(book|booking|reserve|reservation|appointment|slot|table for)\b/i},
    {"settings",
     ~r/\b(settings?|preferences?|profile|display name|timezone|newsletter|instructions|notes|contacts? me|home store|change (my|how|the)|set my|make \w+ my)\b/i},
    {"messaging", ~r/\b(send|reply|forward|e-?mail|message|ask|question)\b/i},
    {"publishing", ~r/\b(post|publish|comment|review)\b/i},
    {"forms", ~r/\b(report|apply|renew|submit|register)\b/i},
    {"search", ~r/\b(find|search|cheapest|compare|look up)\b/i}
  ]

  # The harness's reason codes, as retrieval signals.
  @refusal_signals %{
    "stale_target" => "stale_target",
    "target_not_found" => "stale_target",
    "outcome_unresolved" => "repeat_held",
    "constraint_mismatch" => "purchase_blocked",
    "purchases_disabled" => "purchase_blocked",
    "insufficient_evidence" => "uncertain",
    "decision_unavailable" => "uncertain"
  }
  @outcome_signals %{
    "save_unproven" => "autosave",
    "response_lost" => "lost_response",
    "server_error" => "lost_response",
    "value_mismatch" => "value_mismatch",
    "request_rejected" => "site_rejected",
    "error_shown" => "site_rejected",
    "effect_not_observed" => "not_observed"
  }

  # Corrections for captured candidates: fixed text, by signal, never
  # anything a page or an agent wrote.
  @templates %{
    "autosave" =>
      "Reload the same page the field is on, stay on it, then call browser_verify with the action id; tell the user only what it confirms.",
    "lost_response" =>
      "Don't send it again. Load the page it was sent from afresh, then call browser_verify; if it still can't be confirmed, tell the user it's unconfirmed.",
    "repeat_held" =>
      "It may already have gone through: don't repeat it. Reload the page it was sent from and call browser_verify, or tell the user.",
    "stale_target" =>
      "Take a fresh snapshot and use the element's new ref: a stale target is a repair, not a refusal.",
    "user_declined" =>
      "The user said no: don't try it another way; tell the user what wasn't done.",
    "purchase_blocked" =>
      "Stop and tell the user why the purchase can't go ahead; never look for another way to buy.",
    "uncertain" =>
      "Look more closely (snapshot or extract) or hand off to the user; don't guess.",
    "value_mismatch" =>
      "The field doesn't hold what was typed: check it, type it again only if the user still wants it, then verify.",
    "site_rejected" =>
      "Read what the page says went wrong; fix it if you can, otherwise tell the user.",
    "not_observed" =>
      "Look at the page that should show the effect (reload the list), verify again, or tell the user it's unconfirmed."
  }

  ## Switches

  @doc "`:off`, `:shadow` (retrieved and recorded, never shown) or `:on`."
  @spec mode() :: :off | :shadow | :on
  def mode do
    case Application.get_env(:tiny_axe, :browser_examples, :shadow) do
      mode when mode in [:off, :shadow, :on] -> mode
      _ -> :shadow
    end
  end

  @doc "Whether reusable content from real sessions may be kept (default false)."
  def persist?, do: Application.get_env(:tiny_axe, :browser_examples_persist, false) == true

  def retention_days,
    do: Application.get_env(:tiny_axe, :browser_examples_retention_days, 30)

  @doc "The versions an example must have been learned under to be retrieved now."
  def current_versions do
    policy = BrowserPolicy.versions()
    outcomes = Outcomes.versions()

    %{
      "evidence" => Evidence.schema(),
      "policy" => policy.policy,
      "questions" => policy.questions,
      "outcome_questions" => outcomes.questions,
      "examples" => @version
    }
  end

  def schema, do: @schema
  def signals_known, do: @signals
  def workflows_known, do: @workflows
  def templates, do: @templates

  ## Validation

  @doc """
  Checks an example against the schema and the trust rules (see the
  module doc). Returns `{:ok, example}` or `{:error, reasons}`.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, [term()]}
  def validate(%{} = ex) do
    chain = ex["chain"]

    errors =
      shape_errors(ex) ++
        chain_errors(chain) ++
        Enum.filter(
          [
            label_error(ex["label"]),
            settled_error(chain),
            lesson_error(chain),
            refs?(ex) && :refs_or_ids,
            too_long?(chain) && :too_long
          ],
          & &1
        )

    if errors == [], do: {:ok, ex}, else: {:error, errors}
  end

  def validate(_), do: {:error, [:not_a_map]}

  @doc "Whether a label is one that can make an example trusted."
  @spec label_error(term()) :: nil | term()
  def label_error(%{"kind" => kind} = label) when kind in @labels do
    case kind do
      "fixture_assertion" ->
        cond do
          label["split"] != "dev" -> {:label, :holdout_or_unknown_split}
          label["passed"] != true -> {:label, :assertion_not_passed}
          not is_binary(label["task"]) -> {:label, :no_task}
          true -> nil
        end

      "human_review" ->
        if is_binary(label["reviewer"]) and String.trim(label["reviewer"]) != "",
          do: nil,
          else: {:label, :no_reviewer}
    end
  end

  def label_error(%{"kind" => kind}) when kind in @not_labels, do: {:not_a_label, kind}
  def label_error(_), do: {:label, :missing}

  defp shape_errors(ex) do
    unknown = Map.keys(ex) -- @top

    [
      ex["schema"] != @schema && {:schema, ex["schema"]},
      not (is_binary(ex["id"]) and ex["id"] =~ ~r/\A[a-z0-9][a-z0-9-]{1,60}\z/) && :id,
      unknown != [] && {:unknown_fields, unknown},
      not (is_list(ex["workflows"]) and ex["workflows"] -- @workflows == []) && :workflows,
      not (is_list(ex["signals"]) and ex["signals"] -- @signals == []) && :signals,
      not is_map(ex["versions"]) && :versions
    ]
    |> Enum.filter(& &1)
  end

  defp chain_errors(chain) when is_map(chain) do
    missing = @chain -- Map.keys(chain)
    extra = Map.keys(chain) -- @chain

    Enum.filter(
      [missing != [] && {:missing, missing}, extra != [] && {:unknown_fields, extra}],
      & &1
    )
  end

  defp chain_errors(_), do: [:chain]

  defp settled_error(%{"verified" => %{"status" => status}}) when status in @settled, do: nil
  defp settled_error(%{"verified" => %{"status" => status}}), do: {:unsettled, status}
  defp settled_error(_), do: {:unsettled, nil}

  defp lesson_error(%{"correction" => %{"text" => text, "source" => source}})
       when is_binary(text) and source in @lesson_sources,
       do: nil

  defp lesson_error(%{"correction" => %{"source" => source}}), do: {:lesson_source, source}
  defp lesson_error(_), do: {:lesson_source, nil}

  defp refs?(ex), do: ex |> strings() |> Enum.any?(&(&1 =~ @refs))

  defp too_long?(chain) when is_map(chain) do
    chain
    |> Map.delete("candidates")
    |> strings()
    |> Enum.any?(&(String.length(&1) > @text_chars)) or
      Enum.any?(
        List.wrap(chain["candidates"]),
        &(String.length(to_string(&1)) > @candidate_chars)
      ) or
      length(List.wrap(chain["candidates"])) > 5
  end

  defp too_long?(_), do: false

  defp strings(s) when is_binary(s), do: [s]
  defp strings(%{} = m), do: m |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(l) when is_list(l), do: Enum.flat_map(l, &strings/1)
  defp strings(_), do: []

  ## The active set

  @doc """
  The examples retrieval may use now: the active set's valid examples
  learned under the current versions and not expired. Invalid ones are
  skipped (and logged), never shown.
  """
  @spec usable(DateTime.t()) :: [map()]
  def usable(now \\ DateTime.utc_now()) do
    current = current_versions()

    for ex <- Store.active()["examples"] || [],
        valid?(ex),
        current?(ex, current),
        not expired?(ex, now),
        do: ex
  end

  defp valid?(ex) do
    case validate(ex) do
      {:ok, _} ->
        true

      {:error, why} ->
        Logger.warning("tiny-axe skipped browser example #{inspect(ex["id"])}: #{inspect(why)}")
        false
    end
  end

  @doc "Whether an example was learned under these versions (every key it names must match)."
  def current?(ex, current \\ current_versions()) do
    versions = ex["versions"] || %{}

    Enum.all?(~w(evidence policy questions outcome_questions), &Map.has_key?(versions, &1)) and
      Enum.all?(versions, fn {k, v} -> current[k] == v end)
  end

  @doc "Whether an example's expiry date has passed."
  def expired?(%{"expires_at" => at}, now) when is_binary(at) do
    case Date.from_iso8601(String.slice(at, 0, 10)) do
      {:ok, date} -> Date.compare(date, DateTime.to_date(now)) != :gt
      _ -> true
    end
  end

  def expired?(_ex, _now), do: false

  ## Retrieval

  @doc "The workflows a request names, from the user's own words (addresses left out)."
  @spec workflows(String.t() | nil) :: [String.t()]
  def workflows(nil), do: []

  def workflows(objective) do
    text = Regex.replace(~r{https?://\S+}, objective, " ")
    for {name, re} <- @workflow_words, text =~ re, do: name
  end

  @doc """
  The retrieval signals in one browser call's facts, all the harness's
  own: `:assessment` (its disposition and reason codes), `:action` (what
  the action came to), `:verification`, `:decision` (`:denied` when the
  user said no). Never page text.
  """
  @spec signals(map()) :: [String.t()]
  def signals(facts) do
    a = facts[:assessment]
    r = facts[:action]
    v = facts[:verification]

    refused =
      if is_map(a) and a.disposition == "refused",
        do: Enum.flat_map(a.reason_codes, &List.wrap(@refusal_signals[&1])),
        else: []

    autosave_code =
      if is_map(a) and "autosave_signal" in a.reason_codes, do: ["autosave"], else: []

    edit_sent =
      if is_map(r) and r.family == "edit" and r.submission == true and
           r.status in [:pending, :unresolved],
         do: ["autosave"],
         else: []

    outcome =
      if is_map(r) and r.status in [:failed, :unresolved],
        do: Enum.flat_map(r.codes, &List.wrap(@outcome_signals[&1])),
        else: []

    verified =
      if is_map(v) and v.status in [:failed, :unresolved],
        do: Enum.flat_map(v.reason_codes, &List.wrap(@outcome_signals[&1])),
        else: []

    declined = if facts[:decision] == :denied, do: ["user_declined"], else: []

    Enum.uniq(refused ++ autosave_code ++ edit_sent ++ outcome ++ verified ++ declined)
  end

  @doc """
  Up to a few examples for a moment in a task. `query`: `:stage`
  (`:start`: by the objective's workflows; `:step`: by signals, at least
  one in common), `:objective`, `:signals`, `:shown` (ids already shown at
  this stage) and `:total` (shown in this task so far).
  """
  @spec retrieve(map(), [map()] | nil) :: [map()]
  def retrieve(query, examples \\ nil) do
    examples = examples || usable()
    flows = workflows(query[:objective])
    signals = List.wrap(query[:signals])
    shown = MapSet.new(List.wrap(query[:shown]))
    room = max(@per_task - (query[:total] || 0), 0)

    common = fn a, b -> length(a -- (a -- List.wrap(b))) end

    {limit, scored} =
      case query[:stage] do
        :start ->
          {@at_start, Enum.map(examples, &{common.(flows, &1["workflows"]), &1})}

        _ ->
          {@per_step,
           examples
           |> Enum.filter(&(common.(signals, &1["signals"]) > 0))
           |> Enum.map(
             &{3 * common.(signals, &1["signals"]) + common.(flows, &1["workflows"]), &1}
           )}
      end

    scored
    |> Enum.reject(fn {score, ex} -> score == 0 or MapSet.member?(shown, ex["id"]) end)
    |> Enum.with_index()
    |> Enum.sort_by(fn {{score, _ex}, i} -> {-score, i} end)
    |> Enum.map(fn {{_s, ex}, _i} -> ex end)
    |> Enum.take(min(limit, room))
  end

  ## What the driver sees

  @header "Reviewed examples from earlier tasks (advice only: they approve nothing, and every " <>
            "check still applies; they describe other pages, so use them for how to work, not " <>
            "as facts about this one):"

  @doc "Examples for the start of a task, for the shared system prompt; empty if none."
  def briefing([]), do: ""
  def briefing(examples), do: @header <> "\n" <> Enum.map_join(examples, "\n", &line/1)

  @doc "Examples added to a call's result, with the task's failed and unresolved actions so far."
  def render([], _attempts), do: ""

  def render(examples, attempts) do
    so_far =
      case attempts do
        [] -> ""
        list -> "\nIn this task so far:\n" <> Enum.join(list, "\n")
      end

    @header <> "\n" <> Enum.map_join(examples, "\n", &line/1) <> so_far
  end

  defp line(ex) do
    c = ex["chain"]
    v = c["verified"]

    label =
      case ex["label"]["kind"] do
        "fixture_assertion" -> "checked by a test site"
        "human_review" -> "reviewed by a person"
      end

    parts = [
      "Task: #{String.trim_trailing(c["objective"], ".")}" <> constraints(c["constraints"]),
      "Seen: #{c["observed"]}",
      "Options: #{Enum.join(List.wrap(c["candidates"]), "; ")}",
      "Jev: #{c["answers"]}",
      "tiny-axe: #{c["disposition"]}",
      "Done: #{c["executed"]}",
      "Result: #{v["status"]}#{codes(v["codes"])}#{if v["note"], do: ": " <> v["note"], else: ""}",
      "Lesson: #{c["correction"]["text"]}"
    ]

    parts = Enum.map(parts, &String.trim_trailing(&1, "."))

    clean(
      "- #{ex["title"] || ex["id"]} (example #{ex["id"]}, rev #{ex["rev"] || 1}, #{label}). " <>
        Enum.join(parts, ". ") <> "."
    )
  end

  defp constraints(nil), do: ""
  defp constraints(""), do: ""
  defp constraints(text), do: " (#{text})"

  defp codes(list) when is_list(list) and list != [], do: " (#{Enum.join(list, ", ")})"
  defp codes(_), do: ""

  # Nothing that could name an element or a decision on this page.
  defp clean(text), do: String.replace(text, @refs, "[ref]")

  @doc """
  The task's failed and unresolved actions so far, newest first, one short
  line each (from the gate's own action records; at most five).
  """
  @spec attempts([map()]) :: [String.t()]
  def attempts(actions) do
    actions
    |> List.wrap()
    |> Enum.filter(&(&1[:status] in [:failed, :unresolved]))
    |> Enum.take(5)
    |> Enum.map(fn r ->
      what = String.slice(r.description || "an action", 0, 120)
      codes = (r.codes || []) -- ["outcome_unresolved"]

      clean(
        cond do
          r.status == :unresolved ->
            "? #{what}: not confirmed (#{Enum.join(codes, ", ")}); don't repeat it"

          r[:decision] == :denied ->
            "✗ #{what}: the user said no; don't try it another way"

          codes == ["not_executed"] ->
            "✗ #{what}: not done (tiny-axe refused it)"

          true ->
            "✗ #{what}: didn't take effect (#{Enum.join(codes, ", ")})"
        end
      )
    end)
  end

  @doc "What the task journal keeps of one retrieval."
  def journal(mode, stage, signals, examples) do
    %{
      schema: @journal,
      mode: mode,
      stage: stage,
      signals: signals,
      shown: mode == :on,
      examples: Enum.map(examples, &%{id: &1["id"], rev: &1["rev"] || 1}),
      set: Store.active()["version"]
    }
  end

  ## Promotion

  @doc """
  Makes a candidate (or a whole example) trusted: adds it to the active set
  as a new version. `label` must be a fixture assertion (a development
  task's check that passed) or a person's review; anything else — the
  user's approval, a tool's success, Jev agreeing, an agent's report — is
  refused. An unsettled result (unresolved, pending) is refused. A
  reviewer may give the lesson in their own words (`opts[:lesson]`).
  """
  @spec promote(map() | String.t(), map(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def promote(candidate, label, opts \\ [])

  def promote(id, label, opts) when is_binary(id) do
    case Store.candidate(id) do
      {:ok, candidate} -> promote(candidate, label, opts)
      :error -> {:error, :no_such_candidate}
    end
  end

  def promote(%{} = candidate, label, opts) do
    label = stringify(label)

    example =
      candidate
      |> Map.take(@top)
      |> Map.merge(%{
        "schema" => @schema,
        "label" => label,
        "rev" => if(candidate["schema"] == @schema, do: (candidate["rev"] || 1) + 1, else: 1),
        "versions" => candidate["versions"] || current_versions(),
        "created_at" => candidate["created_at"] || today(),
        "expires_at" => candidate["expires_at"] || expiry(opts)
      })
      |> reviewer_lesson(label, opts[:lesson])

    with nil <- label_error(label),
         {:ok, ex} <- validate(example) do
      examples =
        (Store.active()["examples"] || [])
        |> Enum.reject(&(&1["id"] == ex["id"]))
        |> Kernel.++([ex])

      with {:ok, version} <- Store.write_set(examples, "promote #{ex["id"]} (#{label["kind"]})") do
        if candidate["candidate"] == true, do: Store.retire_candidate(candidate["id"])
        {:ok, version}
      end
    else
      {:error, why} -> {:error, why}
      error -> {:error, [error]}
    end
  end

  # A person reviewing it may put the lesson in their own words.
  defp reviewer_lesson(ex, %{"kind" => "human_review"}, text)
       when is_binary(text) and text != "" do
    put_in(ex, ["chain", "correction"], %{
      "text" => String.slice(text, 0, @text_chars),
      "source" => "human_review"
    })
  end

  defp reviewer_lesson(ex, _label, _text), do: ex

  defp expiry(opts) do
    days = Keyword.get(opts, :days, 90)
    Date.utc_today() |> Date.add(days) |> Date.to_iso8601()
  end

  ## Inspecting and forgetting

  @doc "The active set: its version and examples."
  def active, do: Store.active()

  @doc "One example in the active set."
  def show(id), do: Enum.find(Store.active()["examples"] || [], &(&1["id"] == id))

  @doc "Every version of the set, with what changed."
  defdelegate history, to: Store

  @doc "Candidates captured but not validated (never retrieved)."
  defdelegate candidates, to: Store

  @doc """
  Takes an example out of the active set (a new version); a copy is kept in
  the store's trash/, so it can be restored. Nothing is destroyed.
  """
  def delete(id) do
    case show(id) do
      nil ->
        {:error, :no_such_example}

      ex ->
        with :ok <- Store.trash_example(ex) do
          rest = Enum.reject(Store.active()["examples"], &(&1["id"] == id))
          Store.write_set(rest, "delete #{id}")
        end
    end
  end

  @doc "Puts a deleted example back (a new version)."
  def restore(id) do
    case {show(id), Store.trashed(id)} do
      {nil, {:ok, ex, _file}} ->
        Store.write_set(Store.active()["examples"] ++ [ex], "restore #{id}")

      {%{}, _} ->
        {:error, :already_active}

      _ ->
        {:error, :not_in_trash}
    end
  end

  @doc "Makes an earlier version's examples active again, as a new version."
  def rollback(version) when is_integer(version) do
    case Store.set(version) do
      {:ok, set} -> Store.write_set(set["examples"] || [], "rollback to #{version}")
      :error -> {:error, :no_such_version}
    end
  end

  @doc """
  Takes expired examples out of the active set (to trash/, as a new
  version) and moves evidence and candidates past their retention to the
  system Trash. Returns what it did.
  """
  def expire(now \\ DateTime.utc_now()) do
    {old, kept} = Enum.split_with(Store.active()["examples"] || [], &expired?(&1, now))

    version =
      if old != [] do
        Enum.each(old, &Store.trash_example/1)
        {:ok, v} = Store.write_set(kept, "expire #{Enum.map_join(old, ", ", & &1["id"])}")
        v
      end

    %{
      expired: Enum.map(old, & &1["id"]),
      version: version,
      files: Store.expire_files(retention_days(), DateTime.to_unix(now))
    }
  end

  ## Capturing real sessions (only with :browser_examples_persist)

  @doc """
  At the end of a task, keeps its lesson-worthy actions (failed,
  unresolved, or held by a signal) as candidates, if and only if
  persistence is on. Each candidate's correction is a fixed template for
  its signal; page text stays in its evidence, quoted, apart from the
  journals. An unresolved one is kept but can't be promoted until its
  outcome is settled. Returns `:disabled` or `{:ok, ids}`.
  """
  @spec capture(map(), keyword()) :: :disabled | {:ok, [String.t()]}
  def capture(task, opts \\ []) do
    if persist?() do
      decisions = Keyword.get_lazy(opts, :decisions, fn -> decisions(task.id) end)
      calls = Keyword.get_lazy(opts, :calls, fn -> TinyAxe.Tools.Journal.read(task.id) end)

      ids =
        for r <- List.wrap(task[:actions]),
            signals = history_signals(r, calls),
            signals != [] do
          id = "cand-" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
          candidate = candidate(id, task, r, signals, decisions)
          :ok = Store.put_candidate(candidate)
          :ok = Store.put_evidence(id, evidence(r, decisions))
          id
        end

      Store.expire_files(retention_days())
      {:ok, ids}
    else
      :disabled
    end
  end

  # What an action went through, from its record and the task's journal: a
  # lost response later confirmed is still a lesson about lost responses.
  defp history_signals(r, calls) do
    codes =
      for e <- List.wrap(calls),
          {src, key} <- [{e["action"], "id"}, {e["verification"], "action_id"}],
          is_map(src) and src[key] == r.id,
          code <- List.wrap(src["codes"] || src["reason_codes"]),
          do: code

    from_codes = Enum.flat_map((r.codes || []) ++ codes, &List.wrap(@outcome_signals[&1]))
    edit = if r[:family] == "edit" and r[:submission] == true, do: ["autosave"], else: []
    declined = if r[:decision] == :denied, do: ["user_declined"], else: []
    Enum.uniq(from_codes ++ edit ++ declined)
  end

  defp candidate(id, task, r, signals, decisions) do
    answers =
      decisions
      |> Enum.filter(&(&1["assessment_id"] == r.assessment_id))
      |> Enum.flat_map(fn d ->
        for {k, %{"p" => p}} <- d["answers"] || %{},
            is_number(p),
            do: "#{k} #{Float.round(p * 1.0, 2)}"
      end)

    status =
      case {r.status, r.codes} do
        {:failed, ["not_executed"]} -> "not_executed"
        {s, _} -> to_string(s)
      end

    %{
      "schema" => "browser-example-candidate/1",
      "candidate" => true,
      "id" => id,
      "title" => "Captured: #{hd(signals)}",
      "origin" => "session",
      "workflows" => workflows(task[:objective]),
      "signals" => signals,
      "versions" => current_versions(),
      "created_at" => today(),
      "expires_at" => nil,
      "excluded" => if(status in @settled, do: nil, else: "unresolved"),
      "chain" => %{
        "objective" => text(task[:objective]),
        "constraints" => constraints_of(task[:intent]),
        # The harness's description; a label from the page stays quoted.
        "observed" => text(r.description),
        "candidates" => [text(r.description, @candidate_chars)],
        "answers" =>
          if(answers == [], do: "none (decided by a rule)", else: Enum.join(answers, ", ")),
        "disposition" => to_string(r.disposition),
        "executed" => executed(r[:decision]),
        "verified" => %{"status" => status, "codes" => r.codes -- ["outcome_unresolved"]},
        "correction" => %{"text" => @templates[hd(signals)], "source" => "template"}
      }
    }
  end

  defp evidence(r, decisions) do
    %{
      "schema" => "browser-example-evidence/1",
      "action" => Map.take(r, [:description, :status, :codes, :disposition, :class]),
      "decisions" =>
        decisions
        |> Enum.filter(&(&1["assessment_id"] == r.assessment_id or &1["action_id"] == r.id))
        |> Enum.map(&Map.take(&1, ["kind", "evidence", "answers", "disposition", "reason_codes"])),
      "kept_until" => Date.utc_today() |> Date.add(retention_days()) |> Date.to_iso8601()
    }
    |> Redact.deep()
  end

  defp decisions(task_id), do: TinyAxe.Tools.Journal.decisions(task_id)

  defp executed(:approved), do: "the user approved it and it ran"
  defp executed(:ran), do: "it ran"
  defp executed(:denied), do: "the user said no; it didn't run"
  defp executed(:refused), do: "tiny-axe refused it"
  defp executed(other), do: to_string(other || "unknown")

  defp constraints_of(%{max: max}) when is_number(max), do: "spend at most #{max}"
  defp constraints_of(_), do: ""

  defp text(s, n \\ @text_chars)
  defp text(nil, _n), do: ""

  defp text(s, n),
    do: s |> Redact.text() |> String.replace(@refs, "[ref]") |> String.slice(0, n)

  defp today, do: Date.utc_today() |> Date.to_iso8601()

  defp stringify(%{} = m), do: Map.new(m, fn {k, v} -> {to_string(k), stringify(v)} end)
  defp stringify(l) when is_list(l), do: Enum.map(l, &stringify/1)
  defp stringify(v) when is_atom(v) and v not in [nil, true, false], do: to_string(v)
  defp stringify(v), do: v
end
