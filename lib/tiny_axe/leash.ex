defmodule TinyAxe.Leash do
  @moduledoc """
  The leash (`docs/plan-leash.md`): while it's on, for this session, every
  browser action that isn't the final purchase runs without asking, in
  tiny-axe's browser and the user's Chrome, on any site; and an order whose
  checks all pass is placed without asking (`TinyAxe.Tools.Gate`). Off at
  each start; `/leash on|off` in the TUI.

  It never covers shell commands, other servers' outward tools, a card
  locked with a PIN, or the 🌐 remote chat: a gate task is leashed only when
  it was opened with `leash: true` (the TUI's own chats) and the leash is on.
  """

  @key {__MODULE__, :on}

  @doc "Whether the leash is on."
  @spec on?() :: boolean()
  def on?, do: :persistent_term.get(@key, false)

  @doc "Turns it on or off for this session."
  @spec set(boolean()) :: :ok
  def set(on) when is_boolean(on), do: :persistent_term.put(@key, on)

  @doc "Whether a gate task runs on the leash now."
  @spec leashed?(map()) :: boolean()
  def leashed?(task), do: task[:leash] == true and on?()
end
