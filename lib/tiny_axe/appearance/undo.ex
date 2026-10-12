defmodule TinyAxe.Appearance.Undo do
  @moduledoc """
  What appearance changes did, kept on disk (`<state_dir>/appearance-undo.json`,
  the last #{20}), so `/look undo` can put the newest one back, even after a
  restart.

  Each record is one request's changes: per setting, the value before and
  after, and for settings kept in a config file, the file's whole content
  from before. Undo puts that content back when the file still holds what
  tiny-axe wrote (nothing else changed it since); otherwise, and for
  settings set by a command, it sets the value from before again. A setting
  with no readable value (an `:action`) is done once more.
  """

  alias TinyAxe.Appearance.{ConfigFiles, Settings}

  @keep 20

  def path, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "appearance-undo.json")

  @doc "Records one request's changes (newest first)."
  @spec push(String.t(), [map()]) :: :ok
  def push(_request, []), do: :ok

  def push(request, changes) do
    record = %{
      "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "request" => request,
      "changes" => changes
    }

    save(Enum.take([record | load()], @keep))
  end

  @doc "The records, newest first."
  @spec load() :: [map()]
  def load do
    with {:ok, text} <- File.read(path()),
         {:ok, list} when is_list(list) <- JSON.decode(text) do
      list
    else
      _ -> []
    end
  end

  @doc """
  Puts the newest record's changes back, newest change first. Returns
  `{:ok, record, results}` (`results` is `[{setting_id, :ok | {:error, why}}]`)
  or `:empty`. The record is dropped once tried.
  """
  @spec undo_last() :: {:ok, map(), list()} | :empty
  def undo_last do
    case load() do
      [] ->
        :empty

      [record | rest] ->
        results = record["changes"] |> Enum.reverse() |> Enum.map(&revert/1)
        save(rest)
        {:ok, record, results}
    end
  end

  defp revert(%{"setting" => id} = change) do
    setting = Settings.get(id)

    result =
      cond do
        setting == nil ->
          {:error, "tiny-axe no longer knows the setting #{id}"}

        file_unchanged?(change) ->
          ConfigFiles.restore(change["file"], change["before"])

        setting.kind == :action ->
          setting.apply.("now")

        is_binary(change["from"]) ->
          case setting.apply.(change["from"]) do
            {:ok, _before} -> :ok
            other -> other
          end

        true ->
          {:error, "the value from before wasn't known"}
      end

    {id, result}
  end

  defp file_unchanged?(%{"file" => file, "before" => before, "after_hash" => hash})
       when is_binary(file) and is_binary(before) do
    case File.read(file) do
      {:ok, now} -> hash(now) == hash
      _ -> false
    end
  end

  defp file_unchanged?(_), do: false

  @doc false
  def hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp save(list) do
    File.mkdir_p!(Path.dirname(path()))
    tmp = path() <> ".tmp"
    File.write!(tmp, JSON.encode!(list))
    File.rename!(tmp, path())
    :ok
  end
end
