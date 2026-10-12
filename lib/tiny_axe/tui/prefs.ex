defmodule TinyAxe.TUI.Prefs do
  @moduledoc """
  The TUI's own choices that outlast a session (`/route on|off`), in
  `<state_dir>/tui.json`. A missing or broken file gives the defaults.
  """

  @defaults %{"route_line" => false}

  @doc "One choice, or its default."
  @spec get(String.t()) :: term()
  def get(key), do: Map.get(read(), key, @defaults[key])

  @doc "Remembers one choice."
  @spec put(String.t(), term()) :: :ok | {:error, term()}
  def put(key, value) do
    with :ok <- File.mkdir_p(Path.dirname(path())),
         do: File.write(path(), JSON.encode!(Map.put(read(), key, value)))
  end

  def path, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "tui.json")

  defp read do
    with {:ok, text} <- File.read(path()),
         {:ok, %{} = prefs} <- JSON.decode(text),
         do: prefs,
         else: (_ -> %{})
  end
end
