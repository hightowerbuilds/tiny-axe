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

  Nothing in the 🌐 chat waits for someone at the machine. What needs a yes
  goes to the Chat tab as an approval card (`docs/plan-chrome-purchases.md`,
  P3), when the phone may approve it and approvals are ready (an approval
  PIN, `TinyAxe.Remote.Approvals`): purchases, tool calls, sending a request
  to Claude, sandboxed commands. The answer is checked here (the PIN's
  proof, and a purchase's exact total) before anything goes ahead; anything
  else is a no. Desktop and OS changes, a card's PIN or CVC, file plans and
  edits, and "your turn in the browser" are always refused, as is
  everything when approvals aren't ready, and the reply says so. Commands
  that only look still run, as they do without asking anywhere.

  `/remote on|off` switches it (remembered for the next start), `/remote`
  says how it stands; the status bar shows 🌐 while it's on.
  """

  require Logger

  alias TinyAxe.Remote.Approvals
  alias TinyAxe.Tools.Redact
  alias TinyAxe.TUI.{Chats, CommandWorkflow, FileWorkflow, Presentation, Run}

  import TinyAxe.TUI.Conversation, only: [add_meta: 2]

  @flush_ms 250
  # Lines the reply repeats: what was refused because nobody's asked.
  @note "🔒 "
  @asks [:asking, :tool_ask, :purchase_ask]
  # How long an approval card waits: inside the gate's own 10 minutes.
  @approval_ttl 540

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
      queue: [],
      # Approval cards open on the Chat tab, by a local ref: what they're for
      # (the ask, or the chat's commands), the site's id and nonce, and when
      # they stop waiting.
      approvals: %{}
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

  def event(state, {:approval_opened, ref, %{"id" => id}}) do
    case state.remote_link.approvals[ref] do
      nil ->
        # Its message is over: nothing to approve now.
        close(state, id, "withdrawn")
        state

      entry ->
        put_approval(state, ref, %{entry | id: id})
    end
  end

  def event(state, {:approval_failed, ref, why}) do
    case pop_approval(state, ref) do
      {nil, state} ->
        state

      {entry, state} ->
        no(state, entry, "#{entry.what}: couldn't put it on the Chat tab (#{why})")
    end
  end

  def event(state, {:approval_answer, id, approval}) do
    case Enum.find(state.remote_link.approvals, fn {_ref, e} -> e.id == id end) do
      nil ->
        state

      {ref, entry} ->
        {_, state} = pop_approval(state, ref)
        decide(state, entry, approval)
    end
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
    state = state |> asks(cur.chat) |> expire()

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
          "🌐 messages from the site's Chat tab are answered here. What needs your yes goes " <>
            "to the Chat tab (approvals: #{Approvals.describe(Approvals.status())})."

        Chats.open_aside(state, %{remote_chat: true, transcript: [{:meta, intro}]})

      id ->
        {state, id}
    end
  end

  defp chat_id(state),
    do: Enum.find(state.chats.order, &Chats.get(state, &1).remote_chat)

  ## What the 🌐 chat asks: a card on the Chat tab, or no

  defp asks(state, id) do
    state = Enum.reduce(@asks, state, &take_shown(&2, &1, id))

    {mine, others} = Enum.split_with(state.waiting, fn {_field, ask} -> ask[:chat] == id end)

    state =
      Enum.reduce(mine, %{state | waiting: others}, fn {f, ask}, s -> take(s, f, ask, id) end)

    case Chats.get(state, id) do
      nil -> state
      chat -> pending(state, id, chat)
    end
  end

  # A question on screen from the 🌐 chat leaves the machine's popups.
  defp take_shown(state, field, id) do
    case Map.fetch!(state, field) do
      %{chat: ^id} = ask ->
        state |> Map.put(field, nil) |> Map.put(:status, "ready") |> take(field, ask, id)

      _ ->
        state
    end
  end

  defp take(state, field, ask, id) do
    item = %{field: field, ask: ask, chat: id, what: what(field, ask)}

    case approvable(field, ask) do
      {:ok, kind, body} -> open(state, item, kind, body)
      {:refuse, why} -> no(state, item, "#{item.what}: #{why}")
    end
  end

  # The chat's own y/n questions: sandboxed commands can go to the Chat tab;
  # desktop changes, file plans and edits are refused.
  defp pending(state, id, chat) do
    state =
      case chat.pending_commands do
        nil ->
          state

        %{kind: :desktop} ->
          Chats.within(state, id, &refuse_commands(&1, "desktop changes are made at the machine"))

        plan ->
          key = :erlang.phash2(plan)

          if Enum.any?(state.remote_link.approvals, fn {_, e} -> e[:key] == key end) do
            state
          else
            item = %{field: :commands, key: key, chat: id, what: "didn't run #{commands(plan)}"}
            open(state, item, "command", commands_body(plan))
          end
      end

    chat = Chats.get(state, id)

    if chat && (chat.pending_plan || chat.pending_edits != []),
      do: Chats.within(state, id, &(&1 |> refuse_plan() |> refuse_edits())),
      else: state
  end

  defp approvable(:purchase_ask, ask) do
    if ask[:mode] == :card_step or (ask[:needs] || []) != [],
      do: {:refuse, "a card's PIN or CVC is typed at the machine"},
      else: {:ok, "purchase", purchase_body(ask.summary, ask[:checks] || [])}
  end

  defp approvable(:tool_ask, ask) do
    shell = ask[:shell]

    cond do
      ask[:class] == :handoff ->
        {:refuse, "it needs you in the browser at the machine"}

      ask[:class] == :payment_step ->
        {:refuse, "card details are sent only with a yes at the machine"}

      shell && shell[:unsandboxed] ->
        {:refuse, "desktop and OS changes are never approved from the site"}

      shell ->
        {:ok, "command", shell_body(shell)}

      true ->
        {:ok, "tool", tool_body(ask)}
    end
  end

  defp approvable(:asking, ask), do: {:ok, "model", model_body(ask)}

  defp open(state, item, kind, body) do
    case Approvals.challenge() do
      {:ok, challenge} ->
        ref = make_ref()

        params =
          Map.merge(challenge, %{
            message_id: state.remote_link.current.id,
            kind: kind,
            body: redact(body),
            expires_in: @approval_ttl
          })

        out(state, {:open_approval, ref, params})

        out(
          state,
          {:progress, state.remote_link.current.id, "waiting for your yes on the Chat tab"}
        )

        entry =
          Map.merge(item, %{
            kind: kind,
            body: body,
            nonce: challenge.nonce,
            id: nil,
            until: System.monotonic_time(:millisecond) + @approval_ttl * 1000
          })

        put_approval(state, ref, entry)

      {:error, status} ->
        no(state, item, "#{item.what}: approvals from the site are #{Approvals.describe(status)}")
    end
  end

  ## Answers from the Chat tab

  defp decide(state, entry, approval) do
    answer = approval["answer"] || %{}

    case answer["decision"] do
      "approve" ->
        total = answer["total"] || ""
        proof = %{id: entry.id, nonce: entry.nonce, total: total, proof: answer["proof"]}

        case Approvals.verify(proof) do
          :ok -> approved(state, entry, total)
          {:error, :wrong_pin, left} -> wrong_pin(state, entry, left)
          {:error, status} -> refused(state, entry, Approvals.describe(status))
        end

      "deny" ->
        close(state, entry.id, "denied")
        no(state, entry, "#{entry.what}: you said no on the Chat tab")

      _ ->
        no(state, entry, "#{entry.what}: the approval was closed on the site")
    end
  end

  defp approved(state, %{kind: "purchase", body: %{total: expected}} = entry, typed)
       when typed != expected do
    refused(state, entry, "the total typed (#{typed}) isn't #{expected}")
  end

  defp approved(state, entry, _total) do
    close(state, entry.id, "approved")
    yes(state, entry)
  end

  defp wrong_pin(state, entry, left) do
    close(state, entry.id, "wrong_pin")

    state =
      no(state, entry, "#{entry.what}: wrong approval PIN on the Chat tab (#{left} tries left)")

    if left == 0,
      do:
        withdraw_all(
          state,
          "refused",
          "approvals from the site are #{Approvals.describe(:locked)}"
        ),
      else: state
  end

  defp refused(state, entry, why) do
    close(state, entry.id, "refused")
    no(state, entry, "#{entry.what}: #{why}")
  end

  # Cards nobody answered in time are a no.
  defp expire(state) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(state.remote_link.approvals, state, fn {ref, entry}, s ->
      if entry.until <= now do
        {_, s} = pop_approval(s, ref)
        close(s, entry.id, "expired")
        no(s, entry, "#{entry.what}: nobody approved it on the Chat tab in time")
      else
        s
      end
    end)
  end

  defp withdraw_all(state, outcome, why) do
    Enum.reduce(state.remote_link.approvals, state, fn {ref, entry}, s ->
      {_, s} = pop_approval(s, ref)
      close(s, entry.id, outcome)
      if why, do: no(s, entry, "#{entry.what}: #{why}"), else: no(s, entry, nil)
    end)
  end

  ## Yes and no

  defp yes(state, %{field: :commands} = entry) do
    Chats.within(state, entry.chat, fn s ->
      s = add_meta(s, @note <> "approved on the Chat tab: #{commands(s.pending_commands)}")

      if same_plan?(s, entry) do
        {:noreply, s} = CommandWorkflow.key("y", s)
        s
      else
        s
      end
    end)
  end

  defp yes(state, %{field: field, ask: ask} = entry) do
    case field do
      :asking -> send(ask.reply_to, {:remote_answer, ask.ref, true})
      :tool_ask -> send(ask.reply_to, {:tool_answer, ask.ref, :once})
      :purchase_ask -> send(ask.reply_to, {:purchase_answer, ask.ref, :confirm})
    end

    note(state, entry.chat, "approved on the Chat tab: #{entry.body.title}")
  end

  defp no(state, %{field: :commands} = entry, why) do
    Chats.within(state, entry.chat, fn s ->
      if same_plan?(s, entry), do: refuse_commands(s, nil, why), else: s
    end)
  end

  defp no(state, %{field: field, ask: ask} = entry, why) do
    answer_no(field, ask)
    if why, do: note(state, entry.chat, why), else: state
  end

  defp same_plan?(s, entry),
    do: s.pending_commands && :erlang.phash2(s.pending_commands) == entry.key

  defp answer_no(:asking, ask), do: send(ask.reply_to, {:remote_answer, ask.ref, false})
  defp answer_no(:tool_ask, ask), do: send(ask.reply_to, {:tool_answer, ask.ref, :deny})
  defp answer_no(:purchase_ask, ask), do: send(ask.reply_to, {:purchase_answer, ask.ref, :deny})

  defp what(:asking, ask),
    do: "kept it on this machine instead of sending it to #{ask[:to] || "Claude or Codex"}"

  defp what(:tool_ask, ask), do: "didn't use #{ask[:tool] || "a tool"}"

  defp what(:purchase_ask, ask),
    do: "didn't buy at #{get_in(ask, [:summary, "host"]) || "the shop"}"

  # `why` given: that's the line; otherwise the usual one.
  defp refuse_commands(s, why, line \\ nil) do
    commands = commands(s.pending_commands)
    {:noreply, s} = CommandWorkflow.key("n", s)

    cond do
      line -> add_meta(s, @note <> line)
      why -> add_meta(s, @note <> "didn't run #{commands}: #{why}")
      true -> s
    end
  end

  defp refuse_plan(%{pending_plan: plan} = s) when plan != nil do
    {:noreply, s} = FileWorkflow.plan_key("n", s)
    add_meta(s, @note <> "didn't carry out the file plan: it needs a yes at the machine")
  end

  defp refuse_plan(s), do: s

  defp refuse_edits(%{pending_edits: [edit | _] = edits} = s) do
    paths = Enum.map_join(edits, ", ", & &1.path)
    s = FileWorkflow.edit_key("esc", edit, s)
    add_meta(s, @note <> "didn't change #{paths}: edits need a yes at the machine")
  end

  defp refuse_edits(s), do: s

  defp commands(%{commands: commands}), do: Enum.map_join(commands, ", ", &"`#{&1.command}`")
  defp commands(_), do: "the commands"

  ## What the card shows

  defp purchase_body(s, checks) do
    %{
      title:
        "Buy at #{s["host"]} for #{s["total_text"]}#{if s["currency"], do: " #{s["currency"]}"}",
      lines:
        Enum.map(s["items"] || [], &("· " <> &1)) ++
          Enum.reject(
            [
              s["ship_to"] && "Ship to: #{s["ship_to"]}",
              "Paying with: #{s["paying_with"] || s["payment"] || "(not shown)"}"
            ],
            &is_nil/1
          ),
      checks: for({result, text} <- checks, do: %{ok: result == :ok, text: text}),
      total: Presentation.expected_total(s),
      total_text: s["total_text"]
    }
  end

  defp tool_body(ask) do
    args =
      (ask[:args] || %{})
      |> Enum.take(8)
      |> Enum.map(fn {k, v} ->
        v = if is_binary(v), do: v, else: JSON.encode!(v)
        "#{k}: #{String.slice(v, 0, 200)}"
      end)

    %{
      title: "Use #{ask[:tool]}#{if ask[:server], do: " (#{ask.server})"}",
      lines:
        Enum.reject(
          [Presentation.describe_class(ask[:class]), ask[:reason] && "It #{ask.reason}."],
          &is_nil/1
        ) ++ args
    }
  end

  defp shell_body(shell) do
    %{
      title: "Run a command",
      lines:
        ["$ " <> shell.command, "in #{shell.dir}"] ++
          ["Only that folder and tool installs (~/.cargo, ~/.local/bin…) can change."]
    }
  end

  defp commands_body(plan) do
    %{
      title:
        "Run #{length(plan.commands)} command#{if length(plan.commands) == 1, do: "", else: "s"}",
      lines:
        ["in #{TinyAxe.Ops.show(plan.dir)}"] ++
          Enum.map(plan.commands, &("$ " <> &1.command)) ++
          ["They run in the sandbox: only that folder and tool installs can change."]
    }
  end

  defp model_body(ask) do
    %{
      title: "Send this request to #{ask[:to] || "Claude"}",
      lines:
        Enum.reject(
          [
            ask[:reason] && "Why: #{ask.reason}",
            "It leaves this machine: the request, the recent conversation and what its tools " <>
              "return go to #{ask[:to] || "Claude"} on your subscription."
          ],
          &is_nil/1
        )
    }
  end

  defp redact(%{} = body) do
    Map.new(body, fn
      {k, v} when is_binary(v) -> {k, Redact.secrets(v)}
      {k, v} when is_list(v) -> {k, Enum.map(v, &redact_item/1)}
      other -> other
    end)
  end

  defp redact_item(v) when is_binary(v), do: Redact.secrets(v)
  defp redact_item(%{text: text} = c), do: %{c | text: Redact.secrets(text)}
  defp redact_item(v), do: v

  defp close(_state, nil, _outcome), do: :ok
  defp close(state, id, outcome), do: out(state, {:close_approval, id, outcome})

  defp put_approval(state, ref, entry),
    do: put_link(state, approvals: Map.put(state.remote_link.approvals, ref, entry))

  defp pop_approval(state, ref) do
    {entry, rest} = Map.pop(state.remote_link.approvals, ref)
    {entry, put_link(state, approvals: rest)}
  end

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
    # Cards still open for this message are no longer needed.
    state = withdraw_all(state, "withdrawn", nil)
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
      {:open_approval, ref, params} -> TinyAxe.Remote.open_approval(server, ref, params)
      {:close_approval, id, outcome} -> TinyAxe.Remote.close_approval(server, id, outcome)
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
        add_meta(
          state,
          "🌐 remote chat: #{describe(link)} · approvals: #{Approvals.describe(Approvals.status())}"
        )

      "pin" ->
        TinyAxe.TUI.PinFlow.open(state)

      "approvals " <> on_off when on_off in ["on", "off"] ->
        case Approvals.set_enabled(on_off == "on") do
          :ok ->
            add_meta(
              state,
              "🔐 approvals from the Chat tab: #{Approvals.describe(Approvals.status())}"
            )

          {:error, why} ->
            add_meta(state, "🔐 #{why}")
        end

      _ ->
        add_meta(
          state,
          "/remote · /remote on · /remote off · /remote pin · /remote approvals on|off"
        )
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
