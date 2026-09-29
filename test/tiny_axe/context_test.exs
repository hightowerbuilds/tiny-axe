defmodule TinyAxe.ContextTest do
  use ExUnit.Case, async: true

  alias TinyAxe.{Compactor, Context}

  test "estimates from characters and recalibrates from measured requests" do
    assert Context.estimate(String.duplicate("a", 1000), 0.25) == 250

    ratio = Context.calibrate(0.28, %{prompt_tokens: 1217, prompt_chars: 6847, output_tokens: 3})
    assert_in_delta ratio, 0.5 * 0.28 + 0.5 * (1217 / 6847), 1.0e-9

    # Tiny prompts say little about the ratio, so they're ignored.
    assert Context.calibrate(0.28, %{prompt_tokens: 20, prompt_chars: 50, output_tokens: 1}) ==
             0.28
  end

  test "compacts once the conversation reaches half the window" do
    window = Context.window()
    refute Context.compact?(div(window, 2) - 1)
    assert Context.compact?(div(window, 2))
  end

  test "short token counts" do
    assert Context.short(830) == "830"
    assert Context.short(4_712) == "4.7k"
    assert Context.short(12_400) == "12k"
  end

  test "keeps the newest two turns and compacts the rest" do
    history =
      for i <- 1..5, role <- ~w(user assistant), do: %{role: role, content: "#{role} #{i}"}

    {old, recent} = Compactor.split(history)

    assert length(old) == 6
    assert Enum.map(recent, & &1.content) == ["user 4", "assistant 4", "user 5", "assistant 5"]
    assert Compactor.split(Enum.take(history, 4)) == {[], Enum.take(history, 4)}
  end
end
