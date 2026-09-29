defmodule TinyAxe.Session do
  @moduledoc """
  Keeps the conversation (what the transcript shows and the history sent to
  the model) outside the TUI process, so a crash in the TUI loses nothing: the
  supervisor restarts it and it picks up where it was.

  The TUI saves after every change; a restarted TUI restores on mount and, if
  the last one crashed, says so.
  """

  use Agent

  def start_link(_opts),
    do: Agent.start_link(fn -> %{history: [], transcript: [], crashed: nil} end, name: __MODULE__)

  @spec save([map()], list()) :: :ok
  def save(history, transcript),
    do: Agent.cast(__MODULE__, &%{&1 | history: history, transcript: transcript})

  @doc "Records why the TUI crashed, for the next one to report."
  @spec crashed(term()) :: :ok
  def crashed(reason), do: Agent.cast(__MODULE__, &%{&1 | crashed: reason})

  @doc "The saved conversation, and the crash reason if the last TUI crashed (cleared once read)."
  @spec restore() :: %{history: [map()], transcript: list(), crashed: term()}
  def restore, do: Agent.get_and_update(__MODULE__, &{&1, %{&1 | crashed: nil}})
end
