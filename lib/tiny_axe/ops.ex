defmodule TinyAxe.Ops do
  @moduledoc """
  File operations tiny-axe carries out for the user once they approve a plan:
  move, copy, make a folder, and write a file. There is no delete.

  `expand/1` turns a model's raw plan into concrete operations, expanding
  wildcards and resolving destinations, and simulates the plan to catch
  problems before anything is touched:

    * sources must exist, and nothing is overwritten except a file being
      rewritten on purpose with `write`
    * changes stay inside `root/0` (the home directory by default) or the
      project directory, and never touch hidden files or folders there

  `step/2` carries out one approved operation and returns undo records, which
  `TinyAxe.Ops.Runner` journals before moving on. `undo_record/2` reverses one:
  moves go back, created folders are removed if still empty, and written files
  are restored from backup or moved to tiny-axe's trash, but only if nobody has
  changed them since. `settle/3` works out how far a step got if tiny-axe
  stopped in the middle of it.
  """

  alias TinyAxe.Files

  @type op ::
          %{op: :move | :copy, from: String.t(), to: String.t()}
          | %{op: :mkdir, path: String.t()}
          | %{op: :write, path: String.t(), about: String.t(), sources: [String.t()]}
          | %{op: :write, path: String.t(), content: String.t(), old_hash: String.t() | nil}

  @max_ops 200

  @doc """
  The system Trash, per the freedesktop.org spec, so trashed files show up in
  the file manager's Trash: `config :tiny_axe, :trash_dir`, or `$XDG_DATA_HOME/Trash`.
  """
  @spec trash_dir() :: String.t()
  def trash_dir do
    Application.get_env(:tiny_axe, :trash_dir) ||
      Path.join(System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"), "Trash")
  end

  @doc "Where file operations may happen, besides the project: `config :tiny_axe, :fs_root`, or home."
  @spec root() :: String.t()
  def root, do: Path.expand(Application.get_env(:tiny_axe, :fs_root) || System.user_home!())

  @doc """
  Resolves a path the user or model gave. `~` means `root/0` (the home folder,
  unless configured otherwise, as tests do), and relative paths are relative to it.
  """
  @spec resolve(String.t()) :: String.t()
  def resolve("~"), do: root()
  def resolve("~/" <> rest), do: Path.join(root(), rest) |> Path.expand()
  def resolve(path), do: Path.expand(path, root())

  @doc "Whether operations may change `abs`: inside the root or project, and not hidden there."
  @spec changeable?(String.t()) :: boolean()
  def changeable?(abs) do
    abs = Path.expand(abs)

    Enum.any?([Files.root(), root()], fn base ->
      inside?(abs, base) and
        not (abs
             |> Path.relative_to(base)
             |> Path.split()
             |> Enum.any?(&String.starts_with?(&1, ".")))
    end)
  end

  defp inside?(abs, base), do: abs != base and String.starts_with?(abs, base <> "/")

  @doc """
  Turns raw operations from the model (string-keyed maps) into concrete ones,
  or returns the problems in plain words for the model to fix.
  """
  @spec expand([map()]) :: {:ok, [op()]} | {:error, [String.t()]}
  def expand(raw) do
    {ops, errors} =
      raw
      |> Enum.flat_map(&expand_one/1)
      |> Enum.split_with(&match?({:ok, _}, &1))

    ops = Enum.map(ops, &elem(&1, 1))
    errors = Enum.map(errors, &elem(&1, 1))
    # Making a folder that's already there is a no-op; leave it out of the plan.
    ops = Enum.reject(ops, &(&1.op == :mkdir and File.dir?(&1.path)))

    cond do
      errors != [] ->
        {:error, errors}

      ops == [] ->
        {:error, ["The plan has no operations."]}

      length(ops) > @max_ops ->
        {:error, ["The plan has #{length(ops)} operations; the limit is #{@max_ops}."]}

      true ->
        ops |> read_sources_now() |> simulate()
    end
  end

  # A write's contents are generated before any step runs, so its sources are
  # read where they are now. A source named by where the plan will put it is
  # read from where it currently is.
  defp read_sources_now(ops) do
    origin =
      for %{op: op, from: from, to: to} when op in [:move, :copy] <- ops,
          into: %{},
          do: {to, from}

    Enum.map(ops, fn
      %{op: :write, sources: sources} = w ->
        %{w | sources: Enum.map(sources, &Map.get(origin, &1, &1))}

      op ->
        op
    end)
  end

  defp expand_one(%{"op" => op} = raw) when op in ["move", "copy"] do
    from = raw["from"] || ""
    to = raw["to"] || ""

    cond do
      from == "" or to == "" ->
        [{:error, "A #{op} needs both \"from\" and \"to\" (got #{JSON.encode!(raw)})."}]

      true ->
        case sources(from) do
          [] ->
            [{:error, "Nothing matches #{inspect(from)}."}]

          srcs ->
            to_abs = resolve(to)
            into_dir? = length(srcs) > 1 or String.ends_with?(to, "/") or File.dir?(to_abs)

            Enum.map(srcs, fn src ->
              dest = if into_dir?, do: Path.join(to_abs, Path.basename(src)), else: to_abs
              {:ok, %{op: String.to_existing_atom(op), from: src, to: dest}}
            end)
        end
    end
  end

  defp expand_one(%{"op" => "mkdir"} = raw) do
    case raw["path"] || raw["to"] do
      p when p in [nil, ""] -> [{:error, "A mkdir needs a \"path\"."}]
      p -> [{:ok, %{op: :mkdir, path: resolve(p)}}]
    end
  end

  defp expand_one(%{"op" => "write"} = raw) do
    case raw["path"] || raw["to"] do
      p when p in [nil, ""] ->
        [{:error, "A write needs a \"path\"."}]

      p ->
        sources = raw |> Map.get("sources", []) |> List.wrap() |> Enum.map(&resolve/1)
        [{:ok, %{op: :write, path: resolve(p), about: raw["about"] || "", sources: sources}}]
    end
  end

  defp expand_one(%{"op" => "trash"} = raw) do
    case raw["path"] || raw["from"] do
      p when p in [nil, ""] ->
        [{:error, "A trash needs a \"path\"."}]

      p ->
        case sources(p) do
          [] -> [{:error, "Nothing matches #{inspect(p)}."}]
          srcs -> Enum.map(srcs, &{:ok, trash_op(&1)})
        end
    end
  end

  defp expand_one(raw), do: [{:error, "Unknown operation #{inspect(raw["op"] || raw)}."}]

  # Wildcards match visible entries only, like a shell does.
  defp sources(from) do
    abs = resolve(from)

    if String.contains?(from, ["*", "?", "["]),
      do: abs |> Path.wildcard() |> Enum.sort(),
      else: if(File.exists?(abs), do: [abs], else: [])
  end

  # Walks the plan against a picture of the filesystem as it will be, so later
  # steps see earlier ones (a folder made in step 1 exists for step 2).
  defp simulate(ops) do
    {_fs, errors} =
      Enum.reduce(ops, {%{}, []}, fn op, {fs, errors} ->
        case check(op, fs) do
          {:ok, fs} -> {fs, errors}
          {:error, message} -> {fs, [message | errors]}
        end
      end)

    if errors == [], do: {:ok, ops}, else: {:error, Enum.reverse(errors)}
  end

  defp check(%{op: op, from: from, to: to}, fs) do
    cond do
      not exists?(from, fs) ->
        {:error, "#{show(from)} doesn't exist (at that point in the plan)."}

      op == :move and not changeable?(from) ->
        {:error, "#{show(from)} can't be moved: #{off_limits()}"}

      not changeable?(to) ->
        {:error, "Can't #{op} to #{show(to)}: #{off_limits()}"}

      exists?(to, fs) ->
        {:error, "#{show(to)} already exists; tiny-axe never overwrites with #{op}."}

      String.starts_with?(to <> "/", from <> "/") ->
        {:error, "Can't #{op} #{show(from)} into itself."}

      true ->
        fs = fs |> Map.put(to, :exists) |> put_parents(to)
        {:ok, if(op == :move, do: Map.put(fs, from, :gone), else: fs)}
    end
  end

  defp check(%{op: :trash, path: path}, fs) do
    cond do
      not exists?(path, fs) ->
        {:error, "#{show(path)} doesn't exist (at that point in the plan)."}

      not changeable?(path) ->
        {:error, "#{show(path)} can't be trashed: #{off_limits()}"}

      true ->
        {:ok, Map.put(fs, path, :gone)}
    end
  end

  defp check(%{op: :mkdir, path: path}, fs) do
    cond do
      not changeable?(path) ->
        {:error, "Can't make folder #{show(path)}: #{off_limits()}"}

      exists?(path, fs) and not File.dir?(path) and fs[path] != :exists ->
        {:error, "#{show(path)} exists and isn't a folder."}

      true ->
        {:ok, fs |> Map.put(path, :exists) |> put_parents(path)}
    end
  end

  defp check(%{op: :write, path: path} = op, fs) do
    # Sources are read before the plan runs, so they must exist now.
    missing = op |> Map.get(:sources, []) |> Enum.reject(&File.exists?/1)
    old_hash = Map.get(op, :old_hash, :unknown)

    cond do
      not changeable?(path) ->
        {:error, "Can't write #{show(path)}: #{off_limits()}"}

      File.dir?(path) ->
        {:error, "#{show(path)} is a folder, not a file."}

      missing != [] ->
        {:error, missing_source(missing, fs)}

      old_hash != :unknown and fs[path] == nil and hash_path(path) != old_hash ->
        {:error, "#{show(path)} changed since tiny-axe read it."}

      true ->
        {:ok, fs |> Map.put(path, :exists) |> put_parents(path)}
    end
  end

  defp missing_source(missing, fs) do
    Enum.map_join(missing, " ", fn src ->
      if Map.get(fs, src) == :gone or gone_parent?(src, fs),
        do: "Source #{show(src)} was moved away by an earlier step, so the write can't read it.",
        else: "Source #{show(src)} doesn't exist."
    end)
  end

  defp off_limits,
    do: "changes are limited to #{show(root())} and the project, outside hidden folders."

  defp exists?(path, fs) do
    case Map.get(fs, path) do
      :exists -> true
      :gone -> false
      nil -> File.exists?(path) and not gone_parent?(path, fs)
    end
  end

  # A file inside a folder that an earlier step moved away is gone too.
  defp gone_parent?(path, fs) do
    Enum.any?(fs, fn {p, state} -> state == :gone and String.starts_with?(path, p <> "/") end)
  end

  defp put_parents(fs, path) do
    parent = Path.dirname(path)

    if parent == path or Map.has_key?(fs, parent),
      do: fs,
      else: put_parents(Map.put(fs, parent, :exists), parent)
  end

  @doc "Re-checks concrete operations against the disk as it is now, e.g. before continuing a plan."
  @spec recheck([op()]) :: :ok | {:error, [String.t()]}
  def recheck([]), do: :ok

  def recheck(ops) do
    case simulate(ops) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "One line describing an operation, for the plan and the transcript."
  @spec describe(op() | map()) :: String.t()
  def describe(%{op: :move, from: from, to: to}) do
    if Path.dirname(from) == Path.dirname(to),
      do: "rename #{show(from)} → #{Path.basename(to)}",
      else: "move #{show(from)} → #{show(to)}"
  end

  def describe(%{op: :copy, from: from, to: to}), do: "copy #{show(from)} → #{show(to)}"

  def describe(%{op: :trash, path: path, folder: true, items: n}),
    do: "trash folder #{show(path)} (#{n} #{if n == 1, do: "file", else: "files"})"

  def describe(%{op: :trash, path: path}), do: "trash #{show(path)}"

  def describe(%{op: :mkdir, path: path}), do: "make folder #{show(path)}"

  def describe(%{op: :write, path: path} = op) do
    verb = if Map.get(op, :old_hash) != nil, do: "rewrite", else: "write"
    "#{verb} #{show(path)}"
  end

  @doc "A path as the user would write it: `~/…` under `root/0`."
  @spec show(String.t()) :: String.t()
  def show(abs) do
    home = root()

    if abs == home or String.starts_with?(abs, home <> "/"),
      do: "~" <> String.replace_prefix(abs, home, ""),
      else: abs
  end

  ## Carrying out a plan, one journalled step at a time

  # Steps return undo records: plain string-keyed maps, so the journal can store
  # them as JSON and `undo_record/2` can reverse them after a restart.

  @doc """
  Carries out one approved operation. A `:write` must carry `:content` and
  `:old_hash` (the hash of the file it was generated against, or nil for a new
  file); the file it replaces is first copied to `backup`.
  """
  @spec step(map(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  # Freedesktop Trash: the .trashinfo is created first and exclusively, which
  # reserves the name; then the file moves to Trash/files under that name. The
  # reserved .trashinfo path is written to `marker` (in the plan's journal
  # folder), so after a crash `settle/3` knows exactly which Trash entry is ours.
  def step(%{op: :trash, path: path}, marker) do
    cond do
      not changeable?(path) ->
        {:error, "not allowed"}

      not File.exists?(path) ->
        {:error, "#{show(path)} no longer exists"}

      true ->
        {dest, info} = reserve_trash_name(path)
        File.mkdir_p!(Path.dirname(marker))
        File.write!(marker, info)

        case relocate(path, dest) do
          :ok ->
            {:ok, [%{"kind" => "trashed", "from" => path, "to" => dest, "info" => info}]}

          error ->
            File.rm(info)
            {:error, inspect(error)}
        end
    end
  end

  def step(%{op: :mkdir, path: path}, _backup) do
    if changeable?(path), do: {:ok, make_dirs(path)}, else: {:error, "not allowed"}
  end

  def step(%{op: op, from: from, to: to}, _backup) when op in [:move, :copy] do
    cond do
      not changeable?(to) or (op == :move and not changeable?(from)) -> {:error, "not allowed"}
      File.exists?(to) -> {:error, "#{show(to)} already exists"}
      not File.exists?(from) -> {:error, "#{show(from)} no longer exists"}
      true -> transfer(op, from, to)
    end
  end

  def step(%{op: :write, path: path, content: content, old_hash: old_hash}, backup) do
    cond do
      not changeable?(path) ->
        {:error, "not allowed"}

      hash_path(path) != old_hash ->
        {:error, "#{show(path)} changed since tiny-axe read it"}

      true ->
        backup =
          if File.regular?(path) do
            File.mkdir_p!(Path.dirname(backup))
            File.cp!(path, backup)
            backup
          end

        dirs = make_dirs(Path.dirname(path))

        case atomic_write(path, content) do
          :ok ->
            {:ok,
             [
               %{"kind" => "wrote", "path" => path, "hash" => hash(content), "backup" => backup}
               | dirs
             ]}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end

  defp transfer(op, from, to) do
    dirs = make_dirs(Path.dirname(to))

    result =
      case op do
        # rename fails across filesystems; fall back to copy, then remove.
        :move ->
          with {:error, :exdev} <- File.rename(from, to),
               {:ok, _} <- File.cp_r(from, to),
               {:ok, _} <- File.rm_rf(from),
               do: :ok

        :copy ->
          with {:ok, _} <- File.cp_r(from, to), do: :ok
      end

    case result do
      :ok when op == :move -> {:ok, [%{"kind" => "moved", "from" => from, "to" => to} | dirs]}
      :ok -> {:ok, [%{"kind" => "copied", "path" => to, "hash" => hash_path(to)} | dirs]}
      {:error, reason} -> {:error, inspect(reason)}
      {:error, reason, _file} -> {:error, inspect(reason)}
    end
  end

  # Creates missing folders, returning a record for each, deepest first.
  defp make_dirs(dir) do
    missing =
      dir
      |> Stream.iterate(&Path.dirname/1)
      |> Enum.take_while(&(not File.exists?(&1)))

    File.mkdir_p!(dir)
    Enum.map(missing, &%{"kind" => "made_dir", "path" => &1})
  end

  defp atomic_write(path, content) do
    tmp = path <> ".tiny_axe_tmp"

    with :ok <- File.write(tmp, content), :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  @doc """
  Works out how far a step got when tiny-axe stopped in the middle of it.
  Returns the undo records for whatever it did, plus notes for the user.
  Anything half-made (a partial copy) goes to `trash`.
  """
  @spec settle(map(), String.t(), String.t()) :: {:done | :not_done, [map()], [String.t()]}
  def settle(%{op: :trash, path: path}, marker, trash) do
    with {:ok, info} <- File.read(marker) do
      dest =
        Path.join([Path.dirname(Path.dirname(info)), "files", Path.basename(info, ".trashinfo")])

      record = %{"kind" => "trashed", "from" => path, "to" => dest, "info" => info}

      case {File.exists?(path), File.exists?(dest)} do
        {false, true} ->
          {:done, [record], []}

        {true, false} ->
          File.rm(info)
          {:not_done, [], []}

        {true, true} ->
          # A copy into the Trash across filesystems stopped partway; the original is intact.
          File.rm(info)
          {:not_done, [], trash_notes(dest, trash, "a partial copy in the Trash")}

        {false, false} ->
          {:not_done, [], ["#{show(path)} is missing and isn't in the Trash"]}
      end
    else
      # The step never reserved a Trash entry, so it never started moving anything.
      {:error, _} -> {:not_done, [], []}
    end
  end

  def settle(%{op: :mkdir, path: path}, _backup, _trash) do
    if File.dir?(path),
      do: {:done, [%{"kind" => "made_dir", "path" => path}], []},
      else: {:not_done, [], []}
  end

  def settle(%{op: op, from: from, to: to}, _backup, trash) do
    case {File.exists?(from), File.exists?(to)} do
      {false, true} when op == :move ->
        {:done, [%{"kind" => "moved", "from" => from, "to" => to}], []}

      {true, false} ->
        {:not_done, [], []}

      {true, true} ->
        # A copy (or a move across filesystems) stopped partway; the source is intact.
        notes = trash_notes(to, trash, "a partial #{op} at #{show(to)}")
        {:not_done, [], notes}

      {false, false} ->
        {:not_done, [], ["#{show(from)} is missing and was never moved to #{show(to)}"]}
    end
  end

  def settle(%{op: :write, path: path, content: content}, backup, _trash) do
    File.rm(path <> ".tiny_axe_tmp")

    if hash_path(path) == hash(content) do
      backup = if File.exists?(backup), do: backup

      {:done, [%{"kind" => "wrote", "path" => path, "hash" => hash(content), "backup" => backup}],
       []}
    else
      {:not_done, [], []}
    end
  end

  @doc """
  Reverses one undo record. Anything changed since it was made is left alone;
  files it takes away go to `trash` rather than being deleted. Returns notes
  for anything it couldn't undo.
  """
  @spec undo_record(map(), String.t()) :: [String.t()]
  def undo_record(%{"kind" => "trashed", "from" => from, "to" => to, "info" => info}, _trash) do
    cond do
      File.exists?(from) ->
        ["#{show(from)} exists again, so its trashed copy was left in the Trash"]

      not File.exists?(to) ->
        [
          "#{show(from)} is no longer in the Trash (emptied or restored), so it couldn't be put back"
        ]

      true ->
        File.mkdir_p!(Path.dirname(from))

        case relocate(to, from) do
          :ok ->
            File.rm(info)
            []

          error ->
            ["couldn't take #{show(from)} out of the Trash: #{inspect(error)}"]
        end
    end
  end

  def undo_record(%{"kind" => "moved", "from" => from, "to" => to}, _trash) do
    cond do
      File.exists?(from) -> ["#{show(from)} exists again, so #{show(to)} was left where it is"]
      not File.exists?(to) -> ["#{show(to)} is gone, so it couldn't be moved back"]
      true -> File.mkdir_p!(Path.dirname(from)) && note(File.rename(to, from), to)
    end
  end

  def undo_record(%{"kind" => "copied", "path" => path, "hash" => digest}, trash) do
    if hash_path(path) == digest,
      do: trash_notes(path, trash, nil),
      else: ["#{show(path)} changed since it was copied, so it was kept"]
  end

  def undo_record(%{"kind" => "wrote", "path" => path, "hash" => digest} = r, trash) do
    cond do
      hash_path(path) != digest ->
        ["#{show(path)} changed since it was written, so it was kept"]

      r["backup"] == nil ->
        trash_notes(path, trash, nil)

      true ->
        # Keep the version being undone too, in case the user wanted it after all.
        _ = trash_notes(path, trash, nil)
        note(File.cp(r["backup"], path), path)
    end
  end

  # Only removed if empty, so nothing put there since is lost.
  def undo_record(%{"kind" => "made_dir", "path" => dir}, _trash) do
    case File.rmdir(dir) do
      :ok -> []
      {:error, :enoent} -> []
      {:error, _} -> ["folder #{show(dir)} isn't empty, so it was kept"]
    end
  end

  # Moves a path into tiny-axe's trash, keeping its place relative to the root.
  defp trash_notes(path, trash, label) do
    rel =
      if inside?(path, root()),
        do: Path.relative_to(path, root()),
        else: String.trim_leading(show(path), "~/") |> String.trim_leading("/")

    dest = Path.join(trash, rel)
    File.mkdir_p!(Path.dirname(dest))
    dest = unique(dest)

    result =
      with {:error, :exdev} <- File.rename(path, dest),
           {:ok, _} <- File.cp_r(path, dest),
           {:ok, _} <- File.rm_rf(path),
           do: :ok

    case {result, label} do
      {:ok, nil} -> []
      {:ok, label} -> ["moved #{label} to #{show(dest)}"]
      {error, _} -> ["couldn't move #{show(path)} to the trash: #{inspect(error)}"]
    end
  end

  defp unique(path) do
    if File.exists?(path), do: unique(path <> "~"), else: path
  end

  defp note(:ok, _path), do: []
  defp note({:error, reason}, path), do: ["couldn't undo #{show(path)}: #{inspect(reason)}"]
  defp note({:ok, _}, _path), do: []

  @doc "Hex SHA-256 of a string."
  @spec hash(String.t()) :: String.t()
  def hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  @doc "Hash of a file's contents; a folder hashes its sorted listing; nil if missing."
  @spec hash_path(String.t()) :: String.t() | nil
  def hash_path(path) do
    cond do
      File.regular?(path) ->
        path |> File.read!() |> hash()

      File.dir?(path) ->
        path
        |> Path.join("**")
        |> Path.wildcard(match_dot: true)
        |> Enum.map_join("\n", &Path.relative_to(&1, path))
        |> hash()

      true ->
        nil
    end
  end

  ## The system Trash

  defp reserve_trash_name(path, n \\ 0) do
    files = Path.join(trash_dir(), "files")
    info_dir = Path.join(trash_dir(), "info")
    File.mkdir_p!(files)
    File.mkdir_p!(info_dir)

    base = Path.basename(path)
    name = if n == 0, do: base, else: "#{Path.rootname(base)}.#{n}#{Path.extname(base)}"
    info = Path.join(info_dir, name <> ".trashinfo")
    dest = Path.join(files, name)

    with false <- File.exists?(dest),
         {:ok, io} <- File.open(info, [:write, :exclusive]) do
      date =
        NaiveDateTime.local_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()

      path_url = URI.encode(path, &(URI.char_unreserved?(&1) or &1 == ?/))
      IO.binwrite(io, "[Trash Info]\nPath=#{path_url}\nDeletionDate=#{date}\n")
      File.close(io)
      {dest, info}
    else
      _taken -> reserve_trash_name(path, n + 1)
    end
  end

  # rename, or copy then remove when it's on another filesystem.
  defp relocate(from, to) do
    with {:error, :exdev} <- File.rename(from, to),
         {:ok, _} <- File.cp_r(from, to),
         {:ok, _} <- File.rm_rf(from),
         do: :ok
  end

  # A folder's file count is shown in the plan, so the size of what goes is clear.
  defp trash_op(path) do
    if File.dir?(path) do
      n =
        path |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.count(&File.regular?/1)

      %{op: :trash, path: path, folder: true, items: n}
    else
      %{op: :trash, path: path, folder: false, items: 1}
    end
  end
end
