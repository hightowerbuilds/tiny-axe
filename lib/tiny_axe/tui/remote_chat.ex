defmodule TinyAxe.TUI.RemoteChat do
  @moduledoc """
  The site's /remote page, in the TUI (`docs/plan-remote-chat.md`, R3).
  Messages from it (`TinyAxe.Remote`) are asked in a chat of their own, the
  🌐 chat, made when the first one comes and kept aside like any chat put
  aside: it works while you use another, `/chats` lists it, `/chat N` shows
  it, `esc` there cancels.

  One message at a time; the others queue. While one is worked on, what the
  chat is doing (its status line) and the reply so far go to the page as they
  change (at most every #{250} ms); once the chat is idle, its answer (with
  any commands' output, and what was refused) is saved as the reply.

  Nothing in the 🌐 chat waits for someone at the machine: until there are
  approvals on the page, anything that needs a yes is refused on the spot
  (commands, file plans and edits, tool calls, purchases, sending a request
  to Claude or Codex) and the reply says so. Commands that only look still
  run, as they do without asking anywhere.

  `/remote on|off` switches it (remembered for the next start), `/remote`
  says how it stands; the status bar shows 🌐 while it's on.
  """

  require Logger

  alias TinyAxe.TUI.{Chats, CommandWorkflow, FileWorkflow, Run}

  import TinyAxe.TUI.Conversation, only: [add_meta: 2]

  @flush_ms 250
  # Lines the reply repeats: what was refused because nobody's asked.
  @note "🔒 "
  @asks [:asking, :tool_ask, :purchase_ask]

  @doc """
  The TUI's remote link. `opts[:remote]` is where replies go: the
  `TinyAxe.Remote` server (the default), or a test's pid, which gets
  `{:remote_out, message}` instead.
  """
  def new(opts) do
    %{
      to: Keyword.get(opts, :remote, TinyAxe.Remote),
      phase: :off,
      error: nil,
      # The message being answered: %{id, chat, from, answers, sent, at, status}.
      current: nil,
      queue: []
    }
  end

  @doc "Starts hearing from the site (the real TUI, at mount)."
  def subscribe(state) do
    %{phase: phase, error: error} = TinyAxe.Remote.subscribe(state.remote_link.to)
    put_link(state, phase: phase, error: error)
  catch
    :exit, _ -> state
  end

  ## Messages from TinyAxe.Remote

  @doc "Handles `{:remote, event}`."
  def event(state, {:status, phase}) do
    link = state.remote_link
    state = put_link(state, phase: phase)

    cond do
      phase == :online and link.phase != :online ->
        %{state | status: "🌐 the site can reach this tiny-axe"}

      phase != :online and link.phase == :online ->
        %{state | status: "🌐 lost the site; trying again"}

      true ->
        state
    end
  end

  def event(state, {:message, msg}) do
    link = state.remote_link

    if link.current == nil and link.queue == [] and idle?(state),
      do: begin(state, msg),
      else: put_link(state, queue: queue(link, msg))
  end

  def event(state, _other), do: state

  defp queue(link, msg) do
    if Enum.any?(link.queue, &(&1.id == msg.id)) or link.current[:id] == msg.id,
      do: link.queue,
      else: link.queue ++ [msg]
  end

  ## After every event and message

  @doc """
  Keeps the 🌐 chat moving: refuses what it asks, sends the page what it's
  doing, saves the reply once it's done, starts the next message.
  """
  def sync({:noreply, state}), do: {:noreply, step(state)}

  def sync({:noreply, state, opts}) do
    case step(state) do
      ^state -> {:noreply, state, opts}
      # Something changed here: draw it.
      stepped -> {:noreply, stepped}
    end
  end

  def sync(result), do: result

  defp step(%{remote_link: %{current: nil, queue: []}} = state), do: state

  defp step(%{remote_link: %{current: nil, queue: [msg | rest]}} = state) do
    if idle?(state), do: begin(put_link(state, queue: rest), msg), else: state
  end

  defp step(%{remote_link: %{current: cur}} = state) do
    state = refuse(state, cur.chat)

    case Chats.get(state, cur.chat) do
      nil ->
        state |> finish(cur, "failed", "the chat was closed at the machine") |> step()

      chat ->
        if done?(chat), do: state |> answer(cur, chat) |> step(), else: live(state, cur, chat)
    end
  end

  # Free to take the next message: the 🌐 chat (if there is one) has no run,
  # not even its compaction, and no file plan going.
  defp idle?(state) do
    chat = (id = chat_id(state)) && Chats.get(state, id)
    chat == nil or (chat.run == nil and chat.ops_job == nil)
  end

  # The answer is in: nothing running for the request (a compaction may be
  # going on after it) and nothing left to say yes or no to.
  defp done?(chat),
    do:
      (chat.run == nil or chat.compacting != nil) and chat.ops_job == nil and
        chat.pending_prompt == nil and chat.pending_commands == nil and
        chat.pending_plan == nil and chat.pending_edits == []

  defp begin(state, msg) do
    {state, id} = ensure_chat(state)
    transcript = Chats.get(state, id).transcript
    from = length(transcript)
    # Answers go above the lines that judged them, so they're found by count.
    answers = Enum.count(transcript, &match?({:assistant, _}, &1))

    # A card number never reaches a model (as at the prompt).
    prompt = TinyAxe.Tools.Redact.text(msg.body)

    state =
      Chats.within(state, id, fn s ->
        s |> add_meta("🌐 from the site") |> Run.request(prompt)
      end)

    cur = %{id: msg.id, chat: id, from: from, answers: answers, sent: nil, at: nil, status: nil}
    put_link(state, current: cur)
  end

  defp ensure_chat(state) do
    case chat_id(state) do
      nil ->
        intro =
          "🌐 messages from #{TinyAxe.Account.site_url()}/remote are answered here. " <>
            "Anything that needs your yes is refused for now (nobody's asked at the machine)."

        Chats.open_aside(state, %{remote_chat: true, transcript: [{:meta, intro}]})

      id ->
        {state, id}
    end
  end

  defp chat_id(state),
    do: Enum.find(state.chats.order, &Chats.get(state, &1).remote_chat)

  ## Nobody at the machine: no to everything that asks

  defp refuse(state, id) do
    state = Enum.reduce(@asks, state, &refuse_shown(&2, &1, id))

    {mine, others} = Enum.split_with(state.waiting, fn {_field, ask} -> ask[:chat] == id end)
    for {field, ask} <- mine, do: answer_no(field, ask)
    state = %{state | waiting: others}
    state = Enum.reduce(mine, state, fn {field, ask}, s -> note(s, id, refused(field, ask)) end)

    chat = Chats.get(state, id)

    if chat && (chat.pending_commands || chat.pending_plan || chat.pending_edits != []),
      do: Chats.within(state, id, &refuse_pending/1),
      else: state
  end

  defp refuse_shown(state, field, id) do
    case Map.fetch!(state, field) do
      %{chat: ^id} = ask ->
        answer_no(field, ask)
        state |> Map.put(field, nil) |> Map.put(:status, "ready") |> note(id, refused(field, ask))

      _ ->
        state
    end
  end

  defp answer_no(:asking, ask), do: send(ask.reply_to, {:remote_answer, ask.ref, false})
  defp answer_no(:tool_ask, ask), do: send(ask.reply_to, {:tool_answer, ask.ref, :deny})
  defp answer_no(:purchase_ask, ask), do: send(ask.reply_to, {:purchase_answer, ask.ref, :deny})

  defp refused(:asking, ask),
    do:
      "kept it on this machine: sending it to #{ask[:to] || "Claude or Codex"} needs a yes at the machine"

  defp refused(:tool_ask, ask),
    do: "didn't use #{ask[:tool] || "a tool"}: it needs a yes at the machine"

  defp refused(:purchase_ask, ask),
    do:
      "didn't buy at #{get_in(ask, [:summary, "host"]) || "the shop"}: purchases are made at the machine"

  defp refuse_pending(%{pending_commands: plan} = s) when plan != nil do
    commands = Enum.map_join(plan.commands, ", ", &"`#{&1.command}`")
    {:noreply, s} = CommandWorkflow.key("n", s)

    s
    |> add_meta(
      @note <> "didn't run #{commands}: commands that change things need a yes at the machine"
    )
    |> refuse_pending()
  end

  defp refuse_pending(%{pending_plan: plan} = s) when plan != nil do
    {:noreply, s} = FileWorkflow.plan_key("n", s)

    s
    |> add_meta(@note <> "didn't carry out the file plan: it needs a yes at the machine")
    |> refuse_pending()
  end

  defp refuse_pending(%{pending_edits: [edit | _] = edits} = s) do
    paths = Enum.map_join(edits, ", ", & &1.path)
    s = FileWorkflow.edit_key("esc", edit, s)
    add_meta(s, @note <> "didn't change #{paths}: edits need a yes at the machine")
  end

  defp refuse_pending(s), do: s

  defp note(state, id, text), do: Chats.within(state, id, &add_meta(&1, @note <> text))

  ## To the page

  # What the chat is doing and the reply so far, when they change (the reply
  # at most every @flush_ms).
  defp live(state, cur, chat) do
    now = System.monotonic_time(:millisecond)

    cur =
      if chat.status != cur.status do
        out(state, {:progress, cur.id, chat.status})
        %{cur | status: chat.status}
      else
        cur
      end

    text = chat.streaming

    cur =
      if text not in [nil, ""] and text != cur.sent and
           (cur.at == nil or now - cur.at >= @flush_ms) do
        out(state, {:draft, cur.id, text})
        %{cur | sent: text, at: now}
      else
        cur
      end

    # Unchanged, the state stays the very same term (so nothing is redrawn).
    if cur == state.remote_link.current, do: state, else: put_link(state, current: cur)
  end

  defp answer(state, cur, chat) do
    entries = Enum.drop(chat.transcript, cur.from)
    answers = for({:assistant, text} <- chat.transcript, do: text) |> Enum.drop(cur.answers)

    outputs =
      for {:output, command, output, status} <- entries do
        output =
          if String.length(output) > 2_000,
            do: "…" <> String.slice(output, -2_000, 2_000),
            else: output

        "```\n$ #{command}\n#{output}\n```" <>
          if(status in [nil, "", 0], do: "", else: " (#{status})")
      end

    notes = for {:meta, @note <> text} <- entries, do: text
    errors = for {:meta, "error: " <> text} <- entries, do: text
    cancelled? = {:meta, "cancelled"} in entries

    cond do
      answers != [] or outputs != [] ->
        body = Enum.join(answers ++ outputs ++ Enum.map(notes, &"_#{&1}_"), "\n\n")
        finish(state, cur, "answered", body)

      cancelled? ->
        finish(state, cur, "failed", Enum.join(["cancelled at the machine" | notes], "\n\n"))

      true ->
        why = List.first(errors) || List.first(notes) || "tiny-axe finished without an answer"
        finish(state, cur, "failed", why)
    end
  end

  defp finish(state, cur, status, body) do
    out(state, {:reply, cur.id, status, body})
    put_link(state, current: nil)
  end

  defp out(%{remote_link: %{to: pid}}, message) when is_pid(pid),
    do: send(pid, {:remote_out, message})

  defp out(%{remote_link: %{to: server}}, message) do
    case message do
      {:reply, id, status, body} -> TinyAxe.Remote.send_reply(server, id, status, body)
      {:draft, id, text} -> TinyAxe.Remote.draft(server, id, text)
      {:progress, id, text} -> TinyAxe.Remote.progress(server, id, text)
    end
  catch
    :exit, reason -> Logger.warning("remote chat: #{inspect(reason, limit: 5)}")
  end

  defp put_link(state, changes),
    do: %{state | remote_link: Map.merge(state.remote_link, Map.new(changes))}

  ## /remote

  @doc "`/remote`, `/remote on`, `/remote off`."
  def command(state, arg) do
    link = state.remote_link

    case arg do
      "on" ->
        switch(link.to, true)

        add_meta(
          state,
          "🌐 remote chat on: #{TinyAxe.Account.site_url()}/remote reaches this tiny-axe while it's open " <>
            "(and from now on when it starts). Its messages go to a 🌐 chat; anything that needs your yes is refused for now."
        )

      "off" ->
        switch(link.to, false)
        add_meta(state, "🌐 remote chat off: the site can't reach this tiny-axe")

      "" ->
        add_meta(state, "🌐 remote chat: " <> describe(link))

      _ ->
        add_meta(state, "/remote · /remote on · /remote off")
    end
  end

  @doc "Changes remote connectivity explicitly, without adding anything to a chat transcript."
  def set_enabled(state, on) when is_boolean(on) do
    case switch(state.remote_link.to, on) do
      :ok ->
        phase =
          cond do
            not on -> :off
            state.remote_link.phase == :online -> :online
            true -> :connecting
          end

        {:ok, put_link(state, phase: phase, error: nil)}

      {:error, _} ->
        {:error, "Remote connectivity could not be changed. Refresh to check its status.", state}
    end
  end

  defp switch(pid, on) when is_pid(pid) do
    send(pid, {:remote_out, {:switch, on}})
    :ok
  end

  defp switch(server, on) do
    with :ok <- TinyAxe.Remote.set_on(on) do
      if on, do: TinyAxe.Remote.connect(server), else: TinyAxe.Remote.disconnect(server)
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp describe(%{phase: :off}), do: "off (/remote on)"
  defp describe(%{phase: :online} = link), do: "on, online#{busy(link)}"
  defp describe(%{phase: :waiting, error: error}), do: "on, not connected: #{error}"
  defp describe(%{phase: _connecting}), do: "on, connecting…"

  defp busy(%{current: nil}), do: ""

  defp busy(%{queue: queue}),
    do: " · answering a message#{if queue != [], do: " (#{length(queue)} waiting)"}"

  @doc "For the status bar."
  def label(%{remote_link: %{phase: :off}}), do: ""
  def label(%{remote_link: %{phase: :online}}), do: "  ·  🌐"
  def label(_state), do: "  ·  🌐…"
end
