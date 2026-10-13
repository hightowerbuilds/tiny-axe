defmodule TinyAxe.TUI.PinFlow do
  @moduledoc """
  `/remote pin`: setting the approval PIN for the site's Chat tab
  (`TinyAxe.Remote.Approvals`), in a popup, typed twice. Each keystroke goes
  straight to `Approvals`; this flow (and so the TUI's state) only knows how
  many characters there are.
  """

  alias TinyAxe.Remote.Approvals
  import TinyAxe.TUI.Conversation, only: [add_meta: 2]

  @doc "Opens the popup."
  def open(state) do
    Approvals.start_entry()

    %{
      state
      | pin_flow: %{step: :first, length: 0, error: nil},
        status: "setting the approval PIN…"
    }
  end

  @doc "A key: the TUI's next state."
  def key(state, "esc") do
    Approvals.discard_entry()
    %{state | pin_flow: nil, status: "ready"} |> add_meta("🔐 approval PIN unchanged")
  end

  def key(%{pin_flow: %{step: :first} = flow} = state, "enter") do
    case Approvals.entry_next() do
      :ok -> %{state | pin_flow: %{flow | step: :again, length: 0, error: nil}}
      {:error, why} -> %{state | pin_flow: %{flow | length: 0, error: why}}
    end
  end

  def key(%{pin_flow: %{step: :again}} = state, "enter") do
    case Approvals.entry_finish() do
      :ok ->
        %{state | pin_flow: nil, status: "ready"}
        |> add_meta(
          "🔐 approval PIN set: the Chat tab can approve purchases, tool calls, sending to " <>
            "Claude and sandboxed commands with it. 3 wrong tries switch approvals off. " <>
            "/remote approvals off stops them."
        )

      {:error, why} ->
        Approvals.start_entry()
        %{state | pin_flow: %{step: :first, length: 0, error: "#{why}; start again"}}
    end
  end

  def key(%{pin_flow: flow} = state, code) do
    %{state | pin_flow: %{flow | length: Approvals.entry_key(code), error: nil}}
  end

  @doc "What the popup says."
  def lines(%{step: step, length: n, error: error}) do
    [
      if(step == :first,
        do: "Type an approval PIN (6 to 64 characters), then enter.",
        else: "Type it again, then enter."
      ),
      "",
      "  " <> String.duplicate("•", n),
      "",
      error && "✗ " <> error,
      "The Chat tab asks for it to approve anything. tiny-axe keeps only a hash, in your keyring.",
      "esc cancels"
    ]
    |> Enum.reject(&is_nil/1)
  end
end
