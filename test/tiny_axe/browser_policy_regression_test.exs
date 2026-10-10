defmodule TinyAxe.BrowserPolicyRegressionTest do
  use ExUnit.Case, async: false

  alias TinyAxe.Decider
  alias TinyAxe.Tools.BrowserPolicy

  setup do
    previous = Application.get_env(:tiny_axe, :decider)
    script = Application.get_env(:tiny_axe, :script_decider)

    on_exit(fn ->
      Application.put_env(:tiny_axe, :decider, previous)

      if script,
        do: Application.put_env(:tiny_axe, :script_decider, script),
        else: Application.delete_env(:tiny_axe, :script_decider)
    end)
  end

  {cases, _} = Code.eval_file("eval/browser_policy_cases.exs")

  for scenario <- cases do
    @scenario scenario
    test scenario.id do
      scenario = @scenario

      Decider.Script.script(fn key, _, _ -> answer(scenario.answers, key) end)

      assert {class, _} =
               BrowserPolicy.classify(scenario.tool, scenario.args, fn _ -> scenario.target end)

      assert class == scenario.expected
    end
  end

  defp answer(:error, _key), do: {:error, :unavailable}
  defp answer(answers, key), do: Map.get(answers, key)
end
