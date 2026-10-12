defmodule TinyAxe.Appearance do
  @moduledoc """
  Changes how the desktop and terminal look when asked ("make the terminal
  font bigger", "switch to Tokyo Night", "no gaps between windows", "put
  the bar at the bottom"), along a fixed path a small model can walk:

  1. **Read** — every setting's current value is read from the computer
     (`Appearance.Settings`), along with the real choices where there's a
     list (themes, fonts).
  2. **Fill** (the local model first) — the model answers in a fixed JSON
     shape: `changes` (a setting id from the list, which the JSON schema
     enforces, and a value) and `reply`. It never writes a command.
  3. **Check** (code) — each value is checked against its kind
     (`Appearance.Value`): one of the real choices, a number in range, an
     image that exists; `+2` is from the current value. Problems go back to
     the model with the real choices, up to #{3} rounds.
  4. **Review** (the Decider) — per change, is it needed for what was
     asked, and do they together do all of it? The weakest is the score; a
     doubtful plan goes back once with reasons.
  5. **Escalate** — when the local model can't produce changes that pass
     the checks and the review, the escalation ladder (`TinyAxe.Escalation`,
     Claude Haiku 5.5) fills the same shape from the start. Escalation
     changes who fills it in, never what may be set.
  6. **Apply** — appearance settings are low-risk and undoable, so they run
     without asking (the user's choice, 2026-10-12), one at a time, and each
     is read back. `/look undo` puts the newest request's changes back
     (`Appearance.Undo`). Requests from the site's Chat tab
     (`origin: :site`) can't change anything: they get the plan and are
     told to ask on this computer.

  Events: `{:stage, text}`, `{:appearance_problems, [text]}`, `{:review, p}`,
  the escalation events, then `{:attempt, 1}` and `{:done, text}`.
  """

  alias TinyAxe.{Escalation, Model, Ollama}
  alias TinyAxe.Appearance.{Settings, Undo, Value}

  @max_rounds 3

  @doc """
  Handles an appearance request. `opts[:remote]`: whether the escalation
  ladder may leave this machine (`:ask`, `:allowed`, `:denied`);
  `opts[:origin]`: `:site` for a request from the site's Chat tab.
  """
  @spec run([Ollama.message()], String.t(), (term() -> any()), keyword()) :: :ok
  def run(history, prompt, notify, opts \\ []) do
    notify.({:stage, "reading the desktop's settings…"})
    settings = snapshot()

    messages = [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: first_message(history, prompt, settings)}
    ]

    context = TinyAxe.Pipeline.context(history, prompt)
    notify.({:stage, "choosing settings…"})

    remote = Keyword.get(opts, :remote, :denied)

    result =
      case plan(messages, context, settings, notify, 1, false) do
        {:ok, _changes, _reply} = sure ->
          sure

        {fell, _, _} = local when fell in [:gave_up, :doubtful] ->
          why =
            if fell == :gave_up,
              do: "its appearance changes didn't pass the checks after #{@max_rounds} tries",
              else: "the reviewer doubted its appearance changes"

          # A doubtful plan is kept: if no bigger model does better, the user
          # is asked about it instead of it running without asking.
          escalated = fn choice, best ->
            case plan(messages, Map.put(context, :use, choice), settings, notify, 1, false) do
              {:ok, _, _} = sure -> {:ok, sure}
              {:doubtful, _, _} = doubtful -> {:fell_short, doubtful}
              {:gave_up, _, _} -> {:fell_short, best}
              {:reply, _} = reply -> {:ok, reply}
              {:error, reason} -> {:error, reason, best}
            end
          end

          case Escalation.climb(why, remote, notify, local, escalated) do
            {:ok, result, choice} ->
              notify.({:answered_by, %{model: Model.label(choice)}})
              result

            {:none, best} ->
              best
          end

        other ->
          other
      end

    site? = Keyword.get(opts, :origin) == :site

    case result do
      {_, changes, reply} when site? and is_list(changes) ->
        done(notify, from_site(changes, reply))

      {:ok, changes, reply} ->
        done(notify, apply_changes(prompt, changes, reply, notify))

      {:doubtful, changes, reply} ->
        ask(prompt, changes, reply, notify)

      {:gave_up, reply, _} ->
        done(notify, reply)

      {:reply, reply} ->
        done(notify, reply)

      {:error, reason} ->
        notify.({:error, reason})
    end

    :ok
  end

  # The plan waits for the user's y/n in the TUI (the commands popup); only
  # setting ids and values are kept, and they're checked again when it runs
  # (`execute/2`).
  defp ask(request, changes, reply, notify) do
    notify.(
      {:appearance_plan,
       %{
         kind: :appearance,
         request: request,
         changes: Enum.map(changes, &%{"setting" => &1.setting.id, "value" => &1.value}),
         commands: Enum.map(changes, &%{command: describe(&1), review: nil}),
         review: nil,
         dir: TinyAxe.Location.current()
       }}
    )

    lines = Enum.map_join(changes, "\n", &"- #{describe(&1)}")
    reply = if String.trim(reply) == "", do: "", else: String.trim(reply) <> "\n\n"

    done(
      notify,
      reply <>
        "**Appearance changes** (waiting for your approval: the reviewer wasn't sure " <>
        "they're what you asked for):\n\n" <> lines
    )
  end

  @doc """
  Makes an approved appearance plan's changes (from `{:appearance_plan, plan}`),
  checked again against the settings as they are now. Events:
  `{:stage, text}`, then `{:appearance_done, text}`.
  """
  @spec execute(map(), (term() -> any())) :: :ok
  def execute(plan, notify) do
    notify.({:stage, "changing the look…"})

    text =
      case check(plan.changes, snapshot()) do
        {:ok, [], _} -> "*Nothing to change: the settings are already as asked.*"
        {:ok, changes, _} -> apply_changes(plan.request, changes, "", notify)
        {:error, problems} -> "✗ didn't change anything; now:\n" <> Enum.join(problems, "\n")
      end

    notify.({:appearance_done, text})
    :ok
  end

  defp done(notify, text) do
    notify.({:attempt, 1})
    notify.({:done, text})
  end

  ## Reading

  @doc """
  Every setting with its current value and, for lists read from the
  computer, its choices (read once, so the prompt and the checks agree):
  `[%{setting | current: value, kind: kind}]`.
  """
  @spec snapshot() :: [map()]
  def snapshot do
    Settings.all()
    |> Task.async_stream(
      fn s ->
        kind =
          case s.kind do
            {:choice, fun} ->
              choices = fun.()
              {:choice, fn -> choices end}

            other ->
              other
          end

        Map.merge(s, %{now: s.current.(), kind: kind})
      end,
      timeout: 15_000,
      on_timeout: :kill_task,
      max_concurrency: 8
    )
    |> Enum.zip(Settings.all())
    |> Enum.map(fn
      {{:ok, s}, _} -> s
      {{:exit, _}, s} -> Map.put(s, :now, nil)
    end)
  end

  ## Planning

  defp schema do
    %{
      type: "object",
      properties: %{
        changes: %{
          type: "array",
          items: %{
            type: "object",
            properties: %{
              setting: %{type: "string", enum: Settings.ids()},
              # A number or true/false is accepted too: held to a string,
              # Gemma has written "," where it meant 0.
              value: %{type: ["string", "number", "boolean"]}
            },
            required: ["setting", "value"]
          }
        },
        reply: %{type: "string"}
      },
      required: ["changes", "reply"]
    }
  end

  defp plan(messages, _context, _settings, _notify, round, _reviewed?)
       when round > @max_rounds do
    problems = List.last(messages).content |> String.split("\n\n") |> hd()

    {:gave_up,
     "I couldn't work out settings that do that. The last attempt's problems:\n\n" <> problems,
     nil}
  end

  defp plan(messages, context, settings, notify, round, reviewed?) do
    case Model.chat(messages,
           format: schema(),
           # Warmer on each retry, so a correction isn't the same answer again.
           options: [temperature: 0.2 * round],
           use: context[:use]
         ) do
      {:ok, %{"message" => %{"content" => json}}} ->
        messages = messages ++ [%{role: "assistant", content: json}]

        case JSON.decode(json) do
          {:ok, answer} when is_map(answer) ->
            planned(answer, messages, context, settings, notify, round, reviewed?)

          _ ->
            # Small models sometimes stop mid-JSON: that's a failed round, not
            # the end of the request.
            fix = "That wasn't the JSON asked for. Reply with only the JSON object."
            plan(messages ++ [user(fix)], context, settings, notify, round + 1, reviewed?)
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :bad_appearance_json}
    end
  end

  defp planned(answer, messages, context, settings, notify, round, reviewed?) do
    reply = text(answer["reply"])

    case check(answer["changes"], settings) do
      {:ok, [], _already} ->
        {:reply, reply}

      {:ok, changes, already} ->
        case review(changes, already, context, notify) do
          {:doubtful, feedback} when not reviewed? ->
            plan(messages ++ [user(feedback)], context, settings, notify, round + 1, true)

          {:doubtful, _feedback} ->
            # Reviewed twice and still doubtful: not good enough to run
            # without asking. A bigger model may try; failing that, the
            # user is asked.
            {:doubtful, changes, reply}

          :ok ->
            {:ok, changes, reply}
        end

      {:error, problems} ->
        notify.({:appearance_problems, problems})

        fix =
          "tiny-axe can't make these changes as written:\n" <>
            Enum.map_join(problems, "\n", &"- #{&1}") <> "\n\nReply with corrected JSON."

        plan(messages ++ [user(fix)], context, settings, notify, round + 1, reviewed?)
    end
  end

  @doc """
  Checks the model's changes against the settings: `{:ok, changes, already}`
  with values in their checked form (a later change to the same setting
  wins), where `already` are those the setting already has, taken out of
  `changes`; or `{:error, problems}`.
  """
  @spec check(term(), [map()]) :: {:ok, [map()], [map()]} | {:error, [String.t()]}
  def check(changes, settings) do
    by_id = Map.new(settings, &{&1.id, &1})

    {ok, problems} =
      changes
      |> List.wrap()
      |> Enum.map(fn
        %{"setting" => id, "value" => value} -> {text(id), text(value)}
        other -> {:bad, other}
      end)
      |> Enum.reduce({[], []}, fn
        {:bad, other}, {ok, bad} ->
          {ok, ["#{inspect(other)} needs \"setting\" and \"value\"" | bad]}

        {id, value}, {ok, bad} ->
          case by_id[id] do
            nil ->
              {ok, ["#{inspect(id)} isn't a setting tiny-axe has" | bad]}

            s ->
              case Value.parse(s.kind, value, s.now) do
                {:ok, v} ->
                  {[%{setting: s, value: v} | Enum.reject(ok, &(&1.setting.id == id))], bad}

                {:error, why} ->
                  {ok, ["#{id}: #{why}" | bad]}
              end
          end
      end)

    case problems do
      [] ->
        {already, changes} =
          ok
          |> Enum.reverse()
          |> Enum.split_with(&(&1.setting.kind != :action and same?(&1.setting.now, &1.value)))

        {:ok, changes, already}

      _ ->
        {:error, Enum.reverse(problems)}
    end
  end

  defp same?(nil, _), do: false
  defp same?(now, value), do: String.downcase(to_string(now)) == String.downcase(value)

  defp review(changes, already, context, notify) do
    questions =
      changes
      |> Enum.with_index()
      |> Map.new(fn {c, i} ->
        {:"change_#{i}",
         %{
           type: :noul,
           instructions: "Is this change part of what the user asked for: #{explain(c)}?"
         }}
      end)
      |> Map.put(:complete, %{
        type: :noul,
        instructions:
          "Would these changes, together with the settings already as asked, do " <>
            "everything the user asked?"
      })

    state = %{
      request: context.request,
      recent_conversation: Map.get(context, :recent_conversation, ""),
      changes: Enum.map_join(changes, "\n", &"- #{explain(&1)}"),
      already_as_asked:
        if(already == [],
          do: "none",
          else: Enum.map_join(already, "; ", &"#{label(&1.setting)} is already #{&1.value}")
        )
    }

    case TinyAxe.Decider.decide(state, questions) do
      {:ok, answers} ->
        scores =
          changes
          |> Enum.with_index()
          |> Enum.map(fn {c, i} -> {c, TinyAxe.Decider.p(answers, :"change_#{i}")} end)

        complete = TinyAxe.Decider.p(answers, :complete)
        all = [complete | Enum.map(scores, &elem(&1, 1))]
        score = if nil in all, do: nil, else: Enum.min(all)
        notify.({:review, score})
        threshold = TinyAxe.Decider.review_threshold()

        if is_number(score) and score < threshold do
          doubtful =
            for {c, p} <- scores, p < threshold, do: "- probably not asked for: #{describe(c)}"

          missing =
            if complete < threshold, do: ["- together they may not do everything asked"], else: []

          {:doubtful,
           "A reviewer checked the changes against the request:\n" <>
             Enum.join(doubtful ++ missing, "\n") <> "\n\nReply with corrected JSON."}
        else
          if score == nil, do: notify.({:decider_unavailable, "reviewing the appearance changes"})
          :ok
        end

      {:error, _} ->
        notify.({:decider_unavailable, "reviewing the appearance changes"})
        :ok
    end
  end

  ## Applying

  defp apply_changes(request, changes, reply, notify) do
    notify.({:stage, "changing the look…"})

    {lines, records} =
      Enum.map_reduce(changes, [], fn %{setting: s, value: v}, records ->
        file = s[:file] && s.file.()

        case s.apply.(v) do
          result when result == :ok or elem(result, 0) == :ok ->
            before = if is_tuple(result), do: elem(result, 1)
            now = s.current.()

            record = %{
              "setting" => s.id,
              "from" => s.now,
              "to" => v,
              "file" => file,
              "before" => before,
              "after_hash" => file && before && after_hash(file)
            }

            {"- #{label(s)}: #{transition(s, v, now)}", [record | records]}

          {:error, why} ->
            {"- #{label(s)}: ✗ not changed (#{why})", records}
        end
      end)

    records = Enum.reverse(records)
    Undo.push(request, records)

    head =
      if records == [],
        do: "*Nothing was changed:*",
        else: "*Changed without asking (appearance settings; `/look undo` puts them back):*"

    reply = if String.trim(reply) == "", do: "", else: "\n\n" <> String.trim(reply)
    head <> "\n" <> Enum.join(lines, "\n") <> reply
  end

  defp after_hash(file) do
    case File.read(file) do
      {:ok, text} -> Undo.hash(text)
      _ -> nil
    end
  end

  defp transition(%{kind: :action}, _v, _now), do: "done"

  defp transition(s, v, now) do
    from = s.now || "?"

    cond do
      now == nil or same?(now, v) -> "#{from} → #{v}"
      true -> "#{from} → #{v} (but it reads back as #{now})"
    end
  end

  defp from_site(changes, reply) do
    "Appearance changes can only be made from tiny-axe on this computer, not from the " <>
      "site. Asked here, I'd change:\n" <>
      Enum.map_join(changes, "\n", &"- #{describe(&1)}") <>
      if(String.trim(reply) == "", do: "", else: "\n\n" <> reply)
  end

  @doc "Undoes the newest appearance request's changes, as a line for the transcript."
  @spec undo() :: String.t()
  def undo do
    case Undo.undo_last() do
      :empty ->
        "no appearance changes to undo"

      {:ok, record, results} ->
        parts =
          Enum.map_join(results, "; ", fn
            {id, :ok} -> "#{id} put back"
            {id, {:error, why}} -> "#{id} not put back (#{why})"
          end)

        "↶ undid “#{record["request"]}”: #{parts}"
    end
  end

  @doc "The current appearance settings, as lines for `/look`."
  @spec describe_current() :: String.t()
  def describe_current do
    snapshot()
    |> Enum.reject(&(&1.kind == :action))
    |> Enum.group_by(& &1.group)
    |> Enum.map_join("\n", fn {group, list} ->
      "#{group}: " <> Enum.map_join(list, " · ", &"#{label(&1)} #{&1.now || "?"}")
    end)
  end

  ## Prompts

  defp system_prompt do
    """
    You change how the user's desktop and terminal look, for tiny-axe. You never write \
    commands: you pick settings from the list below and give each a value, and tiny-axe \
    checks and applies them (they can be undone).

    Reply with JSON:
    - "changes": the settings to change, each {"setting": an id from the list, "value": text}. \
    Values must be one of the listed choices, or a number in the listed range; "+2" or "-2" \
    changes a number from its current value. "bigger"/"smaller" means about 2 points or pixels.
    - "reply": one short sentence for the user about what you changed. If the user only asks \
    how something is set, leave "changes" empty and answer from the current values. If \
    nothing in the list can do what they ask, leave "changes" empty and say so.

    Only change what the user asked for. The terminal is Ghostty; "terminal" settings only \
    change it, while "text_size" scales text everywhere (bar, apps and terminals) at once.
    """
  end

  defp first_message(history, prompt, settings) do
    recent =
      history
      |> Enum.take(-4)
      |> Enum.map_join("\n", &"#{&1.role}: #{String.slice(&1.content, 0, 400)}")

    [
      recent != "" && "Conversation so far:\n#{recent}",
      "Request: #{prompt}",
      "Settings (id — what it is — now — values):\n" <> Enum.map_join(settings, "\n", &line/1)
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n\n")
  end

  defp line(s) do
    "- #{s.id} — #{s.summary} — now: #{s.now || "unknown"} — #{values(s.kind)}"
  end

  defp values(:action), do: "value: \"now\" (does it once)"
  defp values(:image), do: "an image file path"
  defp values({:choice, fun}), do: "one of: " <> Enum.join(fun.(), ", ")
  defp values({:enum, names}), do: "one of: " <> Enum.join(names, ", ")
  defp values({:int, lo, hi}), do: "a whole number #{lo}–#{hi}"
  defp values({:float, lo, hi}), do: "a number #{lo}–#{hi}"

  defp values({:or, words, kind}),
    do: Enum.map_join(words, ", ", &inspect/1) <> ", or " <> values(kind)

  defp describe(%{setting: s, value: v}),
    do: if(s.kind == :action, do: label(s), else: "#{label(s)} → #{v}")

  # For the reviewer: what the setting is and where it's going from.
  defp explain(%{setting: s} = c) do
    from = if s.kind == :action or s.now == nil, do: "", else: ", now #{s.now}"
    "#{describe(c)} (#{s.summary}#{from})"
  end

  defp label(s), do: String.replace(s.id, "_", " ")

  defp text(v) when is_binary(v), do: String.trim(v)
  defp text(nil), do: ""
  defp text(v) when is_float(v), do: Settings.format_float(v)
  defp text(v) when is_number(v) or is_atom(v), do: to_string(v)
  defp text(_), do: ""

  defp user(content), do: %{role: "user", content: content}
end
