defmodule TinyAxe.EvalTest do
  @moduledoc "The evaluation runner, with a scripted model and decider."

  # Swaps the app-wide model, decider and folders, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Decider, Eval, Model}

  @keys ~w(model_backend decider script_model script_decider code_check web_search fs_root project_dir)a

  setup do
    previous = Map.new(@keys, &{&1, Application.get_env(:tiny_axe, &1)})

    on_exit(fn ->
      for {k, v} <- previous,
          do:
            if(v,
              do: Application.put_env(:tiny_axe, k, v),
              else: Application.delete_env(:tiny_axe, k)
            )
    end)

    Application.put_env(:tiny_axe, :code_check, false)
    Application.put_env(:tiny_axe, :web_search, false)
    :ok
  end

  defp routing(extra) do
    fn
      :kind, _, _ -> Map.get(extra, :kind, :question)
      key, _, _ -> Map.get(extra, key)
    end
  end

  test "an answer is checked for its facts, and the verifier's verdict is compared with them" do
    Model.Script.script(fn _, _ -> "OTP is the Open Platform." end)
    route = routing(%{})

    Decider.Script.script(fn
      :addresses, _, _ -> 0.95
      k, q, s -> route.(k, q, s)
    end)

    task = %{
      id: "q",
      category: :answer,
      split: :dev,
      prompt: "What does OTP stand for?",
      expect: [route: :answer, contains: ["Open Telecom Platform"]]
    }

    r = Eval.run_task(task)
    refute r.passed
    assert [%{ok: true}, %{ok: false, why: "missing Open Telecom Platform"}] = r.checks
    # The verifier passed an answer the check failed: a false acceptance.
    assert r.verdict == :accepted
    assert r.calls.model == 1
    assert r.calls.decider >= 2
    assert %{false_acceptances: 1, passed: 0, route_accuracy: 1.0} = Eval.summary([r])
  end

  test "a file plan is approved in the throwaway home, and the tree it leaves is checked" do
    Model.Script.script(fn _, _ ->
      JSON.encode!(%{
        look: [],
        mkdir: [],
        copy: [],
        trash: [],
        write: [],
        move: [%{from: "~/Downloads/a.pdf", to: "~/Papers/"}],
        reply: "Moving it."
      })
    end)

    Decider.Script.script(fn
      :organize, _, _ -> 0.95
      :complete, _, _ -> 0.9
      key, _, _ -> if String.starts_with?(to_string(key), "step_"), do: 0.9, else: nil
    end)

    task = %{
      id: "f",
      category: :files,
      split: :dev,
      home: %{"Downloads/a.pdf" => "pdf a", "Downloads/b.pdf" => "pdf b"},
      prompt: "Move the PDFs into Papers",
      expect: [
        route: :organize,
        tree: %{"Papers/a.pdf" => "pdf a", "Papers/b.pdf" => "pdf b"}
      ]
    }

    r = Eval.run_task(task)
    assert r.plan_applied
    assert r.route == :organize
    # Only a.pdf was moved: the tree check catches the missed file.
    assert [%{ok: true}, %{ok: false, why: why}] = r.checks
    assert why =~ "Papers/b.pdf"
    refute why =~ "Papers/a.pdf"
    # The real home and project settings are back.
    assert Application.get_env(:tiny_axe, :fs_root) == nil
  end

  test "generated code is run against the task's own tests" do
    unless TinyAxe.Sandbox.available?(), do: flunk("bwrap is needed for code checks")

    Model.Script.script(fn _, _ ->
      "```elixir\ndefmodule Twice do\n  def of(n), do: n * 2\nend\n```"
    end)

    route = routing(%{kind: :code})

    Decider.Script.script(fn
      :addresses, _, _ -> 0.9
      k, q, s -> route.(k, q, s)
    end)

    passing = %{
      id: "c",
      category: :code,
      split: :dev,
      prompt: "Write Twice.of/1",
      expect: [elixir_tests: "assert Twice.of(2) == 4"]
    }

    assert Eval.run_task(passing).passed

    failing = %{passing | expect: [elixir_tests: "assert Twice.of(2) == 5"]}
    assert %{passed: false, checks: [%{why: why}]} = Eval.run_task(failing)
    assert why =~ "Assertion"
  end

  test "a retry that fixes a failing first attempt is told apart from one that breaks a passing one" do
    counter = :counters.new(1, [])

    Model.Script.script(fn _, _ ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1,
        do: "It's the Open Platform.",
        else: "Open Telecom Platform."
    end)

    route = routing(%{})

    Decider.Script.script(fn
      :addresses, _, %{response: r} -> if r =~ "Telecom", do: 0.9, else: 0.2
      k, q, s -> route.(k, q, s)
    end)

    task = %{
      id: "r",
      category: :answer,
      split: :dev,
      prompt: "What does OTP stand for?",
      expect: [contains: ["Open Telecom Platform"]]
    }

    fixed = Eval.run_task(task)
    assert %{attempts: 2, first_passed: false, passed: true, verdict: :accepted} = fixed

    # The reverse: the judge sends a right first answer back, and the retry is wrong.
    :counters.put(counter, 1, 0)

    Decider.Script.script(fn
      :addresses, _, %{response: r} -> if r =~ "Telecom", do: 0.2, else: 0.9
      k, q, s -> route.(k, q, s)
    end)

    Model.Script.script(fn _, _ ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1,
        do: "Open Telecom Platform.",
        else: "It's the Open Platform."
    end)

    broke = Eval.run_task(task)
    assert %{attempts: 2, first_passed: true, passed: false, verdict: :accepted} = broke

    assert %{retry_fixed: 1, retry_broke: 1, false_acceptances: 1} =
             Eval.summary([fixed, broke])
  end

  test "the starter tasks load and are well-formed" do
    tasks = Eval.tasks()
    assert length(tasks) >= 16
    assert tasks |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(tasks)
    assert Enum.any?(tasks, &(&1.split == :holdout))

    for t <- tasks do
      assert t.split in [:dev, :holdout]
      assert is_binary(t.prompt) and t.expect != []
    end
  end
end
