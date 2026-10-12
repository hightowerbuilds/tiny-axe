defmodule TinyAxe.TUI.Run do
  @moduledoc false

  import TinyAxe.TUI.Conversation, only: [request_history: 1]

  @tick_ms 100

  def start(state, work) do
    tui = self()
    id = make_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(TinyAxe.TaskSupervisor, fn ->
        work.(&send(tui, {:pipeline, id, &1}))
      end)

    Process.monitor(pid)
    schedule_tick()
    %{state | run: {id, pid}}
  end

  def schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  def request(state, prompt) do
    history = request_history(state)

    state =
      start(state, fn notify ->
        TinyAxe.Pipeline.run(history, prompt, notify,
          remote: remote_mode(state),
          # The 🌐 chat is never on the leash (TinyAxe.Leash).
          leash: not state.remote_chat
        )
      end)

    %{
      state
      | pending_prompt: prompt,
        transcript: state.transcript ++ [{:user, prompt}],
        streaming: nil,
        scroll: :bottom,
        copy_back: 0,
        agent_run: false,
        status: "routing…"
    }
  end

  defp remote_mode(%{remote: nil}), do: :ask
  defp remote_mode(%{remote: true}), do: :allowed
  defp remote_mode(%{remote: false}), do: :denied

  def cancel(%{run: nil} = state), do: state

  def cancel(%{run: {id, pid}} = state) do
    Process.exit(pid, :kill)

    if state.card_flow, do: TinyAxe.Cards.discard_entry()

    # This run's questions, on screen or waiting, are refused, so the gate lets
    # them go; other runs' questions stay.
    mine = fn ask -> ask != nil and ask[:run] in [id, nil] end
    asked = [asking: state.asking, tool_ask: state.tool_ask, purchase_ask: state.purchase_ask]
    {refused, waiting} = Enum.split_with(state.waiting, fn {_field, ask} -> mine.(ask) end)
    for {field, ask} <- asked ++ refused, mine.(ask), do: refuse(field, ask)
    cleared = for {field, ask} <- asked, mine.(ask), into: %{}, do: {field, nil}
    state = Map.merge(%{state | waiting: waiting}, cleared)

    # Killing the task doesn't stop the sandboxed command, so stop that (and
    # whatever it started) directly.
    state =
      case state.running_cmd do
        %{os_pid: os_pid} = cmd when is_integer(os_pid) ->
          TinyAxe.Shell.stop(os_pid)
          entry = {:output, cmd.command, String.trim_trailing(cmd.output), "cancelled"}
          %{state | running_cmd: nil, transcript: state.transcript ++ [entry]}

        _ ->
          %{state | running_cmd: nil}
      end

    partial = if state.streaming in [nil, ""], do: [], else: [{:assistant, state.streaming}]

    %{
      state
      | run: nil,
        pending_prompt: nil,
        streaming: nil,
        compacting: nil,
        card_flow: nil,
        transcript: state.transcript ++ partial ++ [{:meta, "cancelled"}]
    }
  end

  defp refuse(:tool_ask, ask), do: send(ask.reply_to, {:tool_answer, ask.ref, :deny})
  defp refuse(:purchase_ask, ask), do: send(ask.reply_to, {:purchase_answer, ask.ref, :deny})
  # The asking process is killed with its run: nothing waits for a reply.
  defp refuse(:asking, _ask), do: :ok

  def fail(state, message) do
    %{
      state
      | run: nil,
        streaming: nil,
        compacting: nil,
        pending_prompt: nil,
        transcript: state.transcript ++ [{:meta, "error: " <> message}],
        status: "error"
    }
  end
end
