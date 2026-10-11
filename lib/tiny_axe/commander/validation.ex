defmodule TinyAxe.Commander.Validation do
  @moduledoc false

  alias TinyAxe.{Files, Ops, Shell}
  alias TinyAxe.Shell.{Processes, ReadOnly}

  @refused ~w(sudo su doas)
  # System package managers need root (and AUR helpers call sudo).
  @system_packages ~w(apt apt-get aptitude pacman yay paru dnf yum zypper apk emerge snap)

  @doc "Programs commands may never run: `{for_root, system_package_managers}`."
  def refused, do: {@refused, @system_packages}

  @doc """
  Resolves the plan's `"dir"` (a subfolder of `current`; "" for `current`
  itself) and checks it and the commands. Returns the folder as an absolute
  path, or the problems in plain words, written for the model to act on.
  """
  @spec check_plan(String.t(), String.t() | nil, [String.t()]) ::
          {:ok, String.t()} | {:error, [String.t()]}
  def check_plan(current, sub, commands) do
    case subfolder(current, sub) do
      {:ok, dir} -> check(dir, commands)
      {:error, problem} -> {:error, [problem]}
    end
  end

  defp subfolder(current, sub) do
    sub = if is_binary(sub), do: String.trim(sub), else: ""

    abs =
      cond do
        sub in ["", "."] -> current
        String.starts_with?(sub, "~") -> Ops.resolve(sub)
        true -> Path.expand(sub, current)
      end

    cond do
      abs == current ->
        {:ok, current}

      not String.starts_with?(abs, current <> "/") ->
        {:error,
         "\"dir\" (#{sub}) must be a subfolder of the current folder, #{Ops.show(current)}, " <>
           "written relative to it (e.g. \"code/web\"), or \"\" for the current folder itself."}

      not File.dir?(abs) ->
        {:error,
         "\"dir\": #{Ops.show(abs)} isn't an existing folder. Set \"dir\" to the existing " <>
           "folder it would go in, and create it with a command (e.g. `mkdir -p name`, or a scaffolder)."}

      true ->
        {:ok, abs}
    end
  end

  @doc """
  Checks the working folder and commands. Returns the folder as an absolute
  path, or the problems in plain words.

  Commands that only look (`TinyAxe.Shell.ReadOnly`) may run in any existing
  folder; commands that change things not in the home folder itself, a hidden
  folder, or outside the home folder and the project.
  """
  @spec check(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, [String.t()]}
  def check(dir, commands) do
    abs = Ops.resolve(dir)
    directory? = File.dir?(abs)
    read_only? = ReadOnly.all?(commands)
    scaffold_commands = Enum.filter(commands, &scaffolds_here?/1)
    entries = if directory? and scaffold_commands != [], do: visible_entries(abs), else: []

    problems =
      [
        not directory? && "#{Ops.show(abs)} isn't an existing folder.",
        (directory? and not read_only?) && folder_problem(abs)
      ] ++
        Enum.map(commands, fn c ->
          c =~ ~r/(^|[\s;&|(])(sudo|su|doas)\s/ &&
            "#{inspect(c)} uses sudo/su/doas; commands run as the user, in a sandbox, and can't get root."
        end) ++
        Enum.map(commands, &system_package_problem/1) ++
        Enum.map(commands, &guard_problem(&1, directory? && abs)) ++
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

  # Where commands that change things may not run. The path as given and
  # where its symlinks lead must both be fine.
  defp folder_problem(abs) do
    real = Shell.real_path(abs)

    cond do
      abs == Ops.root() or real == Ops.root() ->
        "Commands that change things can't run in the home folder itself (#{Ops.show(abs)}). " <>
          "Set \"dir\" to the subfolder they're for, relative to the current folder " <>
          "(e.g. \"code/my-app\"); to make a new folder, set \"dir\" to the folder it goes in " <>
          "and create it with a command. Commands that only look may run here."

      Ops.hidden?(abs) or Ops.hidden?(real) ->
        "Commands that change things can't run in #{Ops.show(abs)}, which is in a hidden " <>
          "folder; only commands that only look may run there. Use a folder outside hidden folders."

      not (workable?(abs) and workable?(real)) ->
        "Commands that change things can't run in #{Ops.show(abs)}: pick a folder inside " <>
          "the home folder (not the home folder itself) or the project, outside hidden folders."

      true ->
        nil
    end
  end

  defp guard_problem(_command, false), do: nil

  defp guard_problem(command, dir) do
    case Processes.guard(command, dir) do
      {:error, problem} -> problem
      :ok -> nil
    end
  end

  defp system_package_problem(command) do
    names =
      case ReadOnly.parse(command) do
        {:ok, simples} ->
          for %{words: [first | _]} <- simples, do: Path.basename(first.text)

        {:error, _} ->
          ~r/(?:^|[;&|(]\s*)([\w.\/-]+)/
          |> Regex.scan(String.trim(command))
          |> Enum.map(fn [_, n] -> Path.basename(n) end)
      end

    case Enum.find(names, &(&1 in @system_packages)) do
      nil ->
        nil

      name ->
        "#{inspect(command)} uses #{name}, a system package manager, which needs root: " <>
          "tiny-axe can't run it. Give the user the command to run themselves instead."
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
