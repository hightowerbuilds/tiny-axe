defmodule Mix.Tasks.TinyAxe.DeadEnds do
  @shortdoc "List or forget the browser paths that didn't work (dead ends), per site"

  @moduledoc """
  The paths tiny-axe's browser agent found didn't work, per site
  (`TinyAxe.Browser.DeadEnds`, docs/plan-leash.md):

      mix tiny_axe.dead_ends                 # every kept path, newest first
      mix tiny_axe.dead_ends forget HOST     # forget one site's
      mix tiny_axe.dead_ends forget --all    # forget them all

  A dead end (Jev's verdict, or two failures) is told to the agent when it
  reaches that site, and a repeat that fails again in the same task is
  refused. One-offs are kept so a second failure can make them dead ends.
  Each is dropped after 30 days without another failure.
  """

  use Mix.Task

  alias TinyAxe.Browser.DeadEnds

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    command(args)
  end

  defp command([]) do
    case DeadEnds.list() do
      [] ->
        Mix.shell().info("No paths kept yet.")

      paths ->
        for p <- paths do
          mark = if p["verdict"] == "dead_end", do: "✗ dead end", else: "· one-off "

          Mix.shell().info(
            "#{mark}  #{p["host"]}#{p["path"]}  #{p["action"]} \"#{p["label"]}\"  " <>
              "#{p["failures"]}× · last #{String.slice(p["last"], 0, 10)} · #{Enum.join(p["codes"], ", ")}"
          )
        end
    end
  end

  defp command(["forget", "--all"]),
    do: Mix.shell().info("Forgot #{DeadEnds.forget(:all)} path(s).")

  defp command(["forget", host]),
    do: Mix.shell().info("Forgot #{DeadEnds.forget(host)} path(s) on #{host}.")

  defp command(_), do: Mix.raise("usage: mix tiny_axe.dead_ends [forget HOST | forget --all]")
end
