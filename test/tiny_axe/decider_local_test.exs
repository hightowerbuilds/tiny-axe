defmodule TinyAxe.Decider.LocalTest do
  use ExUnit.Case, async: true

  alias TinyAxe.Decider.Local

  test "sums case/whitespace variants of a label and renormalises" do
    top = [
      %{"token" => "Yes", "logprob" => :math.log(0.6)},
      %{"token" => " yes", "logprob" => :math.log(0.1)},
      %{"token" => "No", "logprob" => :math.log(0.1)},
      %{"token" => "The", "logprob" => :math.log(0.2)}
    ]

    {dist, coverage} = Local.label_distribution(top, ["Yes", "No"])

    assert_in_delta coverage, 0.8, 1.0e-9
    assert_in_delta dist["Yes"], 0.875, 1.0e-9
    assert_in_delta dist["No"], 0.125, 1.0e-9
  end

  test "falls back to uniform when no label appears" do
    {dist, coverage} = Local.label_distribution([%{"token" => "Hmm", "logprob" => 0.0}], ~w(A B))
    assert coverage == 0.0
    assert dist == %{"A" => 0.5, "B" => 0.5}
  end
end
