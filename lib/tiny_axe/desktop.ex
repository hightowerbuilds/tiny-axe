defmodule TinyAxe.Desktop do
  @moduledoc """
  Changes the desktop when asked: how it looks ("make the terminal font
  bigger", "switch to Tokyo Night", "no gaps between windows"), its sound,
  devices and default apps ("volume to 40", "turn bluetooth off", "make
  Brave my default browser"), and actions ("take a screenshot", "open
  Spotify", "remind me in 10 minutes to stretch", "reboot"), along a fixed
  path a small model can walk:

  1. **Read** — every setting's current value is read from the computer
     (`Desktop.Settings`), along with the real choices where there's a
     list (themes, fonts).
  2. **Fill** (the local model first) — the model answers in a fixed JSON
     shape: `changes` (a setting id from the list, which the JSON schema
     enforces, and a value) and `reply`. It never writes a command.
  3. **Check** (code) — each value is checked against its kind
     (`Desktop.Value`): one of the real choices, a number in range, an
     image that exists; `+2` is from the current value. Problems go back to
     the model with the real choices, up to #{3} rounds.
  4. **Review** (the Decider) — per change, is it needed for what was
     asked, and do they together do all of it? The weakest is the score; a
     doubtful plan goes back once with reasons.
  5. **Escalate** — when the local model can't produce changes that pass
     the checks and the review, the escalation ladder (`TinyAxe.Escalation`,
     Claude Haiku 5.5) fills the same shape from the start. Escalation
     changes who fills it in, never what may be set.
  6. **Apply** — low-risk changes (look and feel, sound, launching an app,
     a screenshot, a reminder) run without asking (the user's choice,
     2026-10-12), one at a time, and settings are read back. A plan with
     anything marked `risk: :ask` (bluetooth, wifi, default apps, screen
     recording, lock/log out/reboot/shut down) waits for the user's y/n, as
     does one the reviewer still doubts. `/look undo` puts the newest
     request's settings back (`Desktop.Undo`); actions can't be undone.
     Requests from the site's Chat tab (`origin: :site`) can't change
     anything: they get the plan and are told to ask on this computer.

  Events: `{:stage, text}`, `{:desktop_problems, [text]}`, `{:review, p}`,
  the escalation events, then `{:attempt, 1}` and `{:done, text}`.
  """

  alias TinyAxe.{Escalation, Model, Ollama}
  alias TinyAxe.Desktop.{Settings, Undo, Value}

  @max_rounds 3

  @doc """
  Handles a desktop request. `opts[:remote]`: whether the escalation
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
              do: "its desktop changes didn't pass the checks after #{@max_rounds} tries",
              else: "the reviewer doubted its desktop changes"

          # A doubtful plan is kept: if no bigger model does better, the user
          # is asked about it instead of it running without asking.
          escalated = fn choice, best ->
            case plan(messages, Map.put(context, :use, choice), settings, notify, 1, false) do
              {:ok, _, _} = sure -> {:ok, sure}
              {:doubtful, _, _} = doubtful -> {:fell_short, doubtful}
              {:gave_up, _, _} -> {:fell_short, best}
              {:reply, _} = reply -> {:ok, reply}
              {:unsupported, _} = unsupported -> {:ok, unsupported}
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
        if Enum.any?(changes, &(&1.setting[:risk] == :ask)),
          do: ask(prompt, changes, reply, notify, :risk),
          else: done(notify, apply_changes(prompt, changes, reply, :without_asking, notify))

      {:doubtful, changes, reply} ->
        ask(prompt, changes, reply, notify, :doubtful)

      {:gave_up, reply, _} ->
        done(notify, reply)

      {:reply, reply} ->
        done(notify, reply)

      {:unsupported, reply} ->
        hand_over(history, prompt, reply, site?, remote, notify)

      {:error, reason} ->
        notify.({:error, reason})
    end

    :ok
  end

  # Nothing in the list does it (a keybinding, a window rule, a service):
  # the agent (Claude Haiku 5.5) takes it, with os_run, which asks before
  # every command and snapshots ~/.config (TinyAxe.Desktop.OsRun). Not from
  # the site, whose approvals are refused anyway.
  defp hand_over(history, prompt, reply, site?, remote, notify) do
    cond do
      site? ->
        done(
          notify,
          "That needs a change outside tiny-axe's desktop settings, which can only be " <>
            "approved on this computer. Ask tiny-axe there."
        )

      not TinyAxe.Desktop.OsRun.available?() ->
        done(notify, reply)

      true ->
        notify.(
          {:escalate, %{to: "the agent", reason: "none of tiny-axe's desktop settings does that"}}
        )

        TinyAxe.Agent.run(history, prompt, notify, remote: remote)
    end
  end

  # The plan waits for the user's y/n in the TUI (the commands popup); only
  # setting ids and values are kept, and they're checked again when it runs
  # (`execute/2`).
  defp ask(request, changes, reply, notify, why) do
    notify.(
      {:desktop_plan,
       %{
         kind: :desktop,
         request: request,
         changes: Enum.map(changes, &%{"setting" => &1.setting.id, "value" => &1.value}),
         commands: Enum.map(changes, &%{command: describe(&1), review: nil}),
         review: nil,
         why: why,
         dir: TinyAxe.Location.current()
       }}
    )

    lines = Enum.map_join(changes, "\n", &"- #{describe(&1)}")
    reply = if String.trim(reply) == "", do: "", else: String.trim(reply) <> "\n\n"

    because =
      case why do
        :risk -> "these always ask first"
        :doubtful -> "the reviewer wasn't sure they're what you asked for"
      end

    done(
      notify,
      reply <> "**Desktop changes** (waiting for your approval: #{because}):\n\n" <> lines
    )
  end

  @doc """
  Makes an approved desktop plan's changes (from `{:desktop_plan, plan}`),
  checked again against the settings as they are now. Events:
  `{:stage, text}`, then `{:desktop_done, text}`.
  """
  @spec execute(map(), (term() -> any())) :: :ok
  def execute(plan, notify) do
    notify.({:stage, "changing the desktop…"})

    text =
      case check(plan.changes, snapshot()) do
        {:ok, [], _} -> "*Nothing to change: the settings are already as asked.*"
        {:ok, changes, _} -> apply_changes(plan.request, changes, "", :approved, notify)
        {:error, problems} -> "✗ didn't change anything; now:\n" <> Enum.join(problems, "\n")
      end

    notify.({:desktop_done, text})
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

            {:lookup, fun} ->
              names = fun.()
              {:lookup, fn -> names end}

            other ->
              other
          end

        Map.merge(s, %{now: s[:current] && s.current.(), kind: kind})
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
        {:error, :bad_desktop_json}
    end
  end

  defp planned(answer, messages, context, settings, notify, round, reviewed?) do
    reply = text(answer["reply"])

    case check(answer["changes"], settings, context.request) do
      {:ok, [], _already} ->
        if wants_change?(context), do: {:unsupported, reply}, else: {:reply, reply}

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
        notify.({:desktop_problems, problems})

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
  @spec check(term(), [map()], String.t() | nil) ::
          {:ok, [map()], [map()]} | {:error, [String.t()]}
  def check(changes, settings, request \\ nil) do
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
              # Several package installs are one install of them all.
              value =
                case {s.kind, Enum.find(ok, &(&1.setting.id == id))} do
                  {:packages, %{value: earlier}} -> earlier <> " " <> value
                  _ -> value
                end

              case Value.parse(s.kind, value, s.now) |> within_jump(s, request) do
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

  # Settings with a `max_jump` (volume) move at most that far when the
  # request gives no number: "louder" isn't "100".
  defp within_jump({:ok, v} = ok, %{max_jump: max, now: now} = s, request)
       when is_binary(request) and is_binary(now) do
    with false <- request =~ ~r/\d/,
         {new, _} <- Float.parse(v),
         {old, _} <- Float.parse(now),
         true <- abs(new - old) > max do
      {:error,
       "the user gave no number, so change #{s.id} by at most #{max} from #{now} " <>
         "(e.g. \"+10\" or \"-10\")"}
    else
      _ -> ok
    end
  end

  defp within_jump(result, _s, _request), do: result

  # No item fits, or it's a question? The model's own flag for this proved
  # unreliable (it wrote "Opening Obsidian now" and flagged it unsupported),
  # so the decider says whether the user wants something changed or done.
  defp wants_change?(context) do
    question = %{
      change: %{
        type: :noul,
        instructions:
          "Does the user want something on their computer changed, installed, set up or " <>
            "done, rather than only asking how something is set or what it is?"
      }
    }

    TinyAxe.Decider.yes?(
      TinyAxe.Decider.decide(%{request: context.request}, question),
      :change,
      TinyAxe.Decider.review_threshold()
    )
  end

  defp same?(nil, _), do: false
  defp same?(now, value), do: String.downcase(to_string(now)) == String.downcase(value)

  # Changes to settings the request names outright ("put the terminal tabs
  # at the bottom") need no review: the decider second-guessed exactly
  # those (2026-10-12). Only the others are reviewed, if there are any.
  defp review(changes, already, context, notify) do
    {named, unnamed} =
      Enum.split_with(changes, fn %{setting: s, value: v} ->
        Settings.named?(s.id, v, s.kind, context.request)
      end)

    if named != [], do: notify.({:review_skipped, Enum.map(named, & &1.setting.id)})

    case unnamed do
      [] -> :ok
      _ -> review_unnamed(unnamed, already ++ named, context, notify)
    end
  end

  defp review_unnamed(changes, already, context, notify) do
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
          "Would these changes, together with the ones already as asked or named by " <>
            "the user, do everything the user asked?"
      })

    state = %{
      request: context.request,
      recent_conversation: Map.get(context, :recent_conversation, ""),
      changes: Enum.map_join(changes, "\n", &"- #{explain(&1)}"),
      already_as_asked_or_named:
        if(already == [],
          do: "none",
          else: Enum.map_join(already, "; ", &"#{label(&1.setting)}: #{&1.value}")
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
          if score == nil, do: notify.({:decider_unavailable, "reviewing the desktop changes"})
          :ok
        end

      {:error, _} ->
        notify.({:decider_unavailable, "reviewing the desktop changes"})
        :ok
    end
  end

  ## Applying

  defp apply_changes(request, changes, reply, how, notify) do
    notify.({:stage, "changing the desktop…"})

    {lines, records} =
      Enum.map_reduce(changes, [], fn %{setting: s, value: v}, records ->
        file = s[:file] && s.file.()

        case s.apply.(v) do
          result when result == :ok or elem(result, 0) == :ok ->
            before = if is_tuple(result), do: elem(result, 1)
            now = s[:current] && s.current.()

            record = %{
              "setting" => s.id,
              "from" => s.now,
              "to" => v,
              "file" => file,
              "before" => before,
              "after_hash" => file && before && after_hash(file)
            }

            records = if undoable?(s), do: [record | records], else: records
            {"- #{label(s)}: #{transition(s, v, now)}", records}

          {:error, why} ->
            {"- #{label(s)}: ✗ not done (#{why})", records}
        end
      end)

    records = Enum.reverse(records)
    Undo.push(request, records)

    done? = Enum.any?(lines, &(not String.contains?(&1, "✗ not done")))

    head =
      cond do
        not done? -> "*Nothing was changed:*"
        how == :approved -> "*Done, after you approved:*"
        true -> "*Done without asking (low-risk desktop changes):*"
      end

    undo = if records == [], do: "", else: "\n\n`/look undo` puts the settings back."
    reply = if String.trim(reply) == "", do: "", else: "\n\n" <> String.trim(reply)
    head <> "\n" <> Enum.join(lines, "\n") <> undo <> reply
  end

  # Actions just happen (a screenshot, a reboot); settings can be put back.
  defp undoable?(s), do: Map.get(s, :undo, :value) != :none

  defp after_hash(file) do
    case File.read(file) do
      {:ok, text} -> Undo.hash(text)
      _ -> nil
    end
  end

  defp transition(%{kind: :action}, _v, _now), do: "done"
  defp transition(%{undo: :none}, v, _now), do: "#{v}, done"

  defp transition(s, v, now) do
    from = s.now || "?"

    cond do
      now == nil or same?(now, v) -> "#{from} → #{v}"
      true -> "#{from} → #{v} (but it reads back as #{now})"
    end
  end

  defp from_site(changes, reply) do
    "Desktop changes can only be made from tiny-axe on this computer, not from the " <>
      "site. Asked here, I'd change:\n" <>
      Enum.map_join(changes, "\n", &"- #{describe(&1)}") <>
      if(String.trim(reply) == "", do: "", else: "\n\n" <> reply)
  end

  @doc "Undoes the newest desktop request's settings, as a line for the transcript."
  @spec undo() :: String.t()
  def undo do
    case Undo.undo_last() do
      :empty ->
        "no desktop changes to undo"

      {:ok, record, results} ->
        parts =
          Enum.map_join(results, "; ", fn
            {id, :ok} -> "#{id} put back"
            {id, {:error, why}} -> "#{id} not put back (#{why})"
          end)

        "↶ undid “#{record["request"]}”: #{parts}"
    end
  end

  @doc "The current desktop settings, as lines for `/look`."
  @spec describe_current() :: String.t()
  def describe_current do
    snapshot()
    |> Enum.reject(&(&1.kind == :action or not undoable?(&1) or &1[:current] == nil))
    |> Enum.group_by(& &1.group)
    |> Enum.map_join("\n", fn {group, list} ->
      "#{group}: " <> Enum.map_join(list, " · ", &"#{label(&1)} #{&1.now || "?"}")
    end)
  end

  ## Prompts

  defp system_prompt do
    """
    You control the user's desktop for tiny-axe: how it and the terminal look, sound, \
    devices, default apps, and actions such as screenshots, opening apps or web pages, \
    reminders, restarting a part of the desktop, and locking, logging out, rebooting or \
    shutting down. You never write commands: you pick items from the list below and give \
    each a value, and tiny-axe checks them and carries them out. Settings can be undone; \
    actions can't. Some always ask the user first; tiny-axe handles that.

    Reply with JSON:
    - "changes": the items to change or do, each {"setting": an id from the list, \
    "value": text}. Values must be one of the listed choices, or a number in the listed \
    range; "+2" or "-2" changes a number from its current value. "bigger"/"smaller" means \
    about 2 points or pixels.
    - "reply": one short sentence for the user about what you're doing. If the user only \
    asks how something is set, leave "changes" empty and answer from the current values. \
    If no item in the list can do what they ask (a keybinding, a window rule, a config \
    file), leave "changes" empty: tiny-axe hands it to a bigger model.

    Only change or do what the user asked for. The terminal is Ghostty; "terminal" \
    settings only change it, while "text_size" scales text everywhere (bar, apps and \
    terminals) at once. "Restart the computer" is power reboot, not restart.
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
      "Items (id — what it is — now — values):\n" <>
        Enum.map_join(settings, "\n", &line(&1, prompt))
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n\n")
  end

  defp line(s, request) do
    now =
      cond do
        not undoable?(s) -> "action"
        s.now -> "now: #{s.now}"
        true -> "now: unknown"
      end

    "- #{s.id} — #{s.summary} — #{now} — #{values_for(s.kind, request)}"
  end

  defp values(:action), do: "value: \"now\" (does it once)"
  defp values(:image), do: "an image file path"
  defp values(:url), do: "a web address"
  defp values(:reminder), do: "minutes, then the message"
  defp values(:packages), do: "package names, separated by spaces"
  defp values(:service), do: "the action, then the unit"

  defp values({:choice, fun}), do: "one of: " <> Enum.join(fun.(), ", ")
  defp values({:enum, names}), do: "one of: " <> Enum.join(names, ", ")
  defp values({:int, lo, hi}), do: "a whole number #{lo}–#{hi}"
  defp values({:float, lo, hi}), do: "a number #{lo}–#{hi}"

  defp values({:or, words, kind}),
    do: Enum.map_join(words, ", ", &inspect/1) <> ", or " <> values(kind)

  # A long list shows the names the request mentions first, so "uninstall
  # obsidian" sees obsidian among the examples.
  defp values_for({:lookup, fun}, request) do
    words =
      request
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/, trim: true)
      |> Enum.filter(&(String.length(&1) >= 3))

    all = fun.()

    {mentioned, rest} =
      Enum.split_with(all, fn name ->
        key = String.downcase(name)
        Enum.any?(words, &String.contains?(key, &1))
      end)

    names = Enum.take(mentioned, 6) ++ rest

    "one of #{length(all)} names on this computer (any of them works, not only these " <>
      "examples), e.g. #{names |> Enum.take(8) |> Enum.join(", ")}"
  end

  defp values_for(kind, _request), do: values(kind)

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
