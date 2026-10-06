defmodule TinyAxe.Ops.Executor do
  @moduledoc """
  Carries out approved operations and produces the journal's undo records.
  Path and stale-file checks happen again here, immediately before mutation.
  Also owns system Trash reservations and cross-filesystem moves, which recovery
  reuses when restoring a trashed file.
  """

  import TinyAxe.Ops.Paths, only: [changeable?: 1, show: 1]
  alias TinyAxe.Ops.Fingerprint

  @doc """
  The system Trash, per the freedesktop.org spec, so trashed files show up in
  the file manager's Trash: `config :tiny_axe, :trash_dir`, or `$XDG_DATA_HOME/Trash`.
  """
  @spec trash_dir() :: String.t()
  def trash_dir do
    Application.get_env(:tiny_axe, :trash_dir) ||
      Path.join(System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"), "Trash")
  end

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
        with {:ok, dest, info} <- reserve_trash_name(path) do
          result =
            with :ok <- File.mkdir_p(Path.dirname(marker)),
                 :ok <- File.write(marker, info),
                 do: relocate(path, dest)

          case result do
            :ok ->
              {:ok, [%{"kind" => "trashed", "from" => path, "to" => dest, "info" => info}]}

            error ->
              File.rm(info)
              {:error, inspect(error)}
          end
        else
          error -> {:error, inspect(error)}
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

      Fingerprint.path(path) != old_hash ->
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
               %{
                 "kind" => "wrote",
                 "path" => path,
                 "hash" => Fingerprint.hash(content),
                 "backup" => backup
               }
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
          relocate(from, to)

        :copy ->
          with {:ok, _} <- File.cp_r(from, to), do: :ok
      end

    case result do
      :ok when op == :move -> {:ok, [%{"kind" => "moved", "from" => from, "to" => to} | dirs]}
      :ok -> {:ok, [%{"kind" => "copied", "path" => to, "hash" => Fingerprint.path(to)} | dirs]}
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
  Moves a path to the system Trash (with its `.trashinfo`), for things
  tiny-axe itself is discarding, like an old plan's own trash.
  """
  @spec discard(String.t()) :: :ok | {:error, term()}
  def discard(path) do
    with {:ok, dest, info} <- reserve_trash_name(path) do
      case relocate(path, dest) do
        :ok ->
          :ok

        error ->
          File.rm(info)
          error
      end
    end
  end

  defp reserve_trash_name(path) do
    files = Path.join(trash_dir(), "files")
    info_dir = Path.join(trash_dir(), "info")

    with :ok <- File.mkdir_p(files),
         :ok <- File.mkdir_p(info_dir),
         do: reserve_trash_name(path, files, info_dir, 0)
  end

  defp reserve_trash_name(path, files, info_dir, n) do
    base = Path.basename(path)
    name = if n == 0, do: base, else: "#{Path.rootname(base)}.#{n}#{Path.extname(base)}"
    info = Path.join(info_dir, name <> ".trashinfo")
    dest = Path.join(files, name)

    with false <- File.exists?(dest),
         {:ok, io} <- File.open(info, [:write, :exclusive]) do
      date =
        NaiveDateTime.local_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()

      path_url = URI.encode(path, &(URI.char_unreserved?(&1) or &1 == ?/))
      written = IO.binwrite(io, "[Trash Info]\nPath=#{path_url}\nDeletionDate=#{date}\n")
      closed = File.close(io)

      case {written, closed} do
        {:ok, :ok} ->
          {:ok, dest, info}

        {written, closed} ->
          File.rm(info)
          if written == :ok, do: closed, else: written
      end
    else
      true -> reserve_trash_name(path, files, info_dir, n + 1)
      {:error, :eexist} -> reserve_trash_name(path, files, info_dir, n + 1)
      {:error, _} = error -> error
    end
  end

  @doc "Moves a path, falling back to copy then remove across filesystems."
  @spec relocate(String.t(), String.t()) :: :ok | {:error, term()} | {:error, term(), String.t()}
  def relocate(from, to) do
    with {:error, :exdev} <- File.rename(from, to),
         {:ok, _} <- File.cp_r(from, to),
         {:ok, _} <- File.rm_rf(from),
         do: :ok
  end
end
