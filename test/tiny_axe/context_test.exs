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

  describe "fit/2 (harness F5: every request fits the window)" do
    defp msg(role, chars), do: %{role: role, content: String.duplicate("x", chars)}
    defp tokens(messages), do: Context.conversation_tokens(messages, 0.33)

    test "a request that fits is left alone" do
      messages = [msg("system", 500), msg("user", 100)]
      assert {^messages, nil} = Context.fit(messages, budget: 5_000)
    end

    test "oversized material is cut to fit; the system prompt and the request never are" do
      messages = [msg("system", 800), msg("system", 30_000), msg("user", 200)]
      {fitted, cut} = Context.fit(messages, budget: 3_000)

      assert tokens(fitted) <= 3_000
      assert cut.cut == ["attached material"]
      assert hd(fitted) == hd(messages)
      assert List.last(fitted) == List.last(messages)
      assert Enum.at(fitted, 1).content =~ "cut to fit the model's context window"
    end

    test "old turns go only when trimming material isn't enough, keeping the newest two" do
      history =
        for i <- 1..6,
            role <- ~w(user assistant),
            do: %{role: role, content: "#{role} #{i} " <> String.duplicate("y", 2_000)}

      messages = [msg("system", 500)] ++ history ++ [%{role: "user", content: "the request"}]
      {fitted, cut} = Context.fit(messages, budget: 3_500)

      assert "older turns" in cut.cut
      assert List.last(fitted).content == "the request"
      kept = Enum.filter(fitted, &(&1.role in ["user", "assistant"])) |> Enum.map(& &1.content)
      # The newest two turns survive whole.
      assert Enum.any?(kept, &String.starts_with?(&1, "user 6 "))
      assert Enum.any?(kept, &String.starts_with?(&1, "assistant 5 "))
      refute Enum.any?(kept, &String.starts_with?(&1, "user 1 "))
    end

    test "cutting stops at the floor instead of looping forever" do
      messages = [msg("system", 100), msg("system", 1_550), msg("user", 50)]
      assert {_fitted, _cut} = Context.fit(messages, budget: 10)
    end
  end
end
