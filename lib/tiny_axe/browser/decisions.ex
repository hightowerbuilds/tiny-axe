defmodule TinyAxe.Browser.Decisions do
  @moduledoc """
  The gate's shared browser decisions: one code path for every browser
  action, whether the agent asked first (the gate-owned `browser_assess`
  tool) or called the action directly, and for verifying what an action
  came to (the gate-owned `browser_verify` tool, and the completion check
  before an answer reaches the user; see `TinyAxe.Browser.Outcomes`), and
  for choosing among similar candidates (the gate-owned `browser_choose`
  tool, and the gate's own check before an ambiguous click; see
  `TinyAxe.Browser.Choices`), which is advice only.

  An assessment classes the action with `TinyAxe.Tools.BrowserPolicy` and its
  fixed questions, then binds the result to what it judged: the task, its
  tab lease, the server and tool, the normalized arguments, each inspected
  target's signature and the tab's observation id. The decision id names a
  record the gate keeps for that task. It isn't a token: nothing an agent
  sends can make it apply to another task, target or argument.

    * **reuse** — a direct action may use the task's own earlier
      `browser_assess` result while its binding holds: same tool and
      arguments, same target signatures, same observation, not expired
    * **stale** — if the element at an assessed ref changed in place, the
      action is refused (`stale_target`) and the old record dropped, so the
      next call is assessed afresh; after a navigation or expiry the action
      is simply assessed again
    * **monotonic** — once a target needed approval or purchase handling in
      this task, a later, weaker judgment of the same target doesn't lower
      it; a missing answer refuses (BrowserPolicy) and never weakens
    * **dispatch** — the gate sends the binding with the action (`expect/1`)
      and the browser checks the targets again just before acting, after
      any wait for the user's approval
    * **unresolved** — while an action that may have sent something can't
      be confirmed, the same kind of action on its target or form is
      refused (`outcome_unresolved`), whatever the decider says

  Signatures cover what identifies a target (its page, tag, role, label,
  link and form), not the text around it, so a ticking clock nearby doesn't
  make a decision stale.

  The agent's expected effect is kept with the assessment (verification
  shows it to the decider, labelled as the agent's) but isn't shown to the
  decider when assessing: an agent's words can't soften a judgment, and an
  assessed call and a direct one are judged on the same evidence.
  """

  alias TinyAxe.Browser
  alias TinyAxe.Browser.{Choices, Evidence, Outcomes}
  alias TinyAxe.Tools.{BrowserPolicy, Redact}

  @schema "browser-assessment/1"
  @tools ["browser_assess", "browser_verify"]

  # From least to most restricted; composition only ever moves right.
  @order [:read, :local, :outward, :payment_step, :commit, :handoff, :refused]
  # Restrictions that evidence established, which later answers can't lower.
  # An uncertain refusal isn't one: more evidence may clear it.
  @held [:outward, :payment_step, :commit, :handoff]

  @expected_chars 300
  @kept 50

  # Browser actions that can change something: an unresolved one blocks its repeat.
  @acts ~w(browser_click browser_type browser_fill_form browser_select_option browser_press_key
           browser_handle_dialog browser_file_upload)

  @doc "The gate-owned tools this module answers (`browser_choose` only while choosing is on)."
  def owns?("browser_choose"), do: Choices.mode() == :on
  def owns?(name), do: name in @tools

  @doc "Their MCP definitions, offered to tasks that have a browser."
  def definitions do
    [
      %{
        "name" => "browser_assess",
        "description" =>
          "Ask tiny-axe how it would treat a browser action before you take it: whether it " <>
            "runs, needs the user's approval or purchase confirmation, or is refused, with " <>
            "reason codes and the next permitted step. Direct calls get the same checks; " <>
            "asking first approves nothing.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "tool" => %{
              "type" => "string",
              "description" => "the browser tool's name as listed, e.g. browser__browser_click"
            },
            "arguments" => %{
              "type" => "object",
              "description" => "the arguments you'd call it with"
            },
            "observation_id" => %{
              "type" => "string",
              "description" =>
                "the observation on the Page line of the snapshot you took the refs from"
            },
            "expected_effect" => %{
              "type" => "string",
              "description" => "what you expect the action to do, in a sentence"
            }
          },
          "required" => ["tool", "arguments"]
        },
        "annotations" => %{"readOnlyHint" => true}
      },
      %{
        "name" => "browser_verify",
        "description" =>
          "Ask tiny-axe whether a browser action you took worked. It looks at the page afresh and " <>
            "answers succeeded, failed or unresolved, with evidence and reason codes. Use the " <>
            "action id from the action's result (or the decision id from browser_assess); without " <>
            "one, your latest action that sent something.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "action_id" => %{
              "type" => "string",
              "description" => "the action id (act-...) from the action's result"
            },
            "claimed_outcome" => %{
              "type" => "string",
              "description" => "what you believe happened, in a sentence"
            }
          },
          "required" => []
        },
        "annotations" => %{"readOnlyHint" => true}
      }
    ] ++ if(Choices.mode() == :on, do: [Choices.definition()], else: [])
  end

  @doc "The same short instructions for every driver whose task has a browser."
  def instructions do
    "Browser actions are checked by tiny-axe before they run, whether or not you ask first. " <>
      "To know beforehand whether one would run, wait for the user's approval, or be refused, " <>
      "call browser_assess with the tool, its arguments, the observation id from your latest " <>
      "snapshot, and what you expect it to do. Its reason codes say how to recover: " <>
      "stale_target means take a fresh snapshot and use its refs; insufficient_evidence means " <>
      "look more closely or use browser_handoff. After an action that sends, saves or buys " <>
      "something, check it worked with browser_verify (the action id from its result, and what " <>
      "the page should show); tell the user only what was confirmed. If an outcome is " <>
      "unresolved, never repeat the action: verify it or tell the user." <>
      if(Choices.mode() == :on, do: " " <> choose_instructions(), else: "")
  end

  # The same short workflow and examples for every driver, while choosing is on.
  defp choose_instructions do
    "When several elements could be the one you need (several \"Add to cart\", \"Book\", " <>
      "\"Add\" or \"Continue\" buttons, near-identical listings, sponsored results, options " <>
      "chosen by default), call browser_choose with their refs, the observation id and your " <>
      "current step. It answers chosen (with a ref), none, need_more_evidence or handoff; it's " <>
      "advice and approves nothing. " <>
      if(Choices.hints?(),
        do:
          "tiny-axe may also hold a click with a choose_hint: nothing was done; act on the " <>
            "suggested ref, or repeat the call only if you're sure. ",
        else: ""
      ) <>
      "Examples: stale_target → take a fresh snapshot and use its refs (a repair, not a retry). " <>
      "The user said no → don't try it another way; tell the user. browser_choose says none → " <>
      "look elsewhere (next page, a search) or tell the user it isn't there. need_more_evidence → " <>
      "open the item's page or use browser_extract, then choose again. chosen e45 → act on e45."
  end

  @doc """
  Assesses one browser action. `request`: `:task`, `:server`, `:name` (the
  gate's tool name), `:tool` (the browser's), `:args`, `:mode` (`:advice` for
  `browser_assess`, `:execute` for a direct call), and from `browser_assess`
  `:observation` and `:expected`. `opts`: `:inspect` (ref or nil → what
  `browser_inspect` reports, or nil), `:context` (the task, for
  `TinyAxe.Browser.Evidence`), `:decide`, `:prior` and `:floors` (the task's
  record, see `remember/2`), `:unresolved` (the keys of the task's
  unresolved actions, `TinyAxe.Browser.Outcomes.unresolved_keys/1`),
  `:purchases` (whether they're enabled), `:now` and `:ttl` (milliseconds).
  A direct call that can change something gets an `action_id`, under which
  the browser records what it did.
  """
  @spec assess(map(), keyword()) :: map()
  def assess(request, opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.monotonic_time(:millisecond) end)
    ttl = Keyword.get_lazy(opts, :ttl, &ttl/0)
    args = clean(request.args || %{})
    hash = Evidence.hash(normalize(args))
    {look, seen} = memo(opts[:inspect])

    prior =
      if request.mode == :execute, do: Enum.find(opts[:prior] || [], &bound?(&1, request, hash))

    judged =
      case prior && check(prior, look, now) do
        :valid -> reuse(prior)
        {:changed, ref, label} -> stale(prior, ref, label)
        _ -> observed_stale(request, args, look) || fresh(request, args, look, opts)
      end

    metas = Process.delete(seen)
    targets = Map.new(metas, fn {ref, meta} -> {ref_key(ref), meta && meta["signature"]} end)
    targets = if judged[:binding_targets], do: judged.binding_targets, else: targets

    binding = %{
      task: request.task,
      lease: request.task,
      server: request.server,
      tool: request.name,
      args_hash: hash,
      family: family(request.tool, args),
      targets: targets,
      observation: judged[:observation] || observation(metas)
    }

    {class, reason, codes} =
      hold(held(opts[:floors] || %{}, binding), judged.class, judged.reason, judged.codes)

    effect = Outcomes.effect(binding, Enum.to_list(metas), prior && prior[:effect])

    # Something like it may already have been sent: never again until it's
    # confirmed one way or the other.
    {class, reason, codes} =
      if class != :refused and request.tool in @acts and
           Outcomes.unresolved?(effect.keys, opts[:unresolved] || MapSet.new()),
         do:
           {:refused,
            "an earlier action like this may already have gone through, and tiny-axe couldn't " <>
              "confirm it either way, so it won't be repeated", codes ++ ["outcome_unresolved"]},
         else: {class, reason, codes}

    codes =
      if Enum.any?(metas, fn {_ref, meta} -> meta == nil end),
        do: codes ++ ["target_not_found"],
        else: codes

    {disposition, codes} =
      disposition(class, codes, opts[:purchases] == true, get_in(opts, [:context, :intent]))

    id = "asm-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    action_id =
      if request.mode == :execute and Outcomes.effectful?(request.tool, args, binding),
        do: "act-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    trace = %{assessment_id: id, binding: binding, action_id: action_id}

    %{
      schema: @schema,
      id: id,
      mode: request.mode,
      binding: binding,
      class: class,
      reason: reason,
      reason_codes: Enum.uniq(codes),
      disposition: disposition,
      next_step: next_step(disposition, codes, request.name),
      expected_effect: expected(request[:expected]),
      targets: judged[:targets] || summary(metas),
      decisions: Enum.map(judged[:records] || [], &Map.merge(&1, trace)),
      reused_from: judged[:reused_from],
      forget: judged[:forget],
      effect: effect,
      action_id: action_id,
      at: now,
      expires: now + ttl
    }
  end

  @doc """
  The task's record after an assessment: `browser_assess` results kept for
  reuse (the newest #{@kept}), and the strictest established class per
  target. A stale record is dropped.
  """
  @spec remember(map(), map()) :: map()
  def remember(record, assessment) do
    kept =
      (record[:assessments] || [])
      |> Enum.reject(&(&1.id == assessment.forget))

    kept =
      if assessment.mode == :advice and assessment.class != :refused,
        do: Enum.take([Map.delete(assessment, :decisions) | kept], @kept),
        else: kept

    entry = %{class: assessment.class, reason: assessment.reason, from: assessment.id}

    floors =
      if assessment.class in @held,
        do:
          Enum.reduce(floor_keys(assessment.binding), record[:floors] || %{}, fn key, floors ->
            Map.update(
              floors,
              key,
              entry,
              &if(rank(&1.class) >= rank(entry.class), do: &1, else: entry)
            )
          end),
        else: record[:floors] || %{}

    %{assessments: kept, floors: floors}
  end

  @doc """
  What the browser checks again just before acting: the tab's observation id
  and each target's signature. Nil when nothing was inspected.
  """
  @spec expect(map() | nil) :: map() | nil
  def expect(%{binding: %{targets: targets, observation: observation}}) do
    seen = for {ref, sig} <- targets, is_binary(sig), into: %{}, do: {ref, sig}
    if seen == %{}, do: nil, else: %{"observation" => observation, "targets" => seen}
  end

  def expect(_), do: nil

  @doc "Whether the browser refused an action because its target went stale."
  @spec stale_result?(term()) :: boolean()
  def stale_result?(%{"isError" => true, "content" => [%{"text" => "stale_target: " <> _} | _]}),
    do: true

  def stale_result?(_), do: false

  @doc """
  What the agent sees: the disposition, reason codes, evidence references
  and the next permitted step. No private reasoning, no decision inputs.
  """
  @spec public(map()) :: map()
  def public(a) do
    %{
      "decision_id" => a.id,
      "disposition" => a.disposition,
      "reason" => a.reason,
      "reason_codes" => a.reason_codes,
      "next_step" => a.next_step,
      "evidence" => %{
        "observation_id" => a.binding.observation,
        "targets" => a.targets,
        "decision_records" => Enum.map(a.decisions, & &1.id)
      },
      "valid_for_seconds" => if(a.class == :refused, do: 0, else: div(a.expires - a.at, 1000))
    }
  end

  @doc "A `browser_assess` result, as an MCP tool result."
  def result(a),
    do: %{"content" => [%{"type" => "text", "text" => JSON.encode!(public(a))}]}

  @doc "What the task's call journal keeps of an assessment."
  def journal(nil), do: nil

  def journal(a) do
    a
    |> Map.take([
      :schema,
      :id,
      :mode,
      :disposition,
      :class,
      :reason_codes,
      :reused_from,
      :binding,
      :expected_effect
    ])
  end

  ## Outcomes (TinyAxe.Browser.Outcomes)

  @doc "An action's record once the gate has done with it; see `TinyAxe.Browser.Outcomes.record/2`."
  defdelegate record(assessment, outcome), to: Outcomes

  @doc "Verifies an action from fresh observations; see `TinyAxe.Browser.Outcomes.verify/2`."
  defdelegate verify(record, opts), to: Outcomes

  @doc "The completion check on an answer; see `TinyAxe.Browser.Outcomes.completion/3`."
  defdelegate completion(records, reply, opts), to: Outcomes

  ## Choosing (TinyAxe.Browser.Choices)

  @doc "Chooses among candidate elements; see `TinyAxe.Browser.Choices.choose/2`."
  defdelegate choose(request, opts), to: Choices

  defdelegate unresolved_keys(records), to: Outcomes
  defdelegate unverified(records), to: Outcomes
  defdelegate note(record), to: Outcomes

  @doc "A `browser_verify` result, as an MCP tool result."
  def verification_result(v),
    do: %{"content" => [%{"type" => "text", "text" => JSON.encode!(Outcomes.public(v))}]}

  @doc "The stricter of two classes."
  def stricter(a, b), do: if(rank(a) >= rank(b), do: a, else: b)

  @doc """
  A tool's name as the gate lists it, from the name an agent saw: Claude
  Code shows the gate's tools as `mcp__tinyaxe__<name>`, Codex as
  `mcp__tinyaxe__<name>` or `tinyaxe.<name>`.
  """
  @spec listed_name(term()) :: String.t() | nil
  def listed_name(name) when is_binary(name) do
    Enum.find_value(["mcp__tinyaxe__", "tinyaxe__", "tinyaxe.", "tinyaxe/"], name, fn prefix ->
      if String.starts_with?(name, prefix), do: String.replace_prefix(name, prefix, "")
    end)
  end

  def listed_name(_name), do: nil

  @doc false
  # Arguments without the gate's own keys, whoever sent them.
  def clean(args) when is_map(args), do: Map.reject(args, fn {k, _} -> Browser.reserved?(k) end)
  def clean(_args), do: %{}

  # What identifies the action: its arguments, without the agent's
  # description of the element.
  defp normalize(args), do: Map.delete(args, "element")

  ## Judging

  defp fresh(request, args, look, opts) do
    key = {__MODULE__, :records, make_ref()}
    Process.put(key, [])

    {class, reason} =
      BrowserPolicy.classify(request.tool, args, look,
        context: opts[:context],
        decide: Keyword.get(opts, :decide, &TinyAxe.Decider.decide_traced/2),
        on_decision: &Process.put(key, [&1 | Process.get(key)])
      )

    # Bind a target the policy had no need to look at (uploads, hovers).
    if is_binary(args["ref"]), do: look.(args["ref"])

    records = key |> Process.delete() |> Enum.reverse()
    codes = Enum.flat_map(records, & &1.reason_codes)
    codes = if records == [], do: ["policy_rule"], else: codes
    %{class: class, reason: reason, codes: codes, records: records}
  end

  defp reuse(prior) do
    %{
      class: prior.class,
      reason: prior.reason,
      codes: prior.reason_codes -- ["prior_restriction"],
      targets: prior.targets,
      binding_targets: prior.binding.targets,
      observation: prior.binding.observation,
      reused_from: prior.id
    }
  end

  defp stale(prior, ref, now) do
    was = get_in(prior.targets, [ref, "text"])

    %{
      class: :refused,
      reason:
        ~s(the element at #{ref} changed since browser_assess checked it ) <>
          ~s[(it was "#{was}", now "#{now}"), so nothing was done],
      codes: ["stale_target"],
      forget: prior.id
    }
  end

  # The agent's refs came from an older snapshot than the page now shows.
  defp observed_stale(%{observation: seen}, args, look) when is_binary(seen) and seen != "" do
    case refs(args) do
      [ref | _] ->
        case look.(ref) do
          %{"observation" => now} when now != seen ->
            %{
              class: :refused,
              reason:
                "your snapshot is out of date: the page has changed since #{seen}, so its refs may point elsewhere",
              codes: ["stale_target"],
              observation: now
            }

          _ ->
            nil
        end

      [] ->
        nil
    end
  end

  defp observed_stale(_request, _args, _look), do: nil

  defp refs(args) do
    fields = for %{"ref" => ref} <- List.wrap(args["fields"]), is_binary(ref), do: ref
    if(is_binary(args["ref"]), do: [args["ref"]], else: []) ++ fields
  end

  # Only this task's own assessment of this exact call, on the same server.
  defp bound?(prior, request, hash) do
    b = prior.binding

    b.task == request.task and b.lease == request.task and b.server == request.server and
      b.tool == request.name and b.args_hash == hash
  end

  defp check(prior, look, now) do
    metas = Map.new(Map.keys(prior.binding.targets), &{&1, look.(ref_arg(&1))})
    signatures = Map.new(metas, fn {k, meta} -> {k, meta && meta["signature"]} end)

    changed = Enum.find(Map.keys(signatures), &(signatures[&1] != prior.binding.targets[&1]))

    cond do
      observation(metas) != prior.binding.observation -> :moved
      changed -> {:changed, changed, label(metas[changed])}
      now >= prior.expires -> :expired
      true -> :valid
    end
  end

  # An established restriction on this target holds against a weaker class;
  # a refusal is already the strictest.
  defp hold(floor, class, reason, codes) do
    if floor && class != :refused && rank(floor.class) > rank(class),
      do: {floor.class, floor.reason, codes ++ ["prior_restriction"]},
      else: {class, reason, codes}
  end

  defp disposition(class, codes, _purchases, _intent) when class in [:read, :local],
    do: {"allowed", codes}

  defp disposition(:outward, codes, _purchases, _intent), do: {"needs_approval", codes}
  defp disposition(:handoff, codes, _purchases, _intent), do: {"needs_handoff", codes}
  defp disposition(:refused, codes, _purchases, _intent), do: {"refused", codes}

  # What the purchase gate will do, said in advance; it still decides.
  defp disposition(class, codes, purchases, intent) when class in [:commit, :payment_step] do
    cond do
      not purchases -> {"refused", codes ++ ["purchases_disabled"]}
      intent == nil or intent[:max] == nil -> {"refused", codes ++ ["constraint_mismatch"]}
      true -> {"needs_purchase_confirmation", codes ++ ["needs_purchase_confirmation"]}
    end
  end

  defp next_step("allowed", _codes, name),
    do: "call #{name} with these arguments; it runs at once"

  defp next_step("needs_approval", _codes, name),
    do: "call #{name} with these arguments; the user is asked to approve it"

  defp next_step("needs_purchase_confirmation", _codes, name),
    do: "call #{name}; tiny-axe shows the order to the user, who confirms it by typing the total"

  defp next_step("needs_handoff", _codes, _name), do: "the user does this in the browser window"

  defp next_step("refused", codes, _name) do
    cond do
      "stale_target" in codes or "target_not_found" in codes ->
        "take a fresh browser_snapshot and use its refs"

      "outcome_unresolved" in codes ->
        "don't repeat it: call browser_verify to check whether the earlier one went through, or tell the user"

      "constraint_mismatch" in codes ->
        "don't; tell the user (they didn't ask to buy this, or gave no maximum to spend)"

      "insufficient_evidence" in codes ->
        "look more closely (browser_snapshot or browser_extract) and assess again, or use browser_handoff"

      "decision_unavailable" in codes ->
        "use browser_handoff for the user to do it, or tell the user"

      true ->
        "don't try it another way; tell the user what you couldn't do"
    end
  end

  ## Bindings

  # Restrictions are held per element (its signature, never its ref, which
  # a new snapshot may change) and per kind of action on it, whatever the
  # other arguments: a double-click or Enter on a button shares its click's.
  defp floor_keys(binding) do
    for {_ref, sig} <- binding.targets, is_binary(sig), do: {binding.server, binding.family, sig}
  end

  # The strictest restriction held for any of this action's targets.
  defp held(floors, binding) do
    binding
    |> floor_keys()
    |> Enum.map(&floors[&1])
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&rank(&1.class), fn -> nil end)
  end

  # Activating an element (clicking, pressing a key on it, answering its
  # dialog, typing and submitting), editing it, or another tool's action.
  defp family(tool, _args)
       when tool in ["browser_click", "browser_press_key", "browser_handle_dialog"],
       do: "activate"

  defp family("browser_type", %{"submit" => true}), do: "activate"

  defp family(tool, _args)
       when tool in ["browser_type", "browser_fill_form", "browser_select_option"],
       do: "edit"

  defp family(tool, _args), do: tool

  # Inspecting with no ref reports what's active: the focused element, or an
  # open dialog.
  defp ref_key(nil), do: "@active"
  defp ref_key(ref), do: ref
  defp ref_arg("@active"), do: nil
  defp ref_arg(ref), do: ref

  defp observation(metas),
    do: Enum.find_value(metas, fn {_ref, meta} -> is_map(meta) && meta["observation"] end)

  defp label(meta), do: meta["text"] || get_in(meta, ["dialog", "message"])

  # What the agent is told about each target: enough to see what was judged.
  defp summary(metas) do
    for {ref, meta} <- metas, is_map(meta), into: %{} do
      {ref_key(ref),
       %{
         "text" => label(meta),
         "tag" => meta["tag"],
         "page" => Evidence.clean_url(meta["page"])
       }
       |> Map.reject(fn {_k, v} -> v in [nil, ""] end)
       |> Redact.deep()}
    end
  end

  defp expected(text) when is_binary(text) and text != "",
    do: text |> String.slice(0, @expected_chars) |> Redact.text()

  defp expected(_), do: nil

  # Each target is inspected once per assessment, and every look is kept.
  defp memo(inspect) do
    inspect = inspect || fn _ref -> nil end
    key = {__MODULE__, :seen, make_ref()}
    Process.put(key, %{})

    look = fn ref ->
      seen = Process.get(key, %{})

      case Map.fetch(seen, ref) do
        {:ok, meta} ->
          meta

        :error ->
          meta = inspect.(ref)
          Process.put(key, Map.put(Process.get(key, %{}), ref, meta))
          meta
      end
    end

    {look, key}
  end

  defp rank(class), do: Enum.find_index(@order, &(&1 == class)) || length(@order)

  defp ttl,
    do: Application.get_env(:tiny_axe, :tools, [])[:assessment_ttl] || :timer.minutes(2)
end
