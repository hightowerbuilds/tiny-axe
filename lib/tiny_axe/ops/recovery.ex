defmodule TinyAxe.Ops.Recovery do
  @moduledoc """
  Settles interrupted steps and reverses journaled operations.
  Records remain plain string-keyed maps so plans written by earlier releases
  can still be recovered. User changes are preserved when an undo check fails.
  """

  import TinyAxe.Ops.Paths, only: [inside?: 2, root: 0, show: 1]
  alias TinyAxe.Ops.{Executor, Fingerprint}

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

    if Fingerprint.path(path) == Fingerprint.hash(content) do
      backup = if File.exists?(backup), do: backup

      {:done,
       [
         %{
           "kind" => "wrote",
           "path" => path,
           "hash" => Fingerprint.hash(content),
           "backup" => backup
         }
       ], []}
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

        case Executor.relocate(to, from) do
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
    cond do
      Fingerprint.legacy_directory?(path, digest) ->
        [
          "#{show(path)} has an older folder fingerprint that cannot verify its contents, so it was kept"
        ]

      Fingerprint.matches?(path, digest) ->
        trash_notes(path, trash, nil)

      true ->
        ["#{show(path)} changed since it was copied or couldn't be checked, so it was kept"]
    end
  end

  def undo_record(%{"kind" => "wrote", "path" => path, "hash" => digest} = r, trash) do
    cond do
      not Fingerprint.matches?(path, digest) ->
        ["#{show(path)} changed since it was written, so it was kept"]

      r["backup"] == nil ->
        trash_notes(path, trash, nil)

      true ->
        # Move the version being undone aside first (the user may want it after
        # all); if that fails, leave everything as it is rather than overwrite it.
        case trash_notes(path, trash, nil) do
          [] -> note(File.cp(r["backup"], path), path)
          notes -> notes ++ ["#{show(path)} was left as it is, so nothing was lost"]
        end
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

    dest = unique(Path.join(trash, rel))

    # Failures come back as notes, never a crash mid-undo.
    result =
      with :ok <- File.mkdir_p(Path.dirname(dest)),
           do: Executor.relocate(path, dest)

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
end
