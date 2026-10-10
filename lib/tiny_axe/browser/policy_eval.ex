defmodule TinyAxe.Browser.PolicyEval do
  @moduledoc """
  A bounded classification benchmark over synthetic browser observations.
  Replay tests policy composition with supplied answers. Live mode uses the
  configured decider and excludes injected faults. Neither executes actions.
  """

  alias TinyAxe.Decider
  alias TinyAxe.Tools.BrowserPolicy

  def cases(path \\ "eval/browser_policy_cases.exs") do
    {cases, _} = Code.eval_file(path)
    cases
  end

  def run(cases, opts \\ []) do
    mode = Keyword.get(opts, :mode, :replay)
    repeat = Keyword.get(opts, :repeat, 1)
    budget = Keyword.get(opts, :max_decisions, 40)
    decide = Keyword.get(opts, :decide, &Decider.decide_traced/2)

    unless mode in [:replay, :live] and repeat in 1..20 and budget in 1..1000,
      do: raise(ArgumentError, "expected mode replay/live, repeat 1..20, max_decisions 1..1000")

    selected = Enum.reject(cases, &(mode == :live and Map.get(&1, :fault, false)))
    ref = make_ref()
    Process.put(ref, %{calls: 0, traces: [], records: [], exhausted: false})

    try do
      results =
        for iteration <- 1..repeat, scenario <- selected do
          before = Process.get(ref).calls
          Process.put(ref, %{Process.get(ref) | traces: [], records: [], exhausted: false})
          start = System.monotonic_time(:millisecond)

          judge = fn state, questions ->
            run = Process.get(ref)

            if run.calls >= budget do
              Process.put(ref, %{run | exhausted: true})
              {:error, :evaluation_budget_exhausted}
            else
              reply =
                if mode == :replay,
                  do: replay(scenario.answers, questions),
                  else: decide.(state, questions)

              trace = %{state: state, questions: questions, result: reply}
              Process.put(ref, %{run | calls: run.calls + 1, traces: [trace | run.traces]})
              reply
            end
          end

          {actual, reason} =
            BrowserPolicy.classify(
              scenario.tool,
              scenario.args,
              fn _ -> scenario.target end,
              decide: judge,
              context: Map.get(scenario, :context),
              on_decision: fn record ->
                run = Process.get(ref)
                Process.put(ref, %{run | records: [record | run.records]})
              end
            )

          run = Process.get(ref)

          %{
            id: scenario.id,
            iteration: iteration,
            expected: scenario.expected,
            actual: actual,
            reason: reason,
            skipped: run.exhausted,
            passed: not run.exhausted and actual == scenario.expected,
            insufficient_protection: not run.exhausted and weaker?(actual, scenario.expected),
            decisions: run.calls - before,
            traces: Enum.reverse(run.traces),
            # What the gate would journal: evidence, versions, answers, disposition.
            records: Enum.reverse(run.records),
            ms: System.monotonic_time(:millisecond) - start
          }
        end

      scored = Enum.reject(results, & &1.skipped)

      %{
        schema_version: 2,
        mode: mode,
        note:
          if(mode == :replay,
            do: "Scripted control-flow replay; not Jev accuracy.",
            else: "Synthetic observations with a real decider; no browser actions executed."
          ),
        cases: length(results),
        scored: length(scored),
        passed: Enum.count(scored, & &1.passed),
        skipped: length(results) - length(scored),
        insufficient_protection: Enum.count(scored, & &1.insufficient_protection),
        decisions: Process.get(ref).calls,
        results: results
      }
    after
      Process.delete(ref)
    end
  end

  defp replay(:error, _questions), do: {:error, :injected_outage}

  defp replay(answers, questions) do
    {:ok,
     Map.new(questions, fn {key, _} ->
       answer =
         case answers[key] do
           p when is_number(p) -> %{noul: p}
           _ -> %{noul: nil, unknown: true}
         end

       {key, answer}
     end)}
  end

  defp weaker?(:refused, _), do: false
  defp weaker?(actual, :commit), do: actual != :commit
  defp weaker?(actual, :outward), do: actual in [:read, :local]
  defp weaker?(_actual, :refused), do: true
  defp weaker?(_, _), do: false
end
