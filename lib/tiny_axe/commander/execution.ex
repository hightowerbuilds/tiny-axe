defmodule TinyAxe.Commander.Execution do
  @moduledoc false

  alias TinyAxe.{Decider, Location, Ops, Shell}
  alias TinyAxe.Commander.Validation

  @doc """
  Runs an approved plan's commands in order, stopping at the first failure.
  Events: `{:cmd_start, i, command}`, `{:cmd_os_pid, pid}`, `{:cmd_output, text}`,
  `{:cmd_exit, i, status}`, then `{:cmds_done, [%{command:, status:, output:}]}`
  and `{:cmds_checked, probability}`.

  Exit codes aren't enough (create-vite exits 0 after "Operation cancelled"), so
  the Decider also judges from the output whether the commands did what was asked.
  """
  @spec execute(map(), (term() -> any())) :: :ok
  def execute(plan, notify) do
    # Re-checked at the moment of running, not only when planned: the folder
    # or the rules may have changed while the plan waited for approval.
    case Validation.check(plan.dir, Enum.map(plan.commands, & &1.command)) do
      {:ok, _} -> run_commands(plan, notify)
      {:error, problems} -> notify.({:cmds_refused, problems})
    end

    :ok
  end

  defp run_commands(plan, notify) do
    results =
      plan.commands
      |> Enum.with_index()
      |> Enum.reduce_while([], fn {%{command: c}, i}, acc ->
        notify.({:cmd_start, i, c})

        case Shell.run(plan.dir, c, &notify.({:cmd_output, &1}),
               on_start: &notify.({:cmd_os_pid, &1})
             ) do
          {:ok, status, output} ->
            notify.({:cmd_exit, i, status})
            result = %{command: c, status: status, output: output}
            if status == 0, do: {:cont, [result | acc]}, else: {:halt, [result | acc]}

          {:error, reason} ->
            notify.({:cmd_exit, i, reason})
            {:halt, [%{command: c, status: reason, output: ""} | acc]}
        end
      end)
      |> Enum.reverse()

    notify.({:cmds_done, results})
    follow(plan.dir, results, notify)
    check? = Application.get_env(:tiny_axe, :check_command_outcome, true)
    notify.({:cmds_checked, if(check?, do: outcome(plan.request, results))})
    :ok
  end

  # The location follows the commands: to the folder they ran in, or, if the last
  # one succeeded and began `cd x && …`, into x (so after
  # `cd web && npm install`, "start the dev server" means in web/).
  defp follow(dir, results, notify) do
    from = Location.current()

    to =
      with %{status: 0, command: c} <- List.last(results),
           [_, sub] <- Regex.run(~r/\A\s*cd\s+("[^"]+"|'[^']+'|\S+)\s*&&/, c),
           abs = Path.expand(String.trim(sub, "\"") |> String.trim("'"), dir),
           true <- File.dir?(abs) do
        abs
      else
        _ -> dir
      end

    if to != from do
      Location.set(to)
      notify.({:moved, %{from: Ops.show(from), to: Ops.show(to), confidence: nil}})
    end
  end

  defp outcome(request, results) do
    ran =
      Enum.map_join(results, "\n\n", fn r ->
        tail = r.output |> String.split("\n") |> Enum.take(-30) |> Enum.join("\n")
        "$ #{r.command}\n(exit status: #{r.status})\n#{tail}"
      end)

    question = %{
      worked: %{
        type: :noul,
        instructions:
          "Judging by the commands' output (not just their exit status), did they do what " <>
            "the user asked?"
      }
    }

    # :unavailable (the decider couldn't judge) is not the same as nil (checking is off).
    %{request: request, commands_and_output: ran}
    |> Decider.decide(question)
    |> Decider.p(:worked) || :unavailable
  end
end
