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
  `ctrl+k` compact now · `ctrl+t` show/hide the sidebar · `ctrl+o` next chat ·
  `alt+←`/`alt+→` previous/next chat · `alt+1`…`alt+9` select a chat ·
  `ctrl+l` clear this chat · `ctrl+c` quit. When the model proposes file edits, each is
  shown as a diff: `y` save · `n` skip · `esc` skip the rest · `↑`/`↓` scroll.

  Chats (`TUI.Chats`): `/new` starts another chat while the one left keeps
  working, `/chats` lists them, `/chat N` switches, `/chat close` closes an
  idle one. Questions from any chat show up wherever you are.

  `/token` shows token use by Claude Haiku, Jev and the local model
  (`TUI.TokenDash`).

  `/look` lists the desktop's settings as they are now, and `/look undo`
  puts back the newest desktop change (`TinyAxe.Desktop`).

  `/remote on|off` lets the site's /remote page reach this tiny-axe: its
  messages are answered in a 🌐 chat of their own (`TUI.RemoteChat`).

  History (`TUI.ChatHistory`, `TinyAxe.History`): every chat is kept on disk;
  `/history` lists the recent ones, `/history N` reopens one, `/history words`
  finds them. Your page of tiny-axe's website shows all of them under Chats.
  """

  use ExRatatui.App

  require Logger

  alias ExRatatui.Event
  alias TinyAxe.{Context, Files}

  alias TinyAxe.TUI.{
    ChatHistory,
    MemoryChat,
    Chats,
    RemoteChat,
    CommandWorkflow,
    CompactionWorkflow,
    FileWorkflow,
    FeaturePanels,
    MainTabs,
    Pulse,
    Run,
    SearchWorkspace,
    TabBar,
    Transcript,
    View,
    Welcome,
    Workspace
  }

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

    # Test-mode TUIs get no timer; tests send :pulse themselves.
    if opts[:test_mode] == nil and Pulse.enabled?(), do: Pulse.schedule()

    {:ok,
     %{
       input: input,
       section: :chat,
       chat_section: nil,
       search_chat: nil,
       search_mode: :words,
       panels: FeaturePanels.new(),
       # Completed turns sent back to the model as context.
       history: saved.history,
       # What the transcript shows: {:user | :assistant | :meta, text}
       transcript: saved.transcript ++ restored ++ startup,
       # This chat's id in the history (TinyAxe.History).
       saved_as: saved[:saved_as] || TinyAxe.History.new_id(),
       # The chats the last /history listed, by number (TinyAxe.TUI.ChatHistory).
       history_shown: [],
       local_only: saved[:local_only] == true,
       memory_results: nil,
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
       # Questions (asking, tool_ask, purchase_ask) that arrived while another
       # was on screen, oldest first, as {field, ask}: each is shown in turn.
       waiting: [],
       # /credit-card in progress (TinyAxe.TUI.CardFlow): nothing secret in it.
       card_flow: nil,
       # Making or signing in to the account (TinyAxe.TUI.AccountFlow): on
       # screen from the start while one is required and there's none. Its
       # running job's ref, so a stale answer is dropped.
       account_flow: first_account_flow(opts),
       account_job: nil,
       # /token's popup (TinyAxe.TUI.TokenDash), while it's open.
       token_dash: nil,
       # The site's /remote page (TinyAxe.TUI.RemoteChat): its connection, the
       # message being answered in the 🌐 chat and those queued.
       remote_link: RemoteChat.new(opts),
       # Whether the chat on screen is the 🌐 one (a chat's own field, TUI.Chats).
       remote_chat: false,
       # Whether this request is an agent run: its answer goes after its tool lines.
       agent_run: false,
       status: "ready",
       # :bottom follows new output; a line number keeps the view on that line.
       scroll: :bottom,
       size: size,
       tick: 0,
       # The prompt cursor's pulse (TinyAxe.TUI.Pulse): its frame and the
       # textarea's first visible row.
       pulse: Pulse.new(),
       welcome: Welcome.new(opts),
       halt_on_exit: Keyword.get(opts, :halt_on_exit, false),
       # The chats put aside, which keep running; the active one's fields are
       # the ones here (TinyAxe.TUI.Chats lists which).
       chats: Chats.restore(saved),
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
     }
     |> Welcome.sync()
     |> then(&if(session?, do: RemoteChat.subscribe(&1), else: &1))}
  end

  @impl true
  defdelegate render(state, frame), to: View

  ## Input

  # Every event and message goes through these, so the conversation is saved
  # outside this process after any change (see TinyAxe.Session).
  @impl true
  # A key answering another chat's question, or a message for a chat put
  # aside, is handled within that chat (TUI.Chats.within/3).
  def handle_event(event, state) do
    # Navigation is handled before approval ownership routes keys to another
    # chat. Otherwise switching while answering a parked chat could swap the
    # wrong transcript or draft back onto the screen.
    result =
      case tab_action(event, state) do
        nil -> Chats.within(state, Chats.asker(state, event), &on_event(event, &1))
        action -> {:noreply, navigate_tabs(state, action)}
      end

    result
    |> RemoteChat.sync()
    |> next_question()
    |> Chats.relabeled()
    |> saved(state)
  end

  defp tab_action(%Event.Key{kind: "release"}, _state), do: nil

  defp tab_action(%Event.Key{code: code, modifiers: []}, _state)
       when code in ~w(f1 f2 f3 f4 f5),
       do:
         {:section,
          Enum.at(
            [:chat, :wallet, :search, :tokens, :remote],
            String.to_integer(String.trim_leading(code, "f")) - 1
          )}

  defp tab_action(%Event.Key{code: "o", modifiers: ["ctrl"]}, %{section: :chat}), do: :next
  defp tab_action(%Event.Key{code: "left", modifiers: ["alt"]}, %{section: :chat}), do: :previous
  defp tab_action(%Event.Key{code: "right", modifiers: ["alt"]}, %{section: :chat}), do: :next

  defp tab_action(%Event.Key{code: code, modifiers: ["alt"]}, %{section: :chat})
       when code in ~w(1 2 3 4 5 6 7 8 9),
       do: {:position, String.to_integer(code)}

  defp tab_action(%Event.Mouse{kind: "down", button: "left", x: x, y: y}, state),
    do: MainTabs.hit(state, x, y) || TabBar.hit(state, x, y)

  defp tab_action(_event, _state), do: nil

  defp navigate_tabs(state, action) do
    if tab_navigation_blocked?(state) do
      state
    else
      case action do
        {:section, section} -> Workspace.select(state, section)
        :new -> Chats.create(state)
        :previous -> Chats.previous(state)
        :next -> Chats.next(state)
        {:chat, id} -> Chats.switch(state, id)
        {:position, n} -> Chats.select(state, n)
      end
    end
  end

  # Approval questions retain their owner and may stay up across tab changes.
  # Other overlays describe the active chat or hold secret-entry state, so
  # navigation waits until those are closed. Reserved navigation keys never
  # become password/card characters or approval answers.
  defp tab_navigation_blocked?(state) do
    Enum.any?(
      [
        :account_flow,
        :card_flow,
        :recovery,
        :confirm_undo,
        :pending_commands,
        :pending_plan,
        :token_dash
      ],
      &(Map.get(state, &1) != nil)
    ) or state.pending_edits != []
  end

  @impl true
  def handle_info(msg, state) do
    state
    |> Chats.within(Chats.owner(state, msg), &on_info(msg, &1))
    |> RemoteChat.sync()
    |> next_question()
    |> Chats.relabeled()
    |> saved(state)
  end

  # Once a question is answered, the next one waiting takes its place.
  defp next_question({:noreply, state} = result) when is_map(state),
    do: put_elem(result, 1, Chats.promote(state, &promote/1))

  defp next_question({:noreply, state, _opts} = result),
    do: put_elem(result, 1, Chats.promote(state, &promote/1))

  defp next_question(result), do: result

  defp promote(%{waiting: [{field, ask} | rest]} = state) do
    if asked?(state),
      do: state,
      else: %{Map.put(state, field, ask) | waiting: rest, status: "waiting for your answer…"}
  end

  defp promote(state), do: state

  defp asked?(state),
    do: state.asking != nil or state.tool_ask != nil or state.purchase_ask != nil

  # Questions remember which run asked them, so cancelling a run refuses only
  # its own (TUI.Run.cancel/1).
  defp asked_by({kind, ask}, id) when kind in [:ask_remote, :tool_approval, :purchase_approval],
    do: {kind, Map.put(ask, :run, id)}

  # A sub-agent's questions too (TinyAxe.Agent.Dispatch).
  defp asked_by({:subagent, sub, event}, id), do: {:subagent, sub, asked_by(event, id)}
  defp asked_by(event, _id), do: event

  # A question is shown now, or waits its turn behind the one on screen.
  defp offer(state, field, ask) do
    if asked?(state),
      do: %{state | waiting: state.waiting ++ [{field, ask}]},
      else: %{Map.put(state, field, ask) | status: "waiting for your answer…"}
  end

  defp saved(result, before) do
    now = elem(result, 1)
    now = if elem(result, 0) == :noreply, do: Welcome.sync(now), else: now
    if now.session?, do: Chats.persist(now, before)
    put_elem(result, 1, now)
  end

  defp on_event(%Event.Key{kind: "release"}, state), do: {:noreply, state}

  defp on_event(%Event.Key{code: "c", modifiers: ["ctrl"]}, state) do
    if state.card_flow, do: TinyAxe.Cards.discard_entry()
    if state.account_flow, do: TinyAxe.Account.discard_entry()
    {:stop, state |> Chats.cancel_all() |> Run.cancel()}
  end

  # The account: every key goes to the flow (and the password to TinyAxe.Account).
  defp on_event(%Event.Key{code: code}, %{account_flow: flow} = state) when flow != nil,
    do: {:noreply, account_step(state, TinyAxe.TUI.AccountFlow.key(flow, code))}

  defp on_event(%Event.Paste{content: content}, %{account_flow: flow} = state) when flow != nil,
    do: {:noreply, %{state | account_flow: TinyAxe.TUI.AccountFlow.paste(flow, content)}}

  # /credit-card: every key goes to the flow (and its secrets to the vault).
  defp on_event(%Event.Key{code: code}, %{card_flow: flow} = state) when flow != nil do
    case TinyAxe.TUI.CardFlow.key(flow, code) do
      {:cont, flow} ->
        {:noreply, %{state | card_flow: flow}}

      {:done, message} ->
        {:noreply, card_notice(%{state | card_flow: nil, status: "ready"}, message)}

      {:cancel, message} ->
        {:noreply, card_notice(%{state | card_flow: nil, status: "ready"}, message)}
    end
  end

  defp on_event(%Event.Paste{content: content}, %{card_flow: flow} = state) when flow != nil,
    do: {:noreply, %{state | card_flow: TinyAxe.TUI.CardFlow.paste(flow, content)}}

  # Popups own their input even when the feature page below has buttons.
  defp on_event(%kind{}, state)
       when kind in [Event.Mouse, Event.Paste] and
              (state.asking != nil or state.purchase_ask != nil or state.tool_ask != nil),
       do: {:noreply, state}

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

  # While an edit is on screen, keys answer it instead of going to the prompt.
  defp on_event(%Event.Key{code: code}, %{pending_edits: [edit | _]} = state) do
    {:noreply, FileWorkflow.edit_key(code, edit, state)}
  end

  # /token: esc closes it; other keys wait until it's closed.
  defp on_event(%Event.Key{code: code}, %{token_dash: dash} = state) when dash != nil do
    if TinyAxe.TUI.TokenDash.close?(code),
      do: {:noreply, %{state | token_dash: nil}},
      else: {:noreply, state, render?: false}
  end

  defp on_event(%Event.Resize{width: w, height: h}, state),
    do: {:noreply, %{state | size: {w, h}}}

  defp on_event(event, %{section: section} = state) when section in [:wallet, :tokens, :remote] do
    if tab_navigation_blocked?(state) do
      {:noreply, state}
    else
      case FeaturePanels.event(event, state) do
        {:open_chat, id, state} -> {:noreply, Workspace.open_chat(state, id)}
        result -> result
      end
    end
  end

  defp on_event(event, %{section: :search} = state) do
    if tab_navigation_blocked?(state),
      do: {:noreply, state},
      else: SearchWorkspace.event(event, state) || conversation_event(event, state)
  end

  defp on_event(event, state), do: conversation_event(event, state)

  defp card_notice(%{section: :wallet} = state, message),
    do: state |> FeaturePanels.enter(:wallet) |> FeaturePanels.notice(:wallet, message)

  defp card_notice(state, message), do: add_meta(state, message)

  defp conversation_event(
         %Event.Key{code: "z", modifiers: ["ctrl"]},
         %{run: nil, ops_job: nil} = state
       ),
       do: FileWorkflow.request_undo(state)

  defp conversation_event(%Event.Key{code: "esc"}, %{run: run} = state) when run != nil do
    {:noreply, %{Run.cancel(state) | status: "cancelled"}}
  end

  defp conversation_event(%Event.Key{code: "l", modifiers: ["ctrl"]}, %{run: nil} = state) do
    # The transcript's measured heights go with it.
    Transcript.clear_cache()

    {:noreply,
     %{
       state
       | history: [],
         transcript: [],
         summary: nil,
         # A cleared chat starts afresh in the history too.
         saved_as: TinyAxe.History.new_id(),
         pending_edits: [],
         scroll: :bottom,
         status: "cleared"
     }}
  end

  # Chat commands work while this chat is busy too: that's when they're wanted.
  defp conversation_event(%Event.Key{code: "enter", modifiers: []}, state) do
    Chats.submit(state) || memory_submit(state) || ChatHistory.submit(state) || submit(state)
  end

  defp conversation_event(%Event.Key{code: "enter"}, state) do
    ExRatatui.textarea_handle_key(state.input, "enter", [])
    {:noreply, state}
  end

  defp conversation_event(%Event.Key{code: "k", modifiers: ["ctrl"]}, %{run: nil} = state),
    do: {:noreply, CompactionWorkflow.start(state)}

  defp conversation_event(%Event.Key{code: "t", modifiers: ["ctrl"]}, state) do
    {w, _h} = state.size
    {:noreply, %{state | sidebar: not View.sidebar?(state, w)}}
  end

  defp conversation_event(%Event.Key{code: "y", modifiers: ["ctrl"]}, state),
    do: {:noreply, copy(state)}

  defp conversation_event(%Event.Key{code: "page_up"}, state),
    do: {:noreply, View.scroll_by(state, -page(state))}

  defp conversation_event(%Event.Key{code: "page_down"}, state),
    do: {:noreply, View.scroll_by(state, page(state))}

  # With an empty prompt, arrows, home and end scroll the transcript. Terminals
  # also turn the mouse wheel into arrow keys, so this makes the wheel scroll.
  defp conversation_event(%Event.Key{code: code, modifiers: []} = key, state)
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

  defp conversation_event(%Event.Key{code: code, modifiers: mods}, state) do
    ExRatatui.textarea_handle_key(state.input, code, mods)
    {:noreply, state}
  end

  defp conversation_event(%Event.Paste{content: content}, state) do
    ExRatatui.textarea_insert_str(state.input, content)
    {:noreply, state}
  end

  defp conversation_event(%Event.Resize{width: w, height: h}, state) do
    {:noreply, %{state | size: {w, h}}}
  end

  # With mouse capture enabled terminals report wheel events directly rather
  # than translating them to arrows. Scroll even while a draft is being typed.
  defp conversation_event(%Event.Mouse{kind: kind}, state)
       when kind in ["scroll_up", "scroll_down"] do
    if tab_navigation_blocked?(state) do
      {:noreply, state}
    else
      {:noreply, View.scroll_by(state, if(kind == "scroll_up", do: -3, else: 3))}
    end
  end

  defp conversation_event(_event, state), do: {:noreply, state}

  defp memory_submit(state) do
    case MemoryChat.submit(state) do
      {:noreply, opened} -> {:noreply, Workspace.adopt_search(opened, state)}
      nil -> nil
    end
  end

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

      state.local_only and String.starts_with?(prompt, "/") ->
        ExRatatui.textarea_set_value(state.input, "")

        {:noreply,
         add_meta(
           state,
           "This is a local memory conversation. Use /memory or /new for ordinary app commands."
         )}

      state.local_only ->
        ExRatatui.textarea_set_value(state.input, "")
        {:noreply, MemoryChat.ask(state, prompt)}

      # cd, pwd, tools, /site, /remote, /account, /token, /look and /credit-card
      # are handled here, like shell built-ins: no model involved.
      prompt in ["pwd", "tools", "/account", "/token", "/site", "/look", "/look undo"] or
        prompt =~ ~r/\Acd(\s|\z)/ or
        prompt =~ ~r/\A\/remote(\s|\z)/ or String.starts_with?(prompt, "/credit-card") ->
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

  # The chats on the site (TinyAxe.Site): the link, shown and copied; and the
  # page opened in the user's browser, signed in, when there's a desktop to
  # open it on. Asking the site can take a moment, so it runs aside.
  defp builtin(state, "/site") do
    tui = self()
    copy = state.clipboard

    Task.Supervisor.start_child(TinyAxe.TaskSupervisor, fn ->
      send(tui, {:site, site(copy)})
    end)

    %{state | status: "asking the site…"}
  end

  defp builtin(state, "/account") do
    case TinyAxe.Account.current() do
      %{username: name, site: site} ->
        add_meta(state, "Your account is #{name} on #{site}.")

      nil ->
        %{state | account_flow: TinyAxe.TUI.AccountFlow.new(), status: "setting up your account…"}
    end
  end

  defp builtin(state, "/remote" <> rest), do: RemoteChat.command(state, String.trim(rest))

  defp builtin(state, "/token"), do: %{state | token_dash: TinyAxe.TUI.TokenDash.open()}

  # Reading every setting runs a few dozen small programs, and undo runs
  # some too, so both run aside.
  defp builtin(state, "/look" <> rest) do
    tui = self()

    work =
      if String.trim(rest) == "undo",
        do: &TinyAxe.Desktop.undo/0,
        else: fn -> "🎨 " <> TinyAxe.Desktop.describe_current() end

    Task.Supervisor.start_child(TinyAxe.TaskSupervisor, fn -> send(tui, {:look, work.()}) end)
    %{state | status: "reading the desktop's settings…"}
  end

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

  defp site(copy) do
    with {:ok, url} <- TinyAxe.Site.open() do
      {:opened, url, copy.(url) == :ok, TinyAxe.Site.open_in_browser()}
    end
  end

  ## Pipeline events

  defp on_info({:pipeline, id, {:memory_result, result}}, %{run: {id, _pid}} = state),
    do: {:noreply, MemoryChat.event(state, result)}

  defp on_info({:pipeline, id, event}, %{run: {id, _pid}} = state) do
    {:noreply, apply_event(asked_by(event, id), state)}
  end

  defp on_info({:pipeline, _stale_id, _event}, state), do: {:noreply, state, render?: false}

  defp on_info({:account_flow, ref, answer}, %{account_job: ref, account_flow: flow} = state)
       when flow != nil,
       do:
         {:noreply,
          account_step(%{state | account_job: nil}, TinyAxe.TUI.AccountFlow.result(flow, answer))}

  defp on_info({:account_flow, _stale, _answer}, state), do: {:noreply, state, render?: false}

  # The URL gets a line of its own, as code so Markdown leaves it as it is, for
  # the terminal to make clickable (the transcript can't hold OSC 8 links).
  defp on_info({:site, {:opened, url, copied?, browser}}, state) do
    copied = if copied?, do: "; the link is copied", else: ""

    shown =
      case browser do
        {:ok, _} ->
          who = with %{username: name} <- TinyAxe.Account.current(), do: " as #{name}"

          "💬 opened your chats on tiny-axe's website in your browser, signed in#{who || ""}#{copied}:"

        {:error, why} ->
          "💬 your chats, on your page of tiny-axe's website (sign in to see them; " <>
            "couldn't open your browser: #{why})#{copied}:"
      end

    state =
      state
      |> add_meta(shown)
      |> add_meta("`#{url}`")

    {:noreply, %{state | status: "ready"}}
  end

  defp on_info({:site, {:error, message}}, state),
    do: {:noreply, %{add_meta(state, "✗ site: #{message}") | status: "ready"}}

  defp on_info({:look, text}, state),
    do: {:noreply, %{add_meta(state, text) | status: "ready"}}

  defp on_info({:token_dash, ref}, %{token_dash: dash} = state) when dash != nil,
    do: {:noreply, %{state | token_dash: TinyAxe.TUI.TokenDash.refresh(dash, ref)}}

  defp on_info({:token_dash, ref}, %{section: :tokens} = state),
    do: {:noreply, FeaturePanels.refresh_tokens(state, ref)}

  defp on_info({:token_dash, _closed}, state), do: {:noreply, state, render?: false}

  # The site's /remote page (TinyAxe.Remote).
  defp on_info({:remote, event}, state), do: {:noreply, RemoteChat.event(state, event)}

  defp on_info(:tick, %{run: nil} = state), do: {:noreply, state, render?: false}

  defp on_info({:timeout, ref, :welcome}, %{welcome: %{timer: ref}} = state)
       when is_reference(ref) do
    {:noreply, Welcome.step(state)}
  end

  defp on_info(:pulse, state) do
    Pulse.schedule()

    if state.run == nil,
      do: {:noreply, Pulse.step(state)},
      else: {:noreply, state, render?: false}
  end

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
              :desktop_plan,
              :desktop_problems,
              :desktop_done,
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

  defp apply_event({:ask_remote, ask}, state), do: offer(state, :asking, ask)

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
    offer(state, :purchase_ask, ask)
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

  defp apply_event({:tool_approval, ask}, state), do: offer(state, :tool_ask, ask)

  defp apply_event({:tool_call, %{tool: tool, class: class, args: args} = call}, state) do
    shown = if args == %{}, do: "", else: " " <> String.slice(JSON.encode!(args), 0, 120)
    why = if call[:reason], do: ": #{call.reason}", else: ""
    add_meta(state, "🔧 #{tool}#{shown} (#{describe_class(class)}#{why})")
  end

  # Results that went through need no line of their own; the answer uses them.
  defp apply_event({:tool_result, %{decision: d, tool: tool, summary: why}}, state)
       when d in [:refused, :denied, :failed],
       do: add_meta(state, "✗ #{tool}: #{why}")

  defp apply_event({:tool_result, %{decision: :advised, tool: tool}}, state),
    do:
      add_meta(state, "↺ #{tool}: held once, tiny-axe's candidate check suggests another element")

  defp apply_event({:tool_result, _}, state), do: state

  defp apply_event({:tool_limit, %{reason: why}}, state),
    do: add_meta(state, "⚠ the agent was stopped: #{why}")

  # What a browser action came to (TinyAxe.Browser.Outcomes): short lines,
  # confirmed or not; the reason codes say why.
  defp apply_event({:outcome, %{status: :succeeded, action: action}}, state),
    do: add_meta(state, "✓ confirmed: #{action}")

  defp apply_event({:outcome, %{status: :unresolved, action: action, codes: codes}}, state),
    do: add_meta(state, "? not confirmed: #{action} (#{outcome_codes(codes)})")

  defp apply_event({:outcome, %{status: :failed, action: action, codes: codes}}, state),
    do: add_meta(state, "✗ didn't take effect: #{action} (#{outcome_codes(codes)})")

  defp apply_event({:outcome, _}, state), do: state

  defp apply_event({:completion, %{outcome: :replaced}}, state),
    do: add_meta(state, "⚠ tiny-axe held back the agent's reply: what it checked contradicts it")

  defp apply_event({:completion, %{outcome: :caveated, unresolved: u, failed: f}}, state),
    do:
      add_meta(
        state,
        "⚠ tiny-axe marked #{length(u) + length(f)} action(s) in the reply as not confirmed"
      )

  defp apply_event({:completion, _}, state), do: state

  ## Sub-agents (TinyAxe.Agent.Dispatch): their lines, marked; their questions
  ## join the queue saying who asks; their text and answers stay out of the reply.

  defp apply_event({:subagent, %{n: n} = sub, event}, state), do: subagent(event, n, sub, state)

  defp apply_event({:review, _}, state), do: state
  # Appearance changes the request named outright weren't reviewed.
  defp apply_event({:review_skipped, _}, state), do: state
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

  defp subagent(:started, n, sub, state),
    do: add_meta(state, "🤖 agent #{n} started: #{String.slice(sub.objective, 0, 120)}")

  defp subagent({:finished, outcome}, n, _sub, state),
    do: add_meta(state, "agent #{n} finished (#{String.replace(to_string(outcome), "_", " ")})")

  defp subagent({kind, ask}, n, _sub, state)
       when kind in [:ask_remote, :tool_approval, :purchase_approval],
       do: apply_event({kind, Map.put(ask, :from, "agent #{n}")}, state)

  defp subagent({kind, _} = event, n, _sub, state)
       when kind in [
              :tool_call,
              :tool_result,
              :tool_limit,
              :outcome,
              :completion,
              :purchase_refused
            ] do
    shown = apply_event(event, state)
    {before, added} = Enum.split(shown.transcript, length(state.transcript))

    marked =
      Enum.map(added, fn
        {:meta, line} -> {:meta, "agent #{n} · " <> line}
        e -> e
      end)

    %{shown | transcript: before ++ marked}
  end

  defp subagent(_event, _n, _sub, state), do: state

  defp outcome_codes(codes), do: codes |> List.delete("outcome_unresolved") |> Enum.join(", ")

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

  ## The account (TinyAxe.TUI.AccountFlow)

  defp first_account_flow(opts) do
    cond do
      Keyword.has_key?(opts, :account_flow) ->
        opts[:account_flow]

      opts[:test_mode] != nil ->
        nil

      TinyAxe.Account.required?() and TinyAxe.Account.current() == nil ->
        TinyAxe.TUI.AccountFlow.new()

      true ->
        nil
    end
  end

  defp account_step(state, {:cont, flow}), do: %{state | account_flow: flow}

  # A job (the model's suggestions, the site) runs in a task; its answer comes
  # back as {:account_flow, ref, answer}.
  defp account_step(state, {:run, flow, job}) do
    tui = self()
    ref = make_ref()

    Task.Supervisor.start_child(TinyAxe.TaskSupervisor, fn ->
      answer =
        try do
          TinyAxe.TUI.AccountFlow.perform(job)
        rescue
          e -> {:error, Exception.message(e)}
        end

      send(tui, {:account_flow, ref, answer})
    end)

    %{state | account_flow: flow, account_job: ref, status: flow.busy || "working…"}
  end

  # A new account: connect to the site and send it everything so far.
  defp account_step(state, {:done, message}) do
    Task.start(fn -> if TinyAxe.Site.available?(), do: TinyAxe.Site.start() end)
    TinyAxe.Sync.soon()
    %{state | account_flow: nil, account_job: nil, status: "ready"} |> add_meta(message)
  end

  defp account_step(state, {:cancel, message}) do
    TinyAxe.Account.discard_entry()
    %{state | account_flow: nil, account_job: nil, status: "ready"} |> add_meta(message)
  end
end
