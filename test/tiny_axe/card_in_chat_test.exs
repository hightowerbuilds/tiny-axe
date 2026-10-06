defmodule TinyAxe.CardInChatTest do
  @moduledoc """
  A card number typed into the prompt never reaches a model, and answers
  about tiny-axe say truthfully what it can do with purchases.
  """

  # Scripts the app-wide model and decider, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Decider, Model, Pipeline, TUI}

  @keys ~w(model_backend decider script_model script_decider code_check web_search purchases)a

  setup do
    previous = Map.new(@keys, &{&1, Application.get_env(:tiny_axe, &1)})
    me = self()

    Model.Script.script(fn messages, _ ->
      send(me, {:model_saw, messages})
      "An answer."
    end)

    Decider.Script.script(fn
      :addresses, _, _ -> 0.95
      _, _, _ -> nil
    end)

    Application.put_env(:tiny_axe, :code_check, false)
    Application.put_env(:tiny_axe, :web_search, false)

    on_exit(fn ->
      for {k, v} <- previous,
          do:
            if(v == nil,
              do: Application.delete_env(:tiny_axe, k),
              else: Application.put_env(:tiny_axe, k, v)
            )
    end)
  end

  test "a card number typed into the prompt is removed before anything sees it" do
    {:ok, state} = TUI.mount(test_mode: {120, 30})
    ExRatatui.textarea_set_value(state.input, "here's my card: 4111 1111 1111 1111, exp 12/30")

    {:noreply, state} =
      TUI.handle_event(%ExRatatui.Event.Key{code: "enter", kind: "press", modifiers: []}, state)

    assert {:user, "here's my card: [card number removed], exp 12/30"} in state.transcript
    assert state.pending_prompt =~ "[card number removed]"
    assert Enum.any?(state.transcript, &match?({:meta, "🔒 removed a card number" <> _}, &1))

    # Nor does the model.
    assert_receive {:model_saw, messages}, 5_000
    refute inspect(messages, limit: :infinity) =~ "4111"
  end

  test "an answer knows what tiny-axe can do with purchases, and whether they're on" do
    Application.put_env(:tiny_axe, :purchases, enabled: false)
    Pipeline.run([], "can I give you my credit card to buy things?", fn _ -> :ok end)
    assert_receive {:model_saw, [%{role: "system", content: system} | _]}

    assert system =~ "It can buy things for the user: Purchases are OFF"
    assert system =~ "Card details are never typed into this chat"
    assert system =~ "No model, including you, ever sees it"

    Application.put_env(:tiny_axe, :purchases, enabled: true)
    Pipeline.run([], "can I buy things?", fn _ -> :ok end)
    assert_receive {:model_saw, [%{role: "system", content: system} | _]}
    assert system =~ "Purchases are ON"
  end
end
