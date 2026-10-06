defmodule TinyAxe.Commander.Validation do
  @moduledoc false

  alias TinyAxe.{Files, Ops}

  @doc """
  Checks the working folder and commands. Returns the folder as an absolute
  path, or the problems in plain words.
  """
  @spec check(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, [String.t()]}
  def check(dir, commands) do
    abs = Ops.resolve(dir)
    directory? = File.dir?(abs)
    scaffold_commands = Enum.filter(commands, &scaffolds_here?/1)
    entries = if directory? and scaffold_commands != [], do: visible_entries(abs), else: []

    problems =
      [
        dir == "" && "Give the working folder in \"dir\".",
        (dir != "" and not directory?) &&
          "#{Ops.show(abs)} isn't an existing folder. Use its parent and create it with a command.",
        (directory? and not workable?(abs)) &&
          "Commands can't run in #{Ops.show(abs)}: pick a folder inside the home folder " <>
            "(not the home folder itself) or the project, outside hidden folders."
      ] ++
        Enum.map(commands, fn c ->
          c =~ ~r/(^|[\s;&|(])(sudo|su|doas)\s/ &&
            "#{inspect(c)} uses sudo/su/doas; commands run as the user, in a sandbox."
        end) ++
        Enum.map(scaffold_commands, fn c ->
          entries != [] &&
            "#{inspect(c)} scaffolds into #{Ops.show(abs)}, which isn't empty " <>
              "(#{entries |> Enum.take(3) |> Enum.join(", ")}), so it would " <>
              "cancel. Scaffold into a new subfolder instead, e.g. `npm create vite@latest web -- --template react`."
        end)

    case Enum.filter(problems, & &1) do
      [] -> {:ok, abs}
      problems -> {:error, problems}
    end
  end

  # `npm create vite@latest . …`, `npx create-next-app .`, `yarn create vite .`: a
  # scaffolder aimed at the working folder itself (as opposed to a new subfolder).
  defp scaffolds_here?(command) do
    command =~
      ~r/\b(npm|pnpm|yarn|bun|npx|bunx)\s+(create|init)?\s*[\w@\/.-]*create[\w@\/.-]*\s+\.(\s|$)/ or
      command =~ ~r/\b(npm|pnpm|yarn|bun)\s+(create|init)\s+[\w@\/.-]+\s+\.(\s|$)/
  end

  defp visible_entries(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.reject(&String.starts_with?(&1, ".")) |> Enum.sort()
      _ -> []
    end
  end

  # The home folder itself would make every file writable; any folder below it is fine.
  defp workable?(abs) do
    abs != Ops.root() and not Ops.hidden?(abs) and (abs == Files.root() or Ops.changeable?(abs))
  end
end
