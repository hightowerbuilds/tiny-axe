defmodule TinyAxe.Ops.Plan do
  @moduledoc """
  Expands model proposals and simulates their effects before execution.
  This module reads the filesystem but never mutates it. Both initial planning
  and recovery use the same validation through expand/1 and recheck/1.
  """

  import TinyAxe.Ops.Paths, only: [resolve: 1, changeable?: 1, show: 1, root: 0]
  alias TinyAxe.Ops.Fingerprint

  @type op :: TinyAxe.Ops.op()
  @max_ops 200

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

      old_hash != :unknown and fs[path] == nil and Fingerprint.path(path) != old_hash ->
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
