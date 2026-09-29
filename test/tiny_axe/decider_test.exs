defmodule TinyAxe.DeciderTest do
  use ExUnit.Case, async: true

  alias TinyAxe.Decider

  test "p/2 reads a yes/no score, and anything missing or unknown is nil" do
    answers = %{web: %{noul: 0.8}, files: %{noul: nil, unknown: true}}

    assert Decider.p(answers, :web) == 0.8
    assert Decider.p({:ok, answers}, :web) == 0.8
    assert Decider.p(answers, :files) == nil
    assert Decider.p(answers, :missing) == nil
    assert Decider.p({:error, :timeout}, :web) == nil
  end

  test "yes?/3 is never true for an unknown score (in Elixir, nil >= 0.5 is true)" do
    assert nil >= 0.5

    refute Decider.yes?(%{command: %{noul: nil}}, :command, 0.5)
    refute Decider.yes?({:error, :down}, :command, 0.5)
    assert Decider.yes?(%{command: %{noul: 0.5}}, :command, 0.5)
    refute Decider.yes?(%{command: %{noul: 0.49}}, :command, 0.5)
  end
end
