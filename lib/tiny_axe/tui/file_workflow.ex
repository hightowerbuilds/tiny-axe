defmodule TinyAxe.TUI.FileWorkflow do
  @moduledoc false

  import TinyAxe.TUI.Conversation, only: [add_meta: 2]
  import TinyAxe.TUI.View, only: [page: 1, scroll_plan: 2]

  def recovery_key(code, %{recovery: plan} = state) when plan != nil do
    action =
      case code do
        "r" -> &TinyAxe.Ops.Runner.roll_back/2
        "c" -> &TinyAxe.Ops.Runner.continue/2
        "k" -> &TinyAxe.Ops.Runner.keep/2
        _ -> nil
      end

    cond do
      action ->
        {:noreply, start_ops(%{state | recovery: nil, plan_scroll: 0}, plan.id, action)}

      code == "esc" ->
        meta = "the interrupted plan is still in the journal; tiny-axe will ask again next start"
        {:noreply, %{state | recovery: nil, transcript: state.transcript ++ [{:meta, meta}]}}

      true ->
        {:noreply, scroll_plan(code, state)}
    end
  end

  def undo_key(code, %{confirm_undo: plan} = state) when plan != nil do
    case code do
      "y" ->
        state = %{state | confirm_undo: nil, plan_scroll: 0}
        {:noreply, start_ops(state, plan.id, &TinyAxe.Ops.Runner.undo_plan/2)}

      c when c in ["n", "esc"] ->
        {:noreply, %{state | confirm_undo: nil, plan_scroll: 0, status: "ready"}}

      _ ->
        {:noreply, scroll_plan(code, state)}
    end
  end

  def plan_key(code, %{pending_plan: plan} = state) when plan != nil do
    case code do
      "y" ->
        state = %{state | pending_plan: nil, plan_scroll: 0}

        {:noreply,
         start_ops(state, nil, fn _id, me ->
           TinyAxe.Ops.Runner.run(plan.request, plan.ops, me)
         end)}

      c when c in ["n", "esc"] ->
        meta = "plan cancelled; nothing changed"

        {:noreply,
         %{
           state
           | pending_plan: nil,
             plan_scroll: 0,
             status: "ready",
             transcript: state.transcript ++ [{:meta, meta}]
         }}

      _ ->
        {:noreply, scroll_plan(code, state)}
    end
  end

  def request_undo(state) do
    case TinyAxe.Ops.Journal.last_undoable() do
      nil -> {:noreply, %{state | transcript: state.transcript ++ [{:meta, "nothing to undo"}]}}
      plan -> {:noreply, %{state | confirm_undo: plan, plan_scroll: 0}}
    end
  end

  # y and n only record the decision; once every edit has one, the accepted
  # edits run together as one journaled plan (backed up, and ctrl+z undoes them).
  def edit_key("y", edit, state) do
    {_, added, removed} = edit.diff

    %{state | accepted_edits: state.accepted_edits ++ [edit]}
    |> next_edit("accepted the change to #{edit.path} (+#{added} −#{removed})")
  end

  def edit_key("n", edit, state), do: next_edit(state, "skipped the change to #{edit.path}")

  def edit_key("esc", _edit, state) do
    skipped = Enum.map(state.pending_edits, &{:meta, "skipped the change to #{&1.path}"})

    %{state | pending_edits: [], transcript: state.transcript ++ skipped, status: "ready"}
    |> save_accepted_edits()
  end

  def edit_key(code, _edit, state) when code in ["down", "j"],
    do: %{state | edit_scroll: state.edit_scroll + 1}

  def edit_key(code, _edit, state) when code in ["up", "k"],
    do: %{state | edit_scroll: max(state.edit_scroll - 1, 0)}

  def edit_key("page_down", _edit, state),
    do: %{state | edit_scroll: state.edit_scroll + page(state)}

  def edit_key("page_up", _edit, state),
    do: %{state | edit_scroll: max(state.edit_scroll - page(state), 0)}

  def edit_key(_code, _edit, state), do: state

  defp next_edit(%{pending_edits: [_ | rest]} = state, meta) do
    %{
      state
      | pending_edits: rest,
        edit_scroll: 0,
        transcript: state.transcript ++ [{:meta, meta}],
        status: if(rest == [], do: "ready", else: state.status)
    }
    |> save_accepted_edits()
  end

  defp save_accepted_edits(%{pending_edits: [], accepted_edits: [_ | _] = edits} = state) do
    ops =
      Enum.map(edits, fn e ->
        %{
          op: :write,
          path: e.abs,
          content: e.new,
          old_hash: e.old && TinyAxe.Ops.hash(e.old),
          about: "edit",
          sources: []
        }
      end)

    request = "save #{Enum.map_join(edits, ", ", & &1.path)}"

    %{state | accepted_edits: []}
    |> start_ops(nil, fn _id, me -> TinyAxe.Ops.Runner.run(request, ops, me) end)
  end

  defp save_accepted_edits(state), do: state

  def crashed(state, reason) do
    meta = "the file runner crashed (#{inspect(reason)}); its plan is safe in the journal"

    {:noreply,
     %{
       state
       | ops_job: nil,
         ops_monitor: nil,
         recovery: List.first(TinyAxe.Ops.Journal.interrupted()),
         transcript: state.transcript ++ [{:meta, meta}],
         status: "ready"
     }}
  end

  # `fun` is a Runner call taking (id, reply_to).
  defp start_ops(state, id, fun) do
    case fun.(id, self()) do
      result when result == :ok or elem(result, 0) == :ok ->
        id = if result == :ok, do: id, else: elem(result, 1)
        ref = Process.monitor(TinyAxe.Ops.Runner)
        %{state | ops_job: id, ops_monitor: ref, status: "working on files…"}

      {:error, reason} ->
        meta = "✗ couldn't start: #{inspect(reason)}"
        %{state | transcript: state.transcript ++ [{:meta, meta}], status: "ready"}
    end
  end

  def event({:progress, i, total}, state), do: %{state | status: "step #{i} of #{total}…"}
  def event({:note, text}, state), do: add_meta(state, "· " <> text)

  def event({:finished, n}, state),
    do: ops_done(state, ["✓ done: #{n} #{plural(n, "step")} · ctrl+z undoes it"])

  def event({:stopped, i, error}, state) do
    ops_done(state, [
      "✗ stopped at step #{i + 1}: #{error}",
      "the steps before it stand · ctrl+z undoes them"
    ])
  end

  def event({:interrupted, reason}, state) do
    state = ops_done(state, ["✗ the plan was interrupted (#{inspect(reason)})"])
    %{state | recovery: List.first(TinyAxe.Ops.Journal.interrupted())}
  end

  def event({:continue_refused, problems}, state) do
    state = ops_done(state, ["✗ can't continue the plan:" | Enum.map(problems, &("  " <> &1))])
    %{state | recovery: List.first(TinyAxe.Ops.Journal.interrupted())}
  end

  def event({kind, notes}, state) when kind in [:rolled_back, :kept, :undone] do
    label = %{rolled_back: "↶ rolled back", kept: "kept the plan as it was", undone: "↶ undone"}
    ops_done(state, [label[kind] | Enum.map(notes, &("  " <> &1))])
  end

  def event(_event, state), do: state

  defp ops_done(state, lines) do
    if state.ops_monitor, do: Process.demonitor(state.ops_monitor, [:flush])
    state = Enum.reduce(lines, state, &add_meta(&2, &1))
    %{state | ops_job: nil, ops_monitor: nil, status: "ready"}
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
