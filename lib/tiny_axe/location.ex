defmodule TinyAxe.Location do
  @moduledoc """
  Where tiny-axe is working: the current folder, like a shell's. It starts
  where tiny-axe was launched (`:project_dir`, or the current directory).

  Code moves it, never a model's free text:

    * `cd <path>` typed at the prompt
    * the Decider picking, from real folders, the one a request names
      (`TinyAxe.Pipeline`)
    * commands that ran: the folder they ran in, or the one the last
      successful command `cd`-ed into (`TinyAxe.Commander`)

  Every model call is told the current folder and what's in it; relative
  paths mean "relative to here", and it's the project that file reading and
  editing work in.
  """

  use Agent

  @trail 10

  def start_link(_opts),
    do: Agent.start_link(fn -> %{current: nil, trail: []} end, name: __MODULE__)

  @doc "The current folder, as an absolute path."
  @spec current() :: String.t()
  def current do
    case Process.whereis(__MODULE__) && Agent.get(__MODULE__, & &1.current) do
      path when is_binary(path) -> path
      _ -> launch_dir()
    end
  end

  defp launch_dir, do: Path.expand(Application.get_env(:tiny_axe, :project_dir) || File.cwd!())

  @doc "Earlier locations, newest first."
  @spec trail() :: [String.t()]
  def trail, do: Agent.get(__MODULE__, & &1.trail)

  @doc """
  Moves to `path` (relative to the current folder, `~/…` or absolute), if it's
  an existing folder.
  """
  @spec cd(String.t()) :: {:ok, String.t()} | {:error, :not_a_folder}
  def cd(path) do
    abs = resolve(path)
    if File.dir?(abs), do: {:ok, set(abs)}, else: {:error, :not_a_folder}
  end

  @doc "Moves to an absolute folder, remembering where it was."
  @spec set(String.t()) :: String.t()
  def set(abs) do
    Agent.update(__MODULE__, fn %{current: cur, trail: trail} = s ->
      from = cur || launch_dir()

      trail =
        if from == abs, do: trail, else: Enum.take([from | List.delete(trail, from)], @trail)

      %{s | current: abs, trail: trail}
    end)

    abs
  end

  @doc "Back to where tiny-axe was launched (tests, and ctrl+l)."
  @spec reset() :: :ok
  def reset, do: Agent.update(__MODULE__, fn _ -> %{current: nil, trail: []} end)

  @doc """
  Resolves a path the way the user means it: `~` is the home folder
  (`TinyAxe.Ops.root/0`), relative paths are relative to the current folder.
  """
  @spec resolve(String.t()) :: String.t()
  def resolve("~"), do: TinyAxe.Ops.root()
  def resolve("~/" <> rest), do: TinyAxe.Ops.root() |> Path.join(rest) |> Path.expand()
  def resolve(path), do: Path.expand(path, current())

  @doc "What's in a folder, for a model to see: visible entries, folders marked with /."
  @spec listing(String.t(), pos_integer()) :: String.t()
  def listing(dir \\ current(), limit \\ 40) do
    case File.ls(dir) do
      {:ok, names} ->
        names = names |> Enum.reject(&String.starts_with?(&1, ".")) |> Enum.sort()
        shown = Enum.take(names, limit)
        more = if length(names) > limit, do: ["… (#{length(names) - limit} more)"], else: []

        case shown do
          [] -> "(empty)"
          _ -> Enum.map_join(Enum.map(shown, &entry(dir, &1)) ++ more, "\n", &("  " <> &1))
        end

      {:error, _} ->
        "(can't list)"
    end
  end

  defp entry(dir, name), do: if(File.dir?(Path.join(dir, name)), do: name <> "/", else: name)

  @doc """
  Real folders a request might mean: around the current folder (its
  subfolders, parent and siblings), earlier locations, the launch folder,
  two levels of the home folder, and folders whose names match words in
  the request. The Decider picks from these, so a location is always real.
  """
  @spec candidates(String.t()) :: [String.t()]
  def candidates(request) do
    here = current()
    home = TinyAxe.Ops.root()
    parent = Path.dirname(here)

    ([here, parent, launch_dir(), home] ++
       subdirs(here) ++
       subdirs(parent) ++
       trail() ++
       (home |> subdirs() |> Enum.flat_map(&[&1 | subdirs(&1)])) ++
       search(request, home))
    |> Enum.uniq()
    |> Enum.filter(&visible_under?(&1, home))
  end

  defp subdirs(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        for n <- Enum.sort(names),
            not String.starts_with?(n, "."),
            path = Path.join(dir, n),
            File.dir?(path),
            do: path

      _ ->
        []
    end
  end

  defp visible_under?(path, home) do
    path == home or
      (String.starts_with?(path, home <> "/") and
         not (path
              |> Path.relative_to(home)
              |> Path.split()
              |> Enum.any?(&String.starts_with?(&1, "."))))
  end

  # Folders named like words in the request, found with fd.
  defp search(request, home) do
    words =
      ~r/[\p{L}\p{N}_-]{3,}/u
      |> Regex.scan(String.downcase(request))
      |> List.flatten()
      |> Enum.reject(
        &(&1 in ~w(the and into inside folder folders directory repo project my run go in to cd))
      )
      |> Enum.uniq()

    with [_ | _] <- words, fd when fd != nil <- System.find_executable("fd") do
      pattern = "^(" <> Enum.map_join(words, "|", &Regex.escape/1) <> ")$"

      args =
        ~w(--type d --ignore-case --max-depth 6 --max-results 30 --exclude node_modules --exclude _build --exclude deps)

      case System.cmd(fd, args ++ [pattern, home], stderr_to_stdout: true) do
        {out, 0} ->
          out |> String.split("\n", trim: true) |> Enum.map(&String.trim_trailing(&1, "/"))

        _ ->
          []
      end
    else
      _ -> []
    end
  end
end
