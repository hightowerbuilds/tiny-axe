defmodule TinyAxe.Files do
  @moduledoc """
  The project directory tiny-axe works in: listing its files, reading them into
  context, and proposing edits (which, once confirmed, run as a journaled plan
  through `TinyAxe.Ops.Runner`, so they can be undone).

    * Reads go wherever the user points with `@path` (relative to the project,
      `~/…` or absolute). Directories are listed rather than read.
    * Edits are limited to the project directory, outside hidden folders, happen
      only after the user confirms a diff, and are refused if the file changed
      on disk since it was read.

  The project is tiny-axe's current folder (`TinyAxe.Location`), which starts
  at `config :tiny_axe, :project_dir`, or the directory it was launched in.
  """

  @max_listing 5_000
  # Binary sniffing looks at this much of a file.
  @sniff 8_000

  @doc "The project: the current folder (`TinyAxe.Location`), where tiny-axe was launched until it moves."
  @spec root() :: String.t()
  def root, do: TinyAxe.Location.current()

  @doc "Resolves a path the way the user would mean it: relative to the project, `~` or absolute."
  @spec resolve(String.t()) :: String.t()
  def resolve(path), do: Path.expand(path, root())

  @doc "The path to show the user: relative inside the project, `~/…` or absolute outside it."
  @spec display(String.t()) :: String.t()
  def display(abs) do
    home = System.user_home!()

    cond do
      inside_project?(abs) -> Path.relative_to(abs, root())
      String.starts_with?(abs, home <> "/") -> "~/" <> Path.relative_to(abs, home)
      true -> abs
    end
  end

  defp inside_project?(abs) do
    abs = Path.expand(abs)
    abs != root() and String.starts_with?(abs, root() <> "/")
  end

  @doc """
  Lists files under `dir` (default: the project) as sorted relative paths,
  honouring `.gitignore` when ripgrep is installed.
  """
  @spec list(String.t()) :: [String.t()]
  def list(dir \\ root()) do
    files =
      cond do
        rg = System.find_executable("rg") ->
          case System.cmd(rg, ["--files", "--no-messages"], cd: dir) do
            {out, status} when status in [0, 1] -> String.split(out, "\n", trim: true)
            _ -> wildcard(dir)
          end

        true ->
          wildcard(dir)
      end

    files |> Enum.sort() |> Enum.take(@max_listing)
  end

  defp wildcard(dir) do
    ignored = ~w(.git _build deps node_modules .elixir_ls)

    Path.wildcard(Path.join(dir, "**/*"))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.reject(fn rel -> rel |> Path.split() |> Enum.any?(&(&1 in ignored)) end)
  end

  @doc """
  Finds `@path` mentions in a prompt that point at existing files or
  directories. Email addresses don't count.
  """
  @spec mentions(String.t()) :: [String.t()]
  def mentions(prompt) do
    ~r/(?<![\w@])@([~.\/\w][^\s,;:!?()"'`]*)/u
    |> Regex.scan(prompt, capture: :all_but_first)
    |> Enum.map(fn [path] -> path |> String.trim_trailing(".") |> resolve() end)
    |> Enum.filter(&File.exists?/1)
    |> Enum.uniq()
  end

  @doc """
  Reads a text file, cut to `max_chars`. Returns `{:ok, content, truncated?}`,
  or an error for binaries, directories and unreadable files.
  """
  @spec read(String.t(), pos_integer()) ::
          {:ok, String.t(), boolean()} | {:error, term()}
  def read(abs, max_chars) do
    with {:ok, content} <- File.read(abs),
         false <- binary?(content) do
      if String.length(content) > max_chars,
        do: {:ok, String.slice(content, 0, max_chars), true},
        else: {:ok, content, false}
    else
      true -> {:error, :binary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp binary?(content) do
    head = binary_part(content, 0, min(byte_size(content), @sniff))
    String.contains?(head, <<0>>) or not String.valid?(content)
  end

  @doc """
  Orders candidate files by how many words of the request appear in their
  paths, keeping the first `limit`. Used to shortlist a large project before
  the Decider picks from it.
  """
  @spec shortlist([String.t()], String.t(), pos_integer()) :: [String.t()]
  def shortlist(files, _prompt, limit) when length(files) <= limit, do: files

  def shortlist(files, prompt, limit) do
    words =
      prompt
      |> String.downcase()
      |> then(&Regex.scan(~r/[a-z0-9]{3,}/, &1))
      |> List.flatten()
      |> MapSet.new()

    files
    |> Enum.with_index()
    |> Enum.sort_by(fn {path, i} ->
      parts =
        path
        |> String.downcase()
        |> then(&Regex.scan(~r/[a-z0-9]{3,}/, &1))
        |> List.flatten()
        |> MapSet.new()

      # More matching words first, then shallower paths, then listing order.
      {-MapSet.size(MapSet.intersection(parts, words)), length(Path.split(path)), i}
    end)
    |> Enum.take(limit)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Finds whole-file edits in a model response: fenced blocks whose info line
  names a path after the language (```` ```elixir lib/foo.ex ````), inside
  the project and different from what's on disk.
  """
  @spec proposed_edits(String.t()) :: [
          %{path: String.t(), abs: String.t(), old: String.t() | nil, new: String.t()}
        ]
  def proposed_edits(text) do
    ~r/```[\w+-]+[ \t]+([^\s`]+)[^\n]*\n(.*?)```/s
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.filter(fn [path, _] -> path =~ ~r/[\/.]/ and not String.contains?(path, "://") end)
    |> Enum.map(fn [path, content] -> {resolve(path), content} end)
    # The same rules as file plans (no hidden folders, .git included), since
    # accepted edits run as a plan.
    |> Enum.filter(fn {abs, _} -> inside_project?(abs) and TinyAxe.Ops.changeable?(abs) end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.flat_map(fn {abs, content} ->
      old =
        case File.read(abs) do
          {:ok, old} -> old
          {:error, _} -> nil
        end

      if old == content,
        do: [],
        else: [%{path: display(abs), abs: abs, old: old, new: content}]
    end)
  end

  @doc "Hash of a file's whole contents, or nil if it can't be read."
  @spec hash(String.t()) :: String.t() | nil
  def hash(abs) do
    case File.read(abs) do
      {:ok, content} -> TinyAxe.Ops.hash(content)
      {:error, _} -> nil
    end
  end

  @doc """
  Splits proposed edits into those safe to offer and those refused, with the
  reason. An edit is only safe if it was written from the version of the file
  the model was given: `given.snapshots` maps each file given to the model to
  the hash of its contents then, and `given.partial` holds files it only saw
  part of. Refused:

    * a file the model saw only part of (its rewrite would drop the rest)
    * a file that changed while the model was writing (the rewrite is based on
      an older version)
    * an existing file the model was never given (it can't know what's there)

  New files are fine.
  """
  @spec against_snapshots([map()], %{partial: MapSet.t(), snapshots: map()}) ::
          {[map()], [{map(), String.t()}]}
  def against_snapshots(edits, given) do
    edits
    |> Enum.map(fn edit -> {edit, refusal(edit, given)} end)
    |> Enum.split_with(fn {_edit, reason} -> reason == nil end)
    |> then(fn {ok, refused} -> {Enum.map(ok, &elem(&1, 0)), refused} end)
  end

  defp refusal(%{abs: abs, old: old}, given) do
    cond do
      abs in given.partial ->
        "the file was too long to show the model in full, so its rewrite would drop the rest"

      old == nil ->
        nil

      not Map.has_key?(given.snapshots, abs) ->
        "the model was never given this file, so it can't know what's in it; " <>
          "mention it with @#{display(abs)} and ask again"

      TinyAxe.Ops.hash(old) != given.snapshots[abs] ->
        "it changed while the model was writing, so the rewrite is based on an older version; " <>
          "ask again to work from the current one"

      true ->
        nil
    end
  end

  @doc """
  A line diff for display: `{:ins | :del | :eq, line}` entries, keeping
  `context` unchanged lines around each change and `:gap` where lines are
  elided. Returns `{lines, added, removed}`.
  """
  @spec diff(String.t() | nil, String.t(), non_neg_integer()) ::
          {[{:ins | :del | :eq, String.t()} | :gap], non_neg_integer(), non_neg_integer()}
  def diff(old, new, context \\ 2) do
    ops =
      List.myers_difference(String.split(old || "", "\n"), String.split(new, "\n"))
      |> Enum.flat_map(fn {op, lines} -> Enum.map(lines, &{op, &1}) end)

    added = Enum.count(ops, &match?({:ins, _}, &1))
    removed = Enum.count(ops, &match?({:del, _}, &1))

    changed =
      ops
      |> Enum.with_index()
      |> Enum.reject(&match?({{:eq, _}, _}, &1))
      |> Enum.map(&elem(&1, 1))

    keep = MapSet.new(for i <- changed, j <- (i - context)..(i + context)//1, do: j)

    lines =
      ops
      |> Enum.with_index()
      |> Enum.chunk_by(fn {_, i} -> MapSet.member?(keep, i) end)
      |> Enum.flat_map(fn [{_, i} | _] = chunk ->
        if MapSet.member?(keep, i), do: Enum.map(chunk, &elem(&1, 0)), else: [:gap]
      end)

    {lines, added, removed}
  end
end
