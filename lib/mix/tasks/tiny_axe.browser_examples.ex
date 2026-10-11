defmodule Mix.Tasks.TinyAxe.BrowserExamples do
  @shortdoc "Inspect, delete, restore, expire, roll back and promote the browser agent's reviewed examples"
  @moduledoc """
  The browser agent's validated memory (`TinyAxe.Browser.Examples`), kept in
  `<state>/browser_examples/` (`TinyAxe.Browser.Examples.Store`):

      mix tiny_axe.browser_examples                    # status: retrieval mode, active version, counts
      mix tiny_axe.browser_examples list               # the active set's examples
      mix tiny_axe.browser_examples show ID            # one example, in full
      mix tiny_axe.browser_examples history            # every version, and what changed
      mix tiny_axe.browser_examples delete ID          # out of the set (kept in trash/, restorable)
      mix tiny_axe.browser_examples restore ID
      mix tiny_axe.browser_examples rollback VERSION   # that version's examples become active again
      mix tiny_axe.browser_examples expire             # expired examples out; old evidence to the Trash
      mix tiny_axe.browser_examples candidates         # captured lessons, never retrieved until promoted
      mix tiny_axe.browser_examples promote CANDIDATE --reviewer NAME \
        --objective TEXT --observed TEXT [--lesson TEXT]

  Every change writes a new version, so nothing is lost and any version can
  be rolled back to. `promote` is a person's review: the only way a lesson
  from a real session becomes trusted (a candidate whose outcome is
  unresolved can't be promoted). The reviewer writes the objective and
  what was observed in their own words; page labels are replaced and
  personal details scrubbed (see `TinyAxe.Browser.Examples.promote/3` for
  what a promotion keeps). Retrieval itself is switched with
  `config :tiny_axe, :browser_examples` (off, shadow, on); keeping lessons
  from real sessions with `:browser_examples_persist` (off by default).
  """

  use Mix.Task

  alias TinyAxe.Browser.Examples

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    command(args)
  end

  defp command([]) do
    active = Examples.active()

    Mix.shell().info("""
    retrieval: #{Examples.mode()} (config :tiny_axe, :browser_examples)
    keeping lessons from real sessions: #{if Examples.persist?(), do: "on", else: "off"} \
    (evidence kept #{Examples.retention_days()} days)
    active set: version #{active["version"]}, #{length(active["examples"] || [])} examples, \
    #{length(Examples.usable())} usable now
    candidates waiting for review: #{length(Examples.candidates())}\
    """)
  end

  defp command(["list"]) do
    for ex <- Examples.active()["examples"] || [] do
      Mix.shell().info(
        "#{String.pad_trailing(ex["id"], 26)} rev #{ex["rev"]}  #{ex["label"]["kind"]}" <>
          "  workflows #{Enum.join(ex["workflows"], ",")}  signals #{Enum.join(ex["signals"], ",")}" <>
          if(ex["expires_at"], do: "  expires #{ex["expires_at"]}", else: "") <>
          if(Examples.current?(ex), do: "", else: "  (older versions: not retrieved)")
      )
    end
  end

  defp command(["show", id]) do
    case Examples.show(id) do
      nil -> Mix.raise("no example #{id} in the active set")
      ex -> Mix.shell().info(JSON.encode!(ex))
    end
  end

  defp command(["history"]) do
    for v <- Examples.history() do
      Mix.shell().info(
        "#{if v.active, do: "*", else: " "} #{v.version}  #{v.examples} examples  #{v.at || ""}  #{v.change}"
      )
    end
  end

  defp command(["delete", id]), do: report(Examples.delete(id), "deleted #{id} (kept in trash/)")
  defp command(["restore", id]), do: report(Examples.restore(id), "restored #{id}")

  defp command(["rollback", version]) do
    case Integer.parse(version) do
      {v, ""} -> report(Examples.rollback(v), "rolled back to version #{v}")
      _ -> Mix.raise("rollback needs a version number")
    end
  end

  defp command(["expire"]) do
    %{expired: ids, files: files} = Examples.expire()

    Mix.shell().info(
      "expired: #{if ids == [], do: "none", else: Enum.join(ids, ", ")}; " <>
        "#{files} evidence or candidate files moved to the Trash"
    )
  end

  defp command(["candidates"]) do
    for c <- Examples.candidates() do
      Mix.shell().info(
        "#{c["id"]}  #{Enum.join(c["signals"], ",")}  #{get_in(c, ["chain", "verified", "status"])}" <>
          if(c["excluded"], do: "  (#{c["excluded"]}: can't be promoted yet)", else: "") <>
          "\n  #{get_in(c, ["chain", "observed"])}"
      )
    end
  end

  defp command(["promote", id | rest]) do
    {opts, _, _} =
      OptionParser.parse(rest,
        strict: [reviewer: :string, lesson: :string, objective: :string, observed: :string]
      )

    reviewer = opts[:reviewer] || Mix.raise("promote needs --reviewer NAME (a person's review)")

    report(
      Examples.promote(id, %{kind: "human_review", reviewer: reviewer},
        lesson: opts[:lesson],
        objective: opts[:objective],
        observed: opts[:observed]
      ),
      "promoted #{id}"
    )
  end

  defp command(_), do: Mix.raise("unknown command; see `mix help tiny_axe.browser_examples`")

  defp report({:ok, version}, what), do: Mix.shell().info("#{what}: now version #{version}")
  defp report({:error, why}, _what), do: Mix.raise("not done: #{inspect(why)}")
end
