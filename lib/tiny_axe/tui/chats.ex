defmodule TinyAxe.TUI.Chats do
  @moduledoc """
  Several chats in one TUI: `/new` starts another, `/chats` lists them,
  `/chat N` (or `ctrl+o`) switches, `/chat close` closes an idle one.

  Each chat is also kept in the history (`TinyAxe.History`) under its own id,
  `saved_as`, from which `/history` (`TinyAxe.TUI.ChatHistory`) can reopen it.

  The chat on screen keeps its fields in the TUI state, as with a single
  chat; the others are parked in `state.chats` (see `blank/0` for which fields
  belong to a chat), including its unsent prompt and cursor. Everything else
  is shared: the screen size,
  the sidebar, questions to the user (`asking`, `tool_ask`, `purchase_ask`,
  `waiting`), `/credit-card`, remote mode, the recovery and undo popups.

  A chat put aside keeps running. A message for it (its run's events, its
  run's exit, its file plan's results) is handled by swapping it in, handling
  the message as usual, and swapping it back out (`within/3`), so the chat on
  screen is left as it was. Questions remember the chat that asked them
  (`:chat`), and say so when it isn't the one on screen.
  """

  alias ExRatatui.Event
  alias TinyAxe.TUI.{Run, Transcript}
  import TinyAxe.TUI.Conversation, only: [add_meta: 2]

  # One chat's own fields, as a new chat has them. The conversation (history,
  # transcript, summary, compacting), its run and what it's doing (streaming,
  # status, commands, file plans and edits waiting for y/n), and where it's
  # scrolled to. And its id in the history (TinyAxe.History), given when
  # it starts.
  @blank %{
    # Textarea resources stay in memory only; session/history saving below
    # selects conversation fields explicitly and never serializes drafts.
    input: nil,
    saved_as: nil,
    local_only: false,
    memory_results: nil,
    history: [],
    transcript: [],
    summary: nil,
    compacting: nil,
    streaming: nil,
    pending_prompt: nil,
    attempt_meta_from: 0,
    run: nil,
    agent_run: false,
    status: "ready",
    pending_edits: [],
    accepted_edits: [],
    edit_scroll: 0,
    pending_plan: nil,
    pending_commands: nil,
    running_cmd: nil,
    plan_scroll: 0,
    ops_job: nil,
    ops_monitor: nil,
    scroll: :bottom,
    usage: nil,
    copy_back: 0,
    # The chat the site's /remote page talks to (TinyAxe.TUI.RemoteChat).
    remote_chat: false
  }

  @fields Map.keys(@blank)

  @asks [:asking, :tool_ask, :purchase_ask]

  def blank, do: @blank

  @doc "One chat, the one on screen."
  def new, do: %{order: [1], active: 1, next: 2, parked: %{}, caches: %{}}

  @doc "The chats saved by TinyAxe.Session; the active one's fields are already in the state."
  def restore(%{chats: [_, _ | _] = saved, active: active}) do
    ids = Enum.to_list(1..length(saved))
    active = min(active, length(saved) - 1) + 1

    parked =
      for {chat, id} <- Enum.zip(saved, ids), id != active, into: %{} do
        chat = Map.take(chat, [:history, :transcript, :summary, :saved_as, :local_only])
        {id, fresh(chat) |> Map.update!(:saved_as, &(&1 || TinyAxe.History.new_id()))}
      end

    %{order: ids, active: active, next: length(saved) + 1, parked: parked, caches: %{}}
  end

  def restore(_saved), do: new()

  def count(state), do: length(state.chats.order)

  ## Handling a message in the chat it belongs to

  @doc """
  Runs `fun` (a message handler) with chat `id` on screen, then puts it back
  aside. nil, or the active chat, runs it as is. Questions that appear are
  marked as that chat's.
  """
  def within(state, nil, fun), do: fun.(state) |> claimed()

  def within(%{chats: chats} = state, id, fun) do
    case chats.parked do
      %{^id => chat} ->
        front = Map.take(state, @fields)
        inner = state |> Map.merge(chat) |> Map.put(:chats, %{chats | active: id})
        result = fun.(inner) |> claimed()
        inner = state_of(result)
        back = Map.take(inner, @fields)
        parked = Map.put(inner.chats.parked, id, back)

        out =
          inner
          |> Map.merge(front)
          |> Map.put(:chats, %{inner.chats | active: chats.active, parked: parked})
          |> note_finished(id, chat, back)

        put_state(result, out)

      _ ->
        within(state, nil, fun)
    end
  end

  @doc "The parked chat a message belongs to, if it isn't the active one's."
  def owner(state, msg) do
    if owns?(state, msg),
      do: nil,
      else: Enum.find_value(state.chats.parked, fn {id, chat} -> owns?(chat, msg) && id end)
  end

  defp owns?(%{run: {id, _}}, {:pipeline, id, _event}), do: true
  defp owns?(%{run: {_, pid}}, {:DOWN, _ref, :process, pid, _reason}), do: true
  defp owns?(%{ops_monitor: ref}, {:DOWN, ref, :process, _, _}) when ref != nil, do: true
  defp owns?(%{ops_job: id}, {:ops, id, _event}) when id != nil, do: true
  defp owns?(_chat, _msg), do: false

  @doc "The chat whose question a key answers, when it's on screen and asked by another chat."
  def asker(%{card_flow: nil, account_flow: nil, pin_flow: nil} = state, %Event.Key{
        kind: kind,
        code: code,
        modifiers: mods
      })
      when kind != "release" do
    ask = state.asking || state.purchase_ask || state.tool_ask

    if ask == nil or (mods == ["ctrl"] and code in ["c", "o"]),
      do: nil,
      else: ask[:chat]
  end

  def asker(_state, _event), do: nil

  @doc "Brings up the next waiting question within the chat that asked it."
  def promote(%{waiting: [{_field, ask} | _]} = state, fun), do: within(state, ask[:chat], fun)
  def promote(state, fun), do: fun.(state)

  # New questions are marked as the active chat's; `asker` keeps who asked
  # within it (e.g. an agent), since `from` is rewritten by `relabeled/1`.
  defp claimed(result) do
    id = state_of(result).chats.active
    each_ask(result, &claim(&1, id))
  end

  defp claim(ask, id) when is_map(ask) and not is_map_key(ask, :chat),
    do: Map.merge(ask, %{chat: id, asker: ask[:from]})

  defp claim(ask, _id), do: ask

  @doc "Says which chat asked each question, when it isn't the one on screen."
  def relabeled(result), do: each_ask(result, &label(&1, state_of(result)))

  # Every question, on screen or waiting, through `fun`.
  defp each_ask(result, fun) do
    state = state_of(result)

    if asked?(state) do
      asks = for field <- @asks, ask = Map.fetch!(state, field), into: %{}, do: {field, fun.(ask)}
      waiting = for {field, ask} <- state.waiting, do: {field, fun.(ask)}
      put_state(result, Map.merge(%{state | waiting: waiting}, asks))
    else
      result
    end
  end

  defp asked?(state), do: state.waiting != [] or Enum.any?(@asks, &Map.fetch!(state, &1))

  defp label(%{chat: id} = ask, state) do
    chat =
      cond do
        id == state.chats.active -> nil
        id in state.chats.order -> "chat #{position(state, id)}"
        true -> "a closed chat"
      end

    from = [chat, ask[:asker]] |> Enum.filter(& &1) |> Enum.join(" · ")
    from = if from == "", do: nil, else: from
    if ask[:from] == from, do: ask, else: Map.put(ask, :from, from)
  end

  defp label(ask, _state), do: ask

  # Said in the active chat's status, if it's idle, when a chat put aside is done.
  defp note_finished(state, id, before, now) do
    if busy?(before) and not busy?(now) and state.run == nil do
      n = position(state, id)

      what =
        cond do
          activity(state, id) == "waiting for you" -> "is waiting for you"
          now.status == "error" -> "stopped with an error"
          true -> "finished"
        end

      %{state | status: "chat #{n} #{what} · /chat #{n} shows it"}
    else
      state
    end
  end

  defp busy?(chat), do: chat.run != nil or chat.ops_job != nil

  ## Commands

  @doc "Handles a chat command typed at the prompt; nil for anything else."
  def submit(state) do
    prompt = state.input |> ExRatatui.textarea_get_value() |> String.trim()

    if prompt in ["/new", "/chats"] or prompt =~ ~r/\A\/chat(\s|\z)/ do
      ExRatatui.textarea_set_value(state.input, "")
      {:noreply, command(state, prompt)}
    end
  end

  defp command(state, "/new"), do: create(state)
  defp command(state, "/chats"), do: list(state)

  defp command(state, "/chat" <> rest) do
    arg = String.trim(rest)

    case Integer.parse(arg) do
      {n, ""} -> select(state, n)
      _ when arg == "close" -> close(state)
      _ -> add_meta(state, "/new · /chats · /chat N · /chat close · ctrl+o next chat")
    end
  end

  @doc "Starts an empty chat and shows it; the one left keeps running."
  def create(state) do
    working = for id <- state.chats.order, busy?(chat(state, id)), do: position(state, id)
    state = open(state, %{})
    add_meta(state, "new chat #{count(state)}#{still_working(working)}")
  end

  @doc """
  Shows a chat from the history (`TinyAxe.History.load/1`): in the chat on
  screen if nothing's been asked there yet, else as a new chat.
  """
  def reopen(state, kept) do
    fields = Map.take(kept, [:saved_as, :history, :transcript, :summary, :local_only])

    if busy?(state) or Enum.any?(state.transcript, &match?({:user, _}, &1)) do
      open(state, fields)
    else
      Transcript.clear_cache()
      Map.merge(state, fresh(fields))
    end
  end

  # A chat after the others, on screen, with `fields` (a new id if none).
  defp open(state, fields) do
    id = state.chats.next
    %{chats: chats} = state = park(state)
    chats = %{chats | order: chats.order ++ [id], next: id + 1, active: id}

    state
    |> Map.merge(fresh())
    |> Map.put(:saved_as, TinyAxe.History.new_id())
    |> Map.merge(fields)
    |> Map.put(:chats, chats)
  end

  @doc """
  A chat after the others, put aside (the one on screen stays), with
  `fields`. Returns it with the new chat's id.
  """
  def open_aside(state, fields) do
    id = state.chats.next
    chat = fresh(fields) |> Map.update!(:saved_as, &(&1 || TinyAxe.History.new_id()))

    chats = %{
      state.chats
      | order: state.chats.order ++ [id],
        next: id + 1,
        parked: Map.put(state.chats.parked, id, chat)
    }

    {%{state | chats: chats}, id}
  end

  @doc "The open chat kept in the history as `saved_as`, if any."
  def kept_as(state, saved_as),
    do: Enum.find(state.chats.order, &(chat(state, &1).saved_as == saved_as))

  defp still_working([]), do: ""
  defp still_working([n]), do: " — chat #{n} is still working"
  defp still_working(ns), do: " — chats #{Enum.join(ns, ", ")} are still working"

  defp list(state) do
    state =
      if Enum.any?(state.chats.order, &chat(state, &1).local_only),
        do: TinyAxe.TUI.MemoryChat.ensure_local(state),
        else: state

    Enum.reduce(state.chats.order, state, fn id, acc ->
      here = if id == state.chats.active, do: " ◂ this one", else: ""
      n = position(state, id)
      add_meta(acc, "chat #{n} · #{title(state, id, 40)} · #{activity(state, id)}#{here}")
    end)
  end

  @doc "Shows the next chat, after the last the first."
  def next(state) do
    case count(state) do
      1 ->
        %{state | status: "this is the only chat · /new starts another"}

      n ->
        select(state, rem(position(state, state.chats.active), n) + 1)
    end
  end

  @doc "Shows the previous chat, before the first the last."
  def previous(state) do
    case count(state) do
      1 -> %{state | status: "this is the only chat · /new starts another"}
      n -> select(state, Integer.mod(position(state, state.chats.active) - 2, n) + 1)
    end
  end

  @doc "Shows a chat by its one-based position in the tab bar."
  def select(state, n) do
    case Enum.at(state.chats.order, n - 1) do
      id when n >= 1 and id != nil -> switch(state, id)
      _ -> add_meta(state, "no chat #{n} (/chats lists them)")
    end
  end

  @doc "Shows chat `id`, putting the active one aside."
  def switch(%{chats: %{active: id}} = state, id), do: state

  def switch(state, id) do
    if Map.has_key?(state.chats.parked, id) do
      was_running? = state.run != nil
      state = state |> park() |> unpark(id)
      # The throbber's tick runs only while the chat on screen is working.
      if state.run != nil and not was_running?, do: Run.schedule_tick()
      state
    else
      state
    end
  end

  defp fresh(fields \\ %{}),
    do: @blank |> Map.put(:input, ExRatatui.textarea_new()) |> Map.merge(fields)

  # Closing a working chat would lose its request, so that has to be cancelled first.
  defp close(state) do
    n = position(state, state.chats.active)

    cond do
      count(state) == 1 ->
        add_meta(state, "this is the only chat (ctrl+l clears it)")

      busy?(state) ->
        add_meta(state, "chat #{n} is still working: esc cancels it, then /chat close")

      true ->
        %{order: order, active: active} = state.chats
        index = Enum.find_index(order, &(&1 == active))
        order = List.delete(order, active)
        next = Enum.at(order, min(index, length(order) - 1))
        chats = %{state.chats | order: order, caches: Map.delete(state.chats.caches, active)}
        state = %{state | chats: chats} |> unpark(next)
        %{state | status: "closed chat #{n}; this is chat #{position(state, next)}"}
    end
  end

  defp park(state) do
    %{active: id} = chats = state.chats
    cache = Transcript.take_cache()

    %{
      state
      | chats: %{
          chats
          | parked: Map.put(chats.parked, id, Map.take(state, @fields)),
            caches: Map.put(chats.caches, id, cache)
        }
    }
  end

  defp unpark(state, id) do
    chats = state.chats
    Transcript.put_cache(chats.caches[id])

    state
    |> Map.merge(chats.parked[id])
    |> Map.put(:chats, %{
      chats
      | active: id,
        parked: Map.delete(chats.parked, id),
        caches: Map.delete(chats.caches, id)
    })
  end

  ## What each chat is doing

  def position(state, id), do: Enum.find_index(state.chats.order, &(&1 == id)) + 1

  @doc "Chat `id`'s own fields (see `blank/0`), wherever it is; nil if it's closed."
  def get(state, id), do: chat(state, id)

  defp chat(state, id),
    do: if(id == state.chats.active, do: Map.take(state, @fields), else: state.chats.parked[id])

  @doc "\"working\", \"waiting for you\" or \"idle\"."
  def activity(state, id) do
    chat = chat(state, id)
    asks = for(f <- @asks, ask = Map.fetch!(state, f), do: ask) ++ Keyword.values(state.waiting)

    cond do
      Enum.any?(asks, &(&1[:chat] == id)) or chat.pending_edits != [] or
        chat.pending_plan != nil or chat.pending_commands != nil ->
        "waiting for you"

      busy?(chat) ->
        "working"

      true ->
        "idle"
    end
  end

  @doc "A chat's name: the start of its first prompt (🌐 for the site's /remote chat)."
  def title(state, id, max) do
    %{transcript: transcript, remote_chat: remote?} = chat(state, id)
    local? = chat(state, id).local_only

    prefix =
      cond do
        local? -> "🔒 "
        remote? -> "🌐 "
        true -> ""
      end

    prefix <> name(transcript, if(prefix == "", do: max, else: max - 2))
  end

  defp name(transcript, max) do
    case Enum.find(transcript, &match?({:user, _}, &1)) do
      {:user, text} ->
        line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()
        if String.length(line) > max, do: String.slice(line, 0, max - 1) <> "…", else: line

      nil ->
        "(nothing asked yet)"
    end
  end

  @doc "For the status bar: which chat this is, and what the others are doing."
  def status_label(state) do
    case count(state) do
      1 ->
        ""

      n ->
        others =
          for id <- state.chats.order,
              id != state.chats.active,
              (what = activity(state, id)) != "idle",
              do: "chat #{position(state, id)} #{what}"

        Enum.join(["  ·  chat #{position(state, state.chats.active)} of #{n}" | others], " · ")
    end
  end

  @doc "For the sidebar: one line per chat."
  def lines(state) do
    for id <- state.chats.order do
      mark = if id == state.chats.active, do: "▸", else: " "
      "#{mark} #{position(state, id)} #{title(state, id, 22)} · #{activity(state, id)}"
    end
  end

  ## Quitting and saving

  @doc "Cancels every chat put aside (ctrl+c then cancels the one on screen)."
  def cancel_all(state) do
    Enum.reduce(Map.keys(state.chats.parked), state, &within(&2, &1, fn s -> Run.cancel(s) end))
  end

  @doc """
  Saves every chat to TinyAxe.Session, and those that changed to the
  history (TinyAxe.History), if any conversation changed.
  """
  def persist(now, before) do
    saved = conversations(now)
    previous = conversations(before)

    if saved != previous or now.chats.active != before.chats.active do
      TinyAxe.Session.save_chats(saved, position(now, now.chats.active) - 1)
    end

    if saved != previous, do: TinyAxe.History.save(saved -- previous)
  end

  defp conversations(state) do
    for id <- state.chats.order,
        do: Map.take(chat(state, id), [:saved_as, :history, :transcript, :summary, :local_only])
  end

  defp state_of(result) when is_tuple(result), do: elem(result, 1)
  defp state_of(state), do: state

  defp put_state(result, state) when is_tuple(result), do: put_elem(result, 1, state)
  defp put_state(_result, state), do: state
end
