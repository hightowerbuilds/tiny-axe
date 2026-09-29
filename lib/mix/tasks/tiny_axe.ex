defmodule Mix.Tasks.TinyAxe do
  @shortdoc "Launch the tiny-axe TUI"
  @moduledoc """
  Launches the TUI.

      mix tiny_axe
      mix tiny_axe --model qwen3.5:4b
      mix tiny_axe --decider jev     # TypeSafe Jev for route/verify
      mix tiny_axe --dir ~/code/app  # project to read and edit (default: current dir)

  `bin/tiny-axe` runs this from any directory, using that directory as the project.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [model: :string, decider_model: :string, decider: :string, dir: :string]
      )

    if model = opts[:model], do: Application.put_env(:tiny_axe, :model, model)
    if model = opts[:decider_model], do: Application.put_env(:tiny_axe, :decider_model, model)

    if dir = opts[:dir] do
      dir = Path.expand(dir)
      unless File.dir?(dir), do: Mix.raise("--dir #{inspect(dir)} is not a directory")
      Application.put_env(:tiny_axe, :project_dir, dir)
    end

    case opts[:decider] do
      nil -> :ok
      "jev" -> Application.put_env(:tiny_axe, :decider, TinyAxe.Decider.Jev)
      "local" -> Application.put_env(:tiny_axe, :decider, TinyAxe.Decider.Local)
      other -> Mix.raise("unknown --decider #{inspect(other)} (expected jev or local)")
    end

    Application.put_env(:tiny_axe, :start_tui, true)

    Mix.Task.run("app.start")

    # The TUI stops the VM when the user quits. If it keeps crashing, its
    # supervisor gives up; exit then instead of hanging with no screen.
    ref = Process.monitor(TinyAxe.Supervisor)

    receive do
      {:DOWN, ^ref, :process, _, reason} ->
        Mix.shell().error("tiny-axe stopped: #{Exception.format_exit(reason)}")
        System.halt(1)
    end
  end
end
