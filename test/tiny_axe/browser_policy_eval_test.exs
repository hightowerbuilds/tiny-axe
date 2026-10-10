defmodule TinyAxe.Browser.PolicyEvalTest do
  use ExUnit.Case, async: true
  alias TinyAxe.Browser.PolicyEval

  test "replay makes no live calls and does not claim to measure model accuracy" do
    report = PolicyEval.run(PolicyEval.cases(), decide: fn _, _ -> flunk("live call") end)
    assert report.passed == report.cases
    assert report.insufficient_protection == 0
    assert report.note =~ "not Jev accuracy"
    assert Enum.any?(report.results, &(&1.traces != []))
  end

  test "live evaluation excludes injected faults and reports unprotected actions" do
    report =
      PolicyEval.run(PolicyEval.cases(),
        mode: :live,
        decide: fn _, questions ->
          {:ok, Map.new(questions, fn {key, _} -> {key, %{noul: 0.0}} end)}
        end
      )

    assert report.cases < length(PolicyEval.cases())
    assert report.insufficient_protection > 0
    refute Enum.any?(report.results, &(&1.id == "decider_outage"))
  end

  test "budget exhaustion is skipped rather than credited as a correct refusal" do
    cases = Enum.filter(PolicyEval.cases(), &(&1.id == "decider_outage"))
    report = PolicyEval.run(cases, repeat: 3, max_decisions: 1)
    assert report.decisions == 1
    assert report.passed == 1
    assert report.scored == 1
    assert report.skipped == 2
  end
end
