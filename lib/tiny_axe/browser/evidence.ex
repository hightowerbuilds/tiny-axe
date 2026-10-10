defmodule TinyAxe.Browser.Evidence do
  @moduledoc """
  What a browser decision is shown: a bounded, redacted observation, built by
  tiny-axe, with each part labelled by where it came from.

    * `task` (source `user`) — the user's request and any purchase limit,
      from the harness's own conversation state; an agent can't replace it
    * `observation` and `target` (source `page`) — the inspected element and
      its surroundings, as `browser_inspect` saw them
    * `proposed_action` (source `agent`) — the tool and its arguments: what
      the agent wants to do, not an observed fact. Typed text is reduced to
      its length; field values never leave tiny-axe
    * `recent_actions` (source `harness`) — the task's last few calls and
      what the gate did with them

  Every text has a budget, and whatever was cut is listed in `truncated`, so
  a decision can tell missing evidence from absent evidence. URLs lose their
  credentials, query strings and fragments; card numbers are removed from
  everything (`TinyAxe.Tools.Redact`).
  """

  alias TinyAxe.Tools.Redact

  @schema "browser-evidence/1"

  @objective_chars 1_000
  @label_chars 200
  @context_chars 2_000
  @arg_chars 200
  @form_fields 30
  @list_items 10
  @recent 5

  @target_keys ~w(page text tag role type href form context)

  @doc "The evidence schema's version, recorded with each decision."
  def schema, do: @schema

  @doc """
  The evidence for one decision. `context`: `:objective`, `:intent` (see
  `TinyAxe.Purchases.intent/2`) and `:recent` (the task's latest calls, newest
  last), each optional. `action`: `:tool`, `:args` and `:description` ("click
  this control"). `target`: what `browser_inspect` reported.
  """
  @spec build(map() | nil, map(), map()) :: map()
  def build(context, action, target) do
    context = context || %{}
    {objective, cut_objective} = cap(context[:objective], @objective_chars)
    {target, cut_target} = target(target)
    {args, cut_args} = args(action[:tool], action[:args] || %{})
    recent = context[:recent] |> List.wrap() |> Enum.take(-@recent)

    truncated =
      if(cut_objective, do: ["task.objective"], else: []) ++
        Enum.map(cut_target, &"target.#{&1}") ++ Enum.map(cut_args, &"proposed_action.args.#{&1}")

    %{
      schema: @schema,
      task: %{source: "user", objective: objective, purchase: purchase(context[:intent])},
      observation: %{
        source: "page",
        id: observation_id(target),
        captured_at:
          DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
        page: target["page"]
      },
      target: Map.put(target, "source", "page"),
      proposed_action: %{
        source: "agent",
        tool: action[:tool],
        action: action[:description],
        args: args
      },
      recent_actions: %{source: "harness", items: Enum.map(recent, &recent_item/1)},
      truncated: truncated
    }
    |> Redact.deep()
  end

  @doc """
  The evidence as a decision maker sees it: without the schema name, the
  observation's id and capture time, or a repeated source label, which say
  nothing about what an action does. The record keeps the full evidence.
  """
  @spec for_decision(map()) :: map()
  def for_decision(evidence) do
    evidence
    |> Map.drop([:schema, :observation])
    |> Map.update(:target, %{}, &Map.delete(&1, "source"))
  end

  @doc """
  A stable id for what was observed: the same target on the same page gets
  the same id, so later phases can tell a stale assessment from a fresh one.
  """
  @spec observation_id(map()) :: String.t()
  def observation_id(target), do: "obs-" <> String.slice(hash(target), 0, 16)

  @doc "A SHA-256 of a term's canonical JSON (map keys sorted), in hex."
  @spec hash(term()) :: String.t()
  def hash(term) do
    :crypto.hash(:sha256, term |> canonical() |> JSON.encode!())
    |> Base.encode16(case: :lower)
  end

  @doc "A URL without credentials, query string or fragment."
  @spec clean_url(term()) :: String.t() | nil
  def clean_url(url) when is_binary(url) do
    uri = URI.parse(url)
    URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})
  end

  def clean_url(_), do: nil

  ## The target

  defp target(nil), do: {%{}, []}

  defp target(meta) do
    base = Map.take(meta, @target_keys)
    {text, cut_text} = cap(base["text"], @label_chars)
    {context, cut_context} = cap(base["context"], @context_chars)
    {form, cut_form} = form(base["form"])

    target =
      base
      |> Map.merge(%{"text" => text, "context" => context, "form" => form})
      |> Map.update("page", nil, &clean_url/1)
      |> Map.update("href", nil, &clean_url/1)
      |> Map.reject(fn {_k, v} -> v in [nil, ""] end)

    # The page itself may already have cut the context short.
    cut =
      if(cut_text, do: ["text"], else: []) ++
        if(cut_context or meta["contextTruncated"] == true, do: ["context"], else: []) ++
        cut_form

    {target, cut}
  end

  defp form(%{} = form) do
    fields = List.wrap(form["fields"])

    kept =
      fields
      |> Enum.take(@form_fields)
      |> Enum.map(fn f ->
        f |> Map.take(~w(tag type name autocomplete)) |> Map.new(fn {k, v} -> {k, short(v)} end)
      end)

    {label, cut_label} = cap(form["label"], @label_chars)
    {submit, cut_submit} = cap(form["submitText"], @label_chars)

    form =
      form
      |> Map.take(~w(method hasPassword hasPayment))
      |> Map.merge(%{
        "action" => clean_url(form["action"]),
        "label" => label,
        "submitText" => submit,
        "fields" => kept
      })

    cut =
      if(length(fields) > @form_fields, do: ["form.fields"], else: []) ++
        if(cut_label, do: ["form.label"], else: []) ++
        if cut_submit, do: ["form.submitText"], else: []

    {form, cut}
  end

  defp form(_), do: {nil, []}

  ## The proposed action

  # Typed text stays in tiny-axe: its length says enough about what would happen.
  defp args("browser_type", args) do
    {%{
       "ref" => short(args["ref"]),
       "typed_chars" => String.length(to_string(args["text"] || "")),
       "submit" => args["submit"] == true
     }, []}
  end

  defp args("browser_fill_form", args) do
    fields = List.wrap(args["fields"])

    kept =
      for f <- Enum.take(fields, @list_items), is_map(f) do
        %{"ref" => short(f["ref"]), "typed_chars" => String.length(to_string(f["value"] || ""))}
      end

    {%{"fields" => kept}, if(length(fields) > @list_items, do: ["fields"], else: [])}
  end

  defp args(_tool, args) when is_map(args) do
    Enum.reduce(args, {%{}, []}, fn
      {k, v}, {acc, cut} when is_binary(v) ->
        {v, cut?} = cap(v, @arg_chars)
        {Map.put(acc, k, v), if(cut?, do: [k | cut], else: cut)}

      {k, v}, {acc, cut} when is_list(v) ->
        items = v |> Enum.take(@list_items) |> Enum.map(&short/1)
        {Map.put(acc, k, items), if(length(v) > @list_items, do: [k | cut], else: cut)}

      {k, v}, {acc, cut} when is_boolean(v) or is_number(v) or is_nil(v) ->
        {Map.put(acc, k, v), cut}

      # Nested structures aren't evidence anything needs; leave a marker.
      {k, _v}, {acc, cut} ->
        {Map.put(acc, k, "(omitted)"), cut}
    end)
  end

  defp args(_tool, _args), do: {%{}, []}

  ## Task context

  defp purchase(%{max: max, currency: currency}), do: %{max_price: max, currency: currency}
  defp purchase(_), do: nil

  defp recent_item(item) do
    %{
      "tool" => item[:tool],
      "class" => item[:class] && to_string(item[:class]),
      "decision" => item[:decision] && to_string(item[:decision]),
      "error" => item[:error] == true
    }
  end

  ## Budgets

  defp cap(nil, _limit), do: {nil, false}

  defp cap(text, limit) when is_binary(text) do
    if String.length(text) > limit, do: {String.slice(text, 0, limit), true}, else: {text, false}
  end

  defp cap(other, limit), do: cap(to_string(other), limit)

  defp short(v) when is_binary(v), do: v |> cap(@arg_chars) |> elem(0)
  defp short(v) when is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp short(_v), do: "(omitted)"

  defp canonical(%{} = map),
    do: map |> Enum.map(fn {k, v} -> [to_string(k), canonical(v)] end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(atom) when is_atom(atom) and atom not in [nil, true, false], do: to_string(atom)
  defp canonical(other), do: other
end
