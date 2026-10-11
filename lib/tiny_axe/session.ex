defmodule TinyAxe.Session do
  @moduledoc """
  Keeps the conversations (what each chat's transcript shows and the history
  sent to the model) outside the TUI process, so a crash in the TUI loses
  nothing: the supervisor restarts it and it picks up where it was.

  The TUI saves after every change; a restarted TUI restores on mount and, if
  the last one crashed, says so. The chat on screen is also kept at the top
  level (`history`, `transcript`, `summary`), as when there was only one.
  """

  use Agent

  @type chat :: %{history: [map()], transcript: list(), summary: map() | nil}

  def start_link(_opts),
    do:
      Agent.start_link(
        fn ->
          %{history: [], transcript: [], summary: nil, crashed: nil, chats: nil, active: 0}
        end,
        name: __MODULE__
      )

  @doc "Saves a single conversation."
  @spec save([map()], list(), map() | nil) :: :ok
  def save(history, transcript, summary),
    do: save_chats([%{history: history, transcript: transcript, summary: summary}], 0)

  @doc "Saves every chat, in order, and which one is on screen (from 0)."
  @spec save_chats([chat()], non_neg_integer()) :: :ok
  def save_chats(chats, active) do
    shown = Map.take(Enum.at(chats, active), [:history, :transcript, :summary, :saved_as])
    Agent.cast(__MODULE__, &Map.merge(&1, Map.merge(shown, %{chats: chats, active: active})))
  end

  @doc "Records why the TUI crashed, for the next one to report."
  @spec crashed(term()) :: :ok
  def crashed(reason), do: Agent.cast(__MODULE__, &Map.put(&1, :crashed, reason))

  @doc """
  The saved chats and the one on screen (its conversation also at the top
  level), and the crash reason if the last TUI crashed (cleared once read).
  """
  @spec restore() :: %{
          history: [map()],
          transcript: list(),
          summary: map() | nil,
          chats: [chat()],
          active: non_neg_integer(),
          crashed: term()
        }
  def restore do
    saved = Agent.get_and_update(__MODULE__, &{&1, Map.put(&1, :crashed, nil)})
    shown = Map.take(saved, [:history, :transcript, :summary, :saved_as])

    # Saved before there were several chats: just the one.
    case saved do
      %{chats: [_ | _], active: active} when is_integer(active) -> saved
      _ -> Map.merge(saved, %{chats: [shown], active: 0})
    end
  end
end
