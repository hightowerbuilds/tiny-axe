defmodule TinyAxe.TUI do
  @moduledoc """
  The terminal UI: a scrolling transcript, a status bar, and a multiline prompt.

  This module owns input precedence and dispatches messages for the active job.
  File, command, and compaction workflows own their transitions; `TUI.Run`
  manages task startup and cancellation. `TUI.View` and `TUI.Overlays` build
  the screen, `TUI.Transcript` formats it, and `TUI.Conversation` builds history.

  The status bar shows how full the model's context window is. Once the
  conversation reaches half of it, older turns are compacted into a summary
  (`TinyAxe.Compactor`), shown in a sidebar on the right with the meter.

  Keys: `enter` send · `alt+enter` newline · `esc` cancel · `pgup`/`pgdn` scroll
  (and `↑`/`↓`/`home`/`end` with an empty prompt) · `ctrl+y` copy the newest code
  block, again for the one before · `ctrl+z` undo the last file plan ·
  `ctrl+k` compact now · `ctrl+t` show/hide the sidebar · `ctrl+l` clear · `ctrl+c` quit. When the model proposes file edits, each is
  shown as a diff: `y` save · `n` skip · `esc` skip the rest · `↑`/`↓` scroll.
  """

  use ExRatatui.App

  require Logger

  alias ExRatatui.Event
  alias TinyAxe.{Context, Files}
  alias TinyAxe.TUI.{CommandWorkflow, CompactionWorkflow, FileWorkflow, Run, Transcript, View}
  import TinyAxe.TUI.Conversation, only: [add_meta: 2]

  import TinyAxe.TUI.Presentation,
    only: [score: 1, review_label: 1, expected_total: 1, describe_class: 1]

  @impl true
  def mount(opts) do
    input = ExRatatui.textarea_new()
    # Test-mode TUIs keep to themselves unless a test asks for the shared session.
    session? = Keyword.get(opts, :session, opts[:test_mode] == nil)

    saved =
      if session?,
        do: TinyAxe.Session.restore(),
        else: %{history: [], transcript: [], summary: nil, crashed: nil}

    # What startup did about Ollama; shown once, not again after a TUI restart.
    startup = Enum.map(Application.get_env(:tiny_axe, :startup_notes, []), &{:meta, &1})
    Application.delete_env(:tiny_axe, :startup_notes)

    restored =
      if saved.crashed,
        do: [
          {:meta,
           "the screen crashed (#{crash_summary(saved.crashed)}) and restarted; your conversation was restored"}
        ],
        else: []

    size =
      case Keyword.get(opts, :test_mode) || ExRatatui.terminal_size() do
        {w, h} -> {w, h}
        _ -> {80, 24}
      end

    {:ok,
     %{
       input: input,
       # Completed turns sent back to the model as context.
       history: saved.history,
       # What the transcript shows: {:user | :assistant | :meta, text}
       transcript: saved.transcript ++ restored ++ startup,
       streaming: nil,
       pending_prompt: nil,
       # Transcript index where the current attempt's meta lines start.
       attempt_meta_from: 0,
       run: nil,
       # Proposed file edits awaiting y/n, first one shown; each carries its diff.
       pending_edits: [],
       # Edits the user said y to, saved together once all have an answer.
       accepted_edits: [],
       edit_scroll: 0,
       # A file plan awaiting y/n, the plan being carried out, and a monitor on
       # the Runner so a crash there surfaces as an interrupted plan.
       pending_plan: nil,
       # Shell commands awaiting y/n, and the one running (with its output so far).
       pending_commands: nil,
       running_cmd: nil,
       plan_scroll: 0,
       ops_job: nil,
       ops_monitor: nil,
       # An interrupted plan found in the journal, awaiting r/c/k.
       recovery: List.first(TinyAxe.Ops.Journal.interrupted()),
       # The plan ctrl+z would undo, awaiting y/n.
       confirm_undo: nil,
       # Whether requests may go to Claude or Codex this session: nil (ask when
       # one first needs to), true or false. And the question being asked.
       remote: nil,
       asking: nil,
       # An agent's tool call waiting for y / a / n (TinyAxe.Tools.Gate).
       tool_ask: nil,
       # A purchase waiting for the user to type its total (TinyAxe.Purchases).
       purchase_ask: nil,
       # /credit-card in progress (TinyAxe.TUI.CardFlow): nothing secret in it.
       card_flow: nil,
       # Whether this request is an agent run: its answer goes after its tool lines.
       agent_run: false,
       status: "ready",
       # :bottom follows new output; a line number keeps the view on that line.
       scroll: :bottom,
       size: size,
       tick: 0,
       halt_on_exit: Keyword.get(opts, :halt_on_exit, false),
       session?: session?,
       # The compacted summary of older turns: %{text, turns, check, before, after}.
       summary: saved.summary,
       # The summary as it streams in while compacting.
       compacting: nil,
       # Tokens per character, recalibrated from each measured request.
       ratio: Context.default_ratio(),
       # The last request's measured size (Ollama's counts).
       usage: nil,
       # nil shows the sidebar automatically on wide screens; ctrl+t sets true/false.
       sidebar: nil,
       # How many code blocks back the next ctrl+y copies; reset by each new request.
       copy_back: 0,
       # Tests swap in a function that doesn't touch the real clipboard.
       clipboard: Keyword.get(opts, :clipboard, &TinyAxe.Clipboard.copy/1)
     }}
  end

  @impl true
  defdelegate render(state, frame), to: View

  ## Input

  # Every event and message goes through these, so the conversation is saved
  # outside this process after any change (see TinyAxe.Session).
  @impl true
  def handle_event(event, state), do: event |> on_event(state) |> saved(state)

  @impl true
  def handle_info(msg, state), do: msg |> on_info(state) |> saved(state)

  defp saved(result, before) do
    now = elem(result, 1)

    changed? =
      now.transcript != before.transcript or now.history != before.history or
        now.summary != before.summary

    if now.session? and changed?,
      do: TinyAxe.Session.save(now.history, now.transcript, now.summary)

    result
  end

  defp on_event(%Event.Key{kind: "release"}, state), do: {:noreply, state}

  defp on_event(%Event.Key{code: "c", modifiers: ["ctrl"]}, state) do
    if state.card_flow, do: TinyAxe.Cards.discard_entry()
    {:stop, Run.cancel(state)}
  end

  # /credit-card: every key goes to the flow (and its secrets to the vault).
  defp on_event(%Event.Key{code: code}, %{card_flow: flow} = state) when flow != nil do
    case TinyAxe.TUI.CardFlow.key(flow, code) do
      {:cont, flow} ->
        {:noreply, %{state | card_flow: flow}}

      {:done, message} ->
        {:noreply, %{state | card_flow: nil, status: "ready"} |> add_meta(message)}

      {:cancel, message} ->
        {:noreply, %{state | card_flow: nil, status: "ready"} |> add_meta(message)}
    end
  end

  defp on_event(%Event.Paste{content: content}, %{card_flow: flow} = state) when flow != nil,
    do: {:noreply, %{state | card_flow: TinyAxe.TUI.CardFlow.paste(flow, content)}}

  # The request waits for this answer; it holds for the rest of the session.
  defp on_event(%Event.Key{code: code}, %{asking: ask} = state) when ask != nil do
    case code do
      "y" ->
        send(ask.reply_to, {:remote_answer, ask.ref, true})

        {:noreply,
         %{state | asking: nil, remote: true, status: "asking #{ask.to}…"}
         |> add_meta(
           "↗ allowed Claude and Codex for this session: requests that fall short can leave this machine"
         )}

      c when c in ["n", "esc"] ->
        send(ask.reply_to, {:remote_answer, ask.ref, false})

        {:noreply,
         %{state | asking: nil, remote: false}
         |> add_meta("kept everything on this machine for this session")}

      _ ->
        {:noreply, state}
    end
  end

  # A purchase: the exact total, typed, buys; esc refuses. Nothing else answers it.
  defp on_event(%Event.Key{code: code}, %{purchase_ask: ask} = state) when ask != nil do
    if code == "esc" do
      send(ask.reply_to, {:purchase_answer, ask.ref, :deny})
      what = if ask[:mode] == :card_step, do: "didn't fill the card in", else: "didn't buy"
      {:noreply, %{state | purchase_ask: nil} |> add_meta("#{what} at #{ask.summary["host"]}")}
    else
      case purchase_key(ask, code) do
        {:ask, ask} ->
          {:noreply, %{state | purchase_ask: ask}}

        :confirm ->
          send(ask.reply_to, {:purchase_answer, ask.ref, :confirm})

          status =
            if ask[:mode] == :card_step, do: "filling the card in…", else: "placing the order…"

          {:noreply, %{state | purchase_ask: nil, status: status}}

        :deny ->
          send(ask.reply_to, {:purchase_answer, ask.ref, :deny})

          {:noreply,
           %{state | purchase_ask: nil}
           |> add_meta("didn't fill the card in at #{ask.summary["host"]}")}
      end
    end
  end

  # The agent's call waits for this answer in the gate.
  defp on_event(%Event.Key{code: code}, %{tool_ask: ask} = state) when ask != nil do
    handoff? = ask[:class] == :handoff
    session_ok? = Map.get(ask, :session_ok, true)

    answer =
      case code do
        "y" when handoff? ->
          {:once, "you did it in the browser"}

        "y" ->
          {:once, "allowed #{ask.tool} once"}

        "a" when not handoff? and session_ok? ->
          {:session, "allowed #{ask.tool} for this session"}

        c when c in ["n", "esc"] and handoff? ->
          {:deny, "you didn't do it in the browser"}

        c when c in ["n", "esc"] ->
          {:deny, "refused #{ask.tool}"}

        _ ->
          nil
      end

    case answer do
      {reply, meta} ->
        send(ask.reply_to, {:tool_answer, ask.ref, reply})
        {:noreply, %{state | tool_ask: nil, status: "working…"} |> add_meta(meta)}

      nil ->
        {:noreply, state}
    end
  end

  # While a popup is on screen, keys answer it instead of going to the prompt.
  defp on_event(%Event.Key{code: code}, %{recovery: plan} = state) when plan != nil,
    do: FileWorkflow.recovery_key(code, state)

  defp on_event(%Event.Key{code: code}, %{confirm_undo: plan} = state) when plan != nil,
    do: FileWorkflow.undo_key(code, state)

  defp on_event(%Event.Key{code: code}, %{pending_commands: plan} = state) when plan != nil,
    do: CommandWorkflow.key(code, state)

  defp on_event(%Event.Key{code: code}, %{pending_plan: plan} = state) when plan != nil,
    do: FileWorkflow.plan_key(code, state)

  defp on_event(%Event.Key{code: "z", modifiers: ["ctrl"]}, %{run: nil, ops_job: nil} = state),
    do: FileWorkflow.request_undo(state)

  # While an edit is on screen, keys answer it instead of going to the prompt.
  defp on_event(%Event.Key{code: code}, %{pending_edits: [edit | _]} = state) do
    {:noreply, FileWorkflow.edit_key(code, edit, state)}
  end

  defp on_event(%Event.Key{code: "esc"}, %{run: run} = state) when run != nil do
    {:noreply, %{Run.cancel(state) | status: "cancelled"}}
  end

  defp on_event(%Event.Key{code: "l", modifiers: ["ctrl"]}, %{run: nil} = state) do
    # The transcript's measured heights go with it.
    Transcript.clear_cache()

    {:noreply,
     %{
       state
       | history: [],
         transcript: [],
         summary: nil,
         pending_edits: [],
         scroll: :bottom,
         status: "cleared"
     }}
  end

  defp on_event(%Event.Key{code: "enter", modifiers: []}, state), do: submit(state)

  defp on_event(%Event.Key{code: "enter"}, state) do
    ExRatatui.textarea_handle_key(state.input, "enter", [])
    {:noreply, state}
  end

  defp on_event(%Event.Key{code: "k", modifiers: ["ctrl"]}, %{run: nil} = state),
    do: {:noreply, CompactionWorkflow.start(state)}

  defp on_event(%Event.Key{code: "t", modifiers: ["ctrl"]}, state) do
    {w, _h} = state.size
    {:noreply, %{state | sidebar: not View.sidebar?(state, w)}}
  end

  defp on_event(%Event.Key{code: "y", modifiers: ["ctrl"]}, state), do: {:noreply, copy(state)}

  defp on_event(%Event.Key{code: "page_up"}, state),
    do: {:noreply, View.scroll_by(state, -page(state))}

  defp on_event(%Event.Key{code: "page_down"}, state),
    do: {:noreply, View.scroll_by(state, page(state))}

  # With an empty prompt, arrows, home and end scroll the transcript. Terminals
  # also turn the mouse wheel into arrow keys, so this makes the wheel scroll.
  defp on_event(%Event.Key{code: code, modifiers: []} = key, state)
       when code in ["up", "down", "home", "end"] do
    if ExRatatui.textarea_get_value(state.input) == "" do
      {:noreply,
       case code do
         "up" -> View.scroll_by(state, -3)
         "down" -> View.scroll_by(state, 3)
         "home" -> View.scroll_to(state, 0)
         "end" -> %{state | scroll: :bottom}
       end}
    else
      ExRatatui.textarea_handle_key(state.input, key.code, key.modifiers)
      {:noreply, state}
    end
  end

  defp on_event(%Event.Key{code: code, modifiers: mods}, state) do
    ExRatatui.textarea_handle_key(state.input, code, mods)
    {:noreply, state}
  end

  defp on_event(%Event.Paste{content: content}, state) do
    ExRatatui.textarea_insert_str(state.input, content)
    {:noreply, state}
  end

  defp on_event(%Event.Resize{width: w, height: h}, state) do
    {:noreply, %{state | size: {w, h}}}
  end

  defp on_event(_event, state), do: {:noreply, state}

  ## Copying

  # Copies the newest code block, then older ones on each press; with no code
  # blocks, the last answer. The transcript keeps the original text, so the
  # copy has ordinary spaces (not the ones used to keep indentation on screen).
  defp copy(state) do
    answers = for {:assistant, text} <- Enum.reverse(state.transcript), do: text

    blocks =
      Enum.flat_map(answers, fn text ->
        ~r/```([^\n]*)\n(.*?)```/s
        |> Regex.scan(text, capture: :all_but_first)
        |> Enum.reverse()
      end)

    {text, label} =
      case {blocks, answers} do
        {[], []} ->
          {nil, nil}

        {[], [last | _]} ->
          {last, "the last answer"}

        _ ->
          [info, code] = Enum.at(blocks, rem(state.copy_back, length(blocks)))
          lang = info |> String.split() |> List.first("code")
          n = rem(state.copy_back, length(blocks)) + 1
          lines = code |> String.split("\n", trim: true) |> length()
          {code, "#{lang} block #{n} of #{length(blocks)} (#{lines} lines)"}
      end

    if text == nil do
      %{state | status: "nothing to copy yet"}
    else
      case state.clipboard.(text) do
        :ok ->
          more = if length(blocks) > 1, do: " · ctrl+y again for the one before", else: ""
          %{state | copy_back: state.copy_back + 1, status: "copied #{label}#{more}"}

        {:error, reason} ->
          hint = if reason == :no_clipboard_tool, do: " (install wl-clipboard)", else: ""
          %{state | status: "couldn't copy: #{inspect(reason)}#{hint}"}
      end
    end
  end

  defp page(state), do: View.page(state)

  defp submit(%{run: run} = state) when run != nil, do: {:noreply, state}

  defp submit(state) do
    prompt = state.input |> ExRatatui.textarea_get_value() |> String.trim()

    cond do
      prompt == "" ->
        {:noreply, state}

      # cd, pwd, tools and /credit-card are handled here, like shell built-ins:
      # no model involved.
      prompt in ["pwd", "tools"] or prompt =~ ~r/\Acd(\s|\z)/ or
          String.starts_with?(prompt, "/credit-card") ->
        ExRatatui.textarea_set_value(state.input, "")
        {:noreply, builtin(state, prompt)}

      true ->
        ExRatatui.textarea_set_value(state.input, "")

        # A card number typed into the prompt never reaches a model, the
        # transcript or the history: it's removed here, before anything else.
        case TinyAxe.Tools.Redact.text(prompt) do
          ^prompt ->
            {:noreply, Run.request(state, prompt)}

          redacted ->
            state =
              state
              |> Run.request(redacted)
              |> add_meta(
                "🔒 removed a card number from your message: card numbers never go to a model. " <>
                  "To pay with a card, store it in your keyring and register it with " <>
                  "`mix tiny_axe.purchases card add` (see `mix help tiny_axe.purchases`)"
              )

            {:noreply, state}
        end
    end
  end

  defp builtin(state, "pwd"),
    do: add_meta(state, "📍 #{TinyAxe.Ops.show(TinyAxe.Location.current())}")

  defp builtin(state, "/credit-card" <> rest) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [""] ->
        %{state | card_flow: TinyAxe.TUI.CardFlow.new(), status: "adding a card…"}

      ["list"] ->
        case TinyAxe.Cards.list() do
          [] ->
            add_meta(state, "no cards yet; add one with /credit-card")

          cards ->
            Enum.reduce(cards, state, fn c, st ->
              until =
                cond do
                  c[:remember] == "session" or c[:keyring] == nil -> "this session only"
                  c[:expires_at] -> "until #{String.slice(c.expires_at, 0, 10)}"
                  true -> "until you remove it"
                end

              add_meta(
                st,
                "💳 #{c.label} (#{c[:brand]} ••#{c[:last4]}) · #{until}" <>
                  if(c[:purpose], do: " · for #{c.purpose}", else: "") <>
                  if(c[:pin], do: " · PIN", else: "")
              )
            end)
        end

      ["forget", label] ->
        case TinyAxe.Cards.forget(String.trim(label)) do
          :ok ->
            add_meta(state, "💳 forgot #{label}: wiped from tiny-axe and your keyring")

          {:error, :not_found} ->
            add_meta(state, "no card called #{label} (see /credit-card list)")
        end

      _ ->
        add_meta(state, "/credit-card · /credit-card list · /credit-card forget NAME")
    end
  end

  # What the agent can use: each MCP server (and the browser), and its tools by class.
  defp builtin(state, "tools") do
    case TinyAxe.MCP.status() do
      [] ->
        add_meta(
          state,
          "no tools connected; add MCP servers with `mix tiny_axe.mcp add` (see `mix help tiny_axe.mcp`)"
        )

      servers ->
        Enum.reduce(servers, state, fn s, state ->
          line =
            cond do
              s.running ->
                counts =
                  for class <- [:read, :local, :per_action, :outward, :refused],
                      n = length(s.tools[class] || []),
                      n > 0,
                      do: "#{n} #{tool_class_word(class)}"

                "🔧 #{s.name}: #{Enum.join(counts, ", ")}"

              s.error ->
                "✗ #{s.name}: #{s.error}"

              true ->
                "· #{s.name}: not running"
            end

          line = if s.policy_error, do: line <> " (⚠ #{s.policy_error})", else: line
          add_meta(state, line)
        end)
    end
  end

  defp builtin(state, "cd" <> arg) do
    target = if String.trim(arg) == "", do: "~", else: String.trim(arg)

    case TinyAxe.Location.cd(target) do
      {:ok, abs} ->
        note =
          if TinyAxe.Ops.hidden?(abs),
            do: " (a hidden folder: tiny-axe can read here but won't change anything)",
            else: ""

        state
        |> add_meta("📍 #{TinyAxe.Ops.show(abs)}#{note}")
        |> Map.put(:status, "ready")

      {:error, :not_a_folder} ->
        add_meta(
          state,
          "cd: #{target} isn't a folder (you're in #{TinyAxe.Ops.show(TinyAxe.Location.current())})"
        )
    end
  end

  ## Pipeline events

  defp on_info({:pipeline, id, event}, %{run: {id, _pid}} = state) do
    {:noreply, apply_event(event, state)}
  end

  defp on_info({:pipeline, _stale_id, _event}, state), do: {:noreply, state, render?: false}

  defp on_info(:tick, %{run: nil} = state), do: {:noreply, state, render?: false}

  defp on_info(:tick, state) do
    Run.schedule_tick()
    {:noreply, %{state | tick: state.tick + 1}}
  end

  defp on_info({:DOWN, _ref, :process, pid, reason}, %{run: {_id, pid}} = state)
       when reason != :normal do
    {:noreply, Run.fail(state, Exception.format_exit(reason))}
  end

  defp on_info({:ops, id, event}, %{ops_job: id} = state),
    do: {:noreply, FileWorkflow.event(event, state)}

  # A result for a job the user already moved past (e.g. after a Runner restart).
  defp on_info({:ops, _id, _event}, state), do: {:noreply, state, render?: false}

  # The Runner died mid-job: the plan is now interrupted in the journal.
  defp on_info({:DOWN, ref, :process, _pid, reason}, %{ops_monitor: ref} = state),
    do: FileWorkflow.crashed(state, reason)

  defp on_info(_msg, state), do: {:noreply, state, render?: false}

  defp apply_event({:route, %{kind: kind} = route}, state) do
    web =
      Enum.map_join([web: "web", files: "files", change: "change"], fn {key, label} ->
        if route[key], do: " · #{label} #{pct(route[key].noul)}", else: ""
      end)

    meta =
      "route → #{kind.choice} (#{pct(kind.probabilities[kind.choice])}, confidence #{pct(kind.confidence)})" <>
        web

    %{
      state
      | transcript: state.transcript ++ [{:meta, meta}],
        status: "generating (#{kind.choice})…"
    }
  end

  defp apply_event({:search, s}, state) do
    meta =
      "web: searched #{inspect(s.query)} on #{s.engine} · #{s.results} results, read #{s.read} pages"

    %{state | transcript: state.transcript ++ [{:meta, meta}], status: "generating…"}
  end

  defp apply_event({:files, %{read: read, listed: n}}, state) do
    what = if read == [], do: "no file contents", else: Enum.join(read, ", ")
    meta = "files: read #{what} · #{n} files in the project"
    %{state | transcript: state.transcript ++ [{:meta, meta}], status: "generating…"}
  end

  defp apply_event({:edits, edits}, state) do
    edits = Enum.map(edits, &Map.put(&1, :diff, Files.diff(&1.old, &1.new)))
    %{state | pending_edits: state.pending_edits ++ edits, edit_scroll: 0}
  end

  defp apply_event({:edit_refused, %{path: path, reason: reason}}, state) do
    %{
      state
      | transcript:
          state.transcript ++ [{:meta, "✗ not offering the change to #{path}: #{reason}"}]
    }
  end

  defp apply_event({:plan, plan}, state), do: %{state | pending_plan: plan, plan_scroll: 0}

  defp apply_event({:moved, %{to: to} = m}, state) do
    how =
      if m.confidence,
        do: " (the request named it; Jev #{pct(m.confidence)})",
        else: " (where the commands went)"

    add_meta(state, "📍 moved to #{to}#{how}")
  end

  defp apply_event(event, state)
       when elem(event, 0) in [
              :command_plan,
              :command_problems,
              :cmd_start,
              :cmd_os_pid,
              :cmd_output,
              :cmd_exit,
              :cmds_checked,
              :cmds_refused,
              :cmds_done
            ],
       do: CommandWorkflow.event(event, state)

  defp apply_event({:looked, dirs}, state),
    do: add_meta(state, "looked in #{Enum.join(dirs, ", ")}")

  defp apply_event({:plan_problems, problems}, state),
    do: add_meta(state, "plan sent back to the model: " <> Enum.join(problems, " "))

  defp apply_event({:wrote, %{path: path, check: p}}, state),
    do: add_meta(state, "drafted #{path} (#{p |> review_label() |> elem(0)})")

  ## Escalation to bigger models

  defp apply_event({:ask_remote, ask}, state),
    do: %{state | asking: ask, status: "waiting for your answer…"}

  defp apply_event({:escalate, %{to: to, reason: why}}, state) do
    %{state | status: "asking #{to}…"}
    |> add_meta("↗ #{to}: the local model fell short (#{why})")
  end

  # Once per request: the same reason usually holds for every rung.
  defp apply_event({:escalate_skipped, %{reason: why}}, state),
    do: once_per_request(state, "↗ not using a bigger model: #{why}")

  defp apply_event({:escalate_failed, %{to: to, reason: reason}}, state),
    do: add_meta(state, "✗ #{to} couldn't answer: #{TinyAxe.Escalation.explain(reason)}")

  defp apply_event({:answered_by, %{model: label}}, state),
    do: add_meta(state, "→ answered by #{label}, off this machine")

  ## Purchases (TinyAxe.Purchases)

  defp apply_event({:purchase_approval, ask}, state) do
    stage = if ask[:mode] == :card_step, do: :consent, else: :total
    ask = Map.merge(ask, %{typed: "", stage: stage, masked: "", unlocked: [], hint: nil})
    %{state | purchase_ask: ask, status: "waiting for your answer…"}
  end

  defp apply_event({:purchase_refused, %{summary: s, failed: failed}}, state) do
    add_meta(
      state,
      "✗ tiny-axe won't buy at #{s["host"] || "this shop"}#{if s["total_text"], do: " (#{s["total_text"]})"}: " <>
        Enum.join(failed, "; ")
    )
  end

  defp apply_event({:purchase_changed, why}, state),
    do: add_meta(state, "✗ nothing was bought: #{why} while you were deciding")

  defp apply_event({:purchased, p}, state) do
    order = if p[:order], do: " · order #{p.order}", else: ""

    add_meta(
      state,
      "🧾 bought at #{p.host} for #{p.total_text}#{order} · receipt in #{TinyAxe.Ops.show(p.dir)}"
    )
  end

  ## Agent tool calls (TinyAxe.Tools.Gate)

  defp apply_event({:agent, %{driver: driver, servers: servers}}, state) do
    %{state | agent_run: true, streaming: "", status: "#{driver} is working…"}
    |> add_meta("🤖 #{driver} is working, with: #{Enum.join(servers, ", ")}")
  end

  defp apply_event({:agent_local, why}, state),
    do: add_meta(state, "the local model will drive instead (#{why})")

  defp apply_event({:tool_approval, ask}, state),
    do: %{state | tool_ask: ask, status: "waiting for your answer…"}

  defp apply_event({:tool_call, %{tool: tool, class: class, args: args} = call}, state) do
    shown = if args == %{}, do: "", else: " " <> String.slice(JSON.encode!(args), 0, 120)
    why = if call[:reason], do: ": #{call.reason}", else: ""
    add_meta(state, "🔧 #{tool}#{shown} (#{describe_class(class)}#{why})")
  end

  # Results that went through need no line of their own; the answer uses them.
  defp apply_event({:tool_result, %{decision: d, tool: tool, summary: why}}, state)
       when d in [:refused, :denied, :failed],
       do: add_meta(state, "✗ #{tool}: #{why}")

  defp apply_event({:tool_result, _}, state), do: state

  defp apply_event({:tool_limit, %{reason: why}}, state),
    do: add_meta(state, "⚠ the agent was stopped: #{why}")

  defp apply_event({:review, _}, state), do: state
  # Which way the request went; the route line already shows it.
  defp apply_event({:task, _}, state), do: state

  defp apply_event({:search_failed, s}, state) do
    meta =
      "web: search for #{inspect(s.query)} failed (#{inspect(s.reason)}), answering without it"

    %{state | transcript: state.transcript ++ [{:meta, meta}], status: "generating…"}
  end

  defp apply_event({:attempt, 1}, state),
    do: %{state | streaming: "", attempt_meta_from: length(state.transcript)}

  defp apply_event({:attempt, n}, state) do
    transcript = state.transcript ++ [{:meta, "retrying (attempt #{n})"}]

    %{
      state
      | streaming: "",
        transcript: transcript,
        attempt_meta_from: length(transcript),
        status: "generating (attempt #{n})…"
    }
  end

  defp apply_event({:stage, label}, state), do: %{state | status: label}

  defp apply_event({:check, {:skipped, reason}}, state)
       when reason in ["no Elixir or Python code", "disabled"],
       do: state

  defp apply_event({:check, {:skipped, reason}}, state) do
    %{state | transcript: state.transcript ++ [{:meta, "· code not checked: #{reason}"}]}
  end

  defp apply_event({:check, {:ran, %{status: :passed} = r}}, state) do
    %{state | transcript: state.transcript ++ [{:meta, "✓ #{r.language}: #{r.summary}"}]}
  end

  defp apply_event({:check, {:ran, %{status: :failed} = r}}, state) do
    first_line = r.output |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 120)
    detail = if first_line == "", do: "", else: " — `#{first_line}`"
    %{state | transcript: state.transcript ++ [{:meta, "✗ #{r.language}: #{r.summary}#{detail}"}]}
  end

  defp apply_event({:delta, text}, state),
    do: %{state | streaming: (state.streaming || "") <> text}

  defp apply_event({:verify, %{addresses: v} = verdict}, state) do
    claim =
      case verdict[:false_claim] do
        %{noul: p} when is_number(p) and p >= 0.5 ->
          " · ✗ claims to have run something it can't (#{pct(p)})"

        _ ->
          ""
      end

    %{
      state
      | transcript: state.transcript ++ [{:meta, "verifier score #{score(v.noul)}#{claim}"}],
        status: "verifying…"
    }
  end

  # The answer will be an earlier attempt, so it goes below every attempt's lines.
  defp apply_event({:chose, c}, state) do
    meta = "showing attempt #{c.attempt} of #{c.attempts}, the highest-rated (#{pct(c.score)})"
    transcript = state.transcript ++ [{:meta, meta}]
    %{state | transcript: transcript, attempt_meta_from: length(transcript)}
  end

  defp apply_event({:done, text}, state) do
    turn = [%{role: "user", content: state.pending_prompt}, %{role: "assistant", content: text}]

    # The answer goes above the check/verifier lines that judged it; an agent's
    # answer goes after the tool calls that led to it.
    from = if state.agent_run, do: length(state.transcript), else: state.attempt_meta_from
    {before, judged} = Enum.split(state.transcript, from)

    %{
      state
      | run: nil,
        streaming: nil,
        pending_prompt: nil,
        history: state.history ++ turn,
        transcript: before ++ [{:assistant, text} | judged],
        status: if(state.pending_edits == [], do: "ready", else: "review the proposed change")
    }
    |> CompactionWorkflow.maybe_start()
  end

  defp apply_event({:usage, usage}, state),
    do: %{state | usage: usage, ratio: Context.calibrate(state.ratio, usage)}

  defp apply_event(event, state) when elem(event, 0) in [:compact_delta, :compacted],
    do: CompactionWorkflow.event(event, state)

  defp apply_event({:error, reason}, state), do: Run.fail(state, inspect(reason))

  defp apply_event({:trimmed, %{cut: cut, before: before, after: after_}}, state) do
    add_meta(
      state,
      "✂ the request was too big for the model's window, so tiny-axe cut #{Enum.join(cut, " and ")} " <>
        "(~#{Context.short(before)} → ~#{Context.short(after_)} tokens)"
    )
  end

  # Once per request: which decision couldn't be made. The request carries on
  # without it, so the user should know what went unchecked.
  defp apply_event({:decider_unavailable, what}, state),
    do: once_per_request(state, "⚠ the decider couldn't answer (#{what}); carried on without it")

  # An event this TUI doesn't know is a bug elsewhere; log it rather than crash.
  defp apply_event(event, state) do
    Logger.warning("TinyAxe.TUI ignored an unknown event: #{inspect(event, limit: 5)}")
    state
  end

  defp tool_class_word(:read), do: "run"
  defp tool_class_word(:local), do: "run (local)"
  defp tool_class_word(:per_action), do: "judged per action"
  defp tool_class_word(:outward), do: "ask you first"
  defp tool_class_word(:refused), do: "refused"

  # Stages: the total typed (an order) or a yes (a card step), then whatever
  # the card needs typed to unlock it: its PIN, its CVC. Those keystrokes go
  # straight to the card vault; only dots come back.
  defp purchase_key(%{stage: :consent} = ask, "y"), do: unlock_or_confirm(ask)
  defp purchase_key(%{stage: :consent}, "n"), do: :deny
  defp purchase_key(%{stage: :consent} = ask, _), do: {:ask, ask}

  defp purchase_key(%{stage: :total} = ask, "enter") do
    expected = expected_total(ask.summary)

    if ask.typed == expected,
      do: unlock_or_confirm(ask),
      else: {:ask, Map.put(ask, :hint, "that's not the total; type #{expected} exactly")}
  end

  defp purchase_key(%{stage: :total} = ask, "backspace"),
    do: {:ask, %{ask | typed: String.slice(ask.typed, 0..-2//1)}}

  defp purchase_key(%{stage: :total} = ask, code) do
    if code =~ ~r/\A[0-9.]\z/ and String.length(ask.typed) < 12,
      do: {:ask, %{ask | typed: ask.typed <> code}},
      else: {:ask, ask}
  end

  defp purchase_key(%{stage: {:unlock, _field}} = ask, "enter") do
    if ask.masked == "",
      do: {:ask, Map.put(ask, :hint, "type it, then press enter (esc to stop)")},
      else: unlock_or_confirm(ask)
  end

  defp purchase_key(%{stage: {:unlock, field}} = ask, code) do
    {:ask, %{ask | masked: TinyAxe.Cards.unlock_key(ask.ref, field, code), hint: nil}}
  end

  defp unlock_or_confirm(ask) do
    done =
      case ask.stage do
        {:unlock, field} -> [field | ask.unlocked]
        _ -> ask.unlocked
      end

    case Enum.reject(ask[:needs] || [], &(&1 in done)) do
      [] -> :confirm
      [next | _] -> {:ask, %{ask | stage: {:unlock, next}, masked: "", unlocked: done, hint: nil}}
    end
  end

  defp once_per_request(state, text) do
    this_request = state.transcript |> Enum.reverse() |> Enum.take_while(&(elem(&1, 0) != :user))
    if {:meta, text} in this_request, do: state, else: add_meta(state, text)
  end

  defp pct(nil), do: "?"
  defp pct(p), do: "#{round(p * 100)}%"

  @impl true
  # Only a real quit stops tiny-axe. After a crash the supervisor restarts the
  # TUI, which restores the conversation from TinyAxe.Session.
  def terminate(reason, state) do
    if quit?(reason) do
      if state.halt_on_exit, do: System.stop(0)
    else
      if state.session?, do: TinyAxe.Session.crashed(reason)
    end
  end

  defp quit?(reason), do: reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)

  defp crash_summary(reason) do
    reason |> Exception.format_exit() |> String.split("\n") |> hd() |> String.slice(0, 120)
  end
end
