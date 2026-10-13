defmodule TinyAxe.Desktop.Runner do
  @moduledoc """
  Runs the desktop's own programs (`omarchy`, `hyprctl`, `killall`) for
  appearance changes: as the user, outside the sandbox (the user's choice,
  2026-10-12: OS changes run unsandboxed), with a program name and a list of
  arguments, never through a shell, so a value can't become a second command.

  Environment variables that look like secrets are removed
  (`TinyAxe.Shell.secret_env?/1`), apart from the D-Bus address, which
  GTK settings and the Omarchy shell need. Each run is stopped after
  30 seconds.

  Tests swap the implementation (`config :tiny_axe, :desktop_runner`) so
  they never touch the real desktop.
  """

  @callback cmd(String.t(), [String.t()]) :: {String.t(), non_neg_integer()} | {:error, term()}

  @doc "Runs `program` with `args`: `{output, exit_status}` or `{:error, reason}`."
  @spec cmd(String.t(), [String.t()]) :: {String.t(), non_neg_integer()} | {:error, term()}
  def cmd(program, args) do
    impl = Application.get_env(:tiny_axe, :desktop_runner, __MODULE__.Desktop)
    impl.cmd(program, args)
  end

  @doc "Runs it and returns `{:ok, output}` only when it exits 0."
  @spec ok(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def ok(program, args) do
    case cmd(program, args) do
      {:error, reason} -> {:error, "#{program} couldn't run (#{inspect(reason)})"}
      {out, 0} -> {:ok, String.trim(out)}
      {out, status} -> {:error, "#{program} exited #{status}: #{tail(out)}"}
    end
  end

  defp tail(out), do: out |> String.trim() |> String.slice(-400..-1//1)

  defmodule Desktop do
    @moduledoc false
    @behaviour TinyAxe.Desktop.Runner

    @timeout 30_000
    @keep ~w(DBUS_SESSION_BUS_ADDRESS)

    @impl true
    def cmd(program, args) do
      case System.find_executable(program) do
        nil ->
          {:error, :not_found}

        path ->
          task =
            Task.async(fn ->
              System.cmd(path, args, stderr_to_stdout: true, env: env())
            end)

          case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
            {:ok, result} -> result
            _ -> {:error, :timeout}
          end
      end
    end

    defp env do
      for {name, _} <- System.get_env(),
          name not in @keep,
          TinyAxe.Shell.secret_env?(name),
          do: {name, nil}
    end
  end
end
