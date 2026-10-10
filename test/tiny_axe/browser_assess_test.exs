defmodule TinyAxe.BrowserAssessTest do
  @moduledoc """
  Mandatory browser assessment through the gate, without Chrome: a fake
  browser server (test/support/fake_mcp/browser) behind the gate, with one
  button whose label a test can change. Covers the gate-owned
  `browser_assess` tool, direct calls, binding across tasks, the browser's
  final check, and every driver getting the same checks.
  """

  # Swaps the app-wide decider, model and roles, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Agent, Decider, MCP, Model, Tools}
  alias TinyAxe.Browser.Decisions
  alias TinyAxe.Tools.Gate

  @browser Path.expand("../support/fake_mcp/browser", __DIR__)
  @server Path.expand("../support/fake_mcp/server", __DIR__)
  @keys ~w(model_backend decider script_model script_decider models code_check web_search)a

  @policy %{
    "browser" => true,
    "read" => ["browser_snapshot"],
    "hidden" => ["browser_inspect", "browser_release", "fake_page", "fake_log"]
  }

  setup do
    previous = Map.new(@keys, &{&1, Application.get_env(:tiny_axe, &1)})
    name = "fakebrowser#{System.unique_integer([:positive])}"
    {:ok, _} = MCP.start_server(name, %{"command" => @browser, "policy" => @policy})

    on_exit(fn ->
      MCP.stop_server(name)

      for {k, v} <- previous,
          do:
            if(v == nil,
              do: Application.delete_env(:tiny_axe, k),
              else: Application.put_env(:tiny_axe, k, v)
            )
    end)

    Application.put_env(:tiny_axe, :code_check, false)
    Application.put_env(:tiny_axe, :web_search, false)
    # The button says nothing: "no" to every question unless a test says otherwise.
    Decider.Script.script(fn _, _, _ -> nil end)
    %{server: name}
  end

  defp open(ctx, opts \\ []) do
    me = self()

    {:ok, task} =
      Gate.open_task(&send(me, {:gate, &1}), Keyword.put_new(opts, :servers, [ctx.server]))

    on_exit(fn -> Gate.close_task(task.id) end)
    task
  end

  defp rpc(task, method, params) do
    Req.post!(task.url,
      json: %{jsonrpc: "2.0", id: 1, method: method, params: params},
      headers: %{"authorization" => "Bearer #{task.token}"},
      retry: false
    ).body["result"]
  end

  # One call through the gate; `answer` replies to an approval, after
  # `meanwhile` (the page changing while the user decides).
  defp call(task, name, args, answer \\ :deny, meanwhile \\ fn -> :ok end) do
    caller = Task.async(fn -> rpc(task, "tools/call", %{name: name, arguments: args}) end)
    await(caller, answer, meanwhile)
  end

  defp await(caller, answer, meanwhile) do
    receive do
      {:gate, {:tool_approval, ask}} ->
        send(self(), {:asked, ask})
        meanwhile.()
        send(ask.reply_to, {:tool_answer, ask.ref, answer})
        await(caller, answer, meanwhile)

      {ref, result} when ref == caller.ref ->
        Process.demonitor(ref, [:flush])
        result
    after
      15_000 -> flunk("the call never finished")
    end
  end

  defp text(%{"content" => [%{"text" => t} | _]}), do: t

  defp assess(ctx, task, args, extra \\ %{}) do
    result =
      call(
        task,
        "browser_assess",
        Map.merge(%{tool: "#{ctx.server}__browser_click", arguments: args}, extra)
      )

    refute result["isError"]
    JSON.decode!(text(result))
  end

  defp click(ctx, task, args \\ %{ref: "e1"}, answer \\ :deny, meanwhile \\ fn -> :ok end),
    do: call(task, "#{ctx.server}__browser_click", args, answer, meanwhile)

  # What the fake browser saw, read straight from it (not through the gate).
  defp log(ctx) do
    {:ok, result} = MCP.call(ctx.server, "fake_log", %{})
    JSON.decode!(text(result))
  end

  defp page(ctx, args), do: {:ok, _} = MCP.call(ctx.server, "fake_page", args)

  # The questions the decider was asked since last time.
  defp decided(acc \\ []) do
    receive do
      {:decided, key} -> decided([key | acc])
    after
      0 -> Enum.sort(acc)
    end
  end

  defp decisions(fun) do
    me = self()

    Decider.Script.script(fn key, q, state ->
      send(me, {:decided, key})
      fun.(key, q, state)
    end)
  end

  describe "browser_assess" do
    test "is offered with a browser, and assesses only browser actions, never itself", ctx do
      task = open(ctx)
      names = for t <- rpc(task, "tools/list", %{})["tools"], do: t["name"]
      assert "browser_assess" in names
      refute "#{ctx.server}__browser_inspect" in names

      for {tool, why} <- [
            {"browser_assess", "only assesses this task's browser actions"},
            {"#{ctx.server}__browser_inspect", "only assesses this task's browser actions"},
            {"#{ctx.server}__fake_page", "only assesses this task's browser actions"}
          ] do
        result = call(task, "browser_assess", %{tool: tool, arguments: %{}})
        assert result["isError"] and text(result) =~ why
      end

      result =
        call(task, "browser_assess", %{tool: "#{ctx.server}__browser_click", arguments: %{}})

      assert text(result) =~ "needs ref"

      # Without a browser there's nothing to assess.
      other = "fake#{System.unique_integer([:positive])}"
      {:ok, _} = MCP.start_server(other, %{"command" => @server, "policy" => %{}})
      on_exit(fn -> MCP.stop_server(other) end)
      plain = open(ctx, servers: [other])
      refute "browser_assess" in for(t <- rpc(plain, "tools/list", %{})["tools"], do: t["name"])
      assert text(call(plain, "browser_assess", %{tool: "x", arguments: %{}})) =~ "no tool"
    end

    test "answers with the disposition, reason codes, evidence and next step, and is traced",
         ctx do
      task = open(ctx)

      decisions(fn
        :sends, _, _ -> 0.9
        _, _, _ -> nil
      end)

      answer = assess(ctx, task, %{ref: "e1"}, %{expected_effect: "opens the settings"})

      assert %{
               "decision_id" => "asm-" <> _ = id,
               "disposition" => "needs_approval",
               "reason_codes" => ["sends_signal"],
               "next_step" => step,
               "evidence" => %{
                 "observation_id" => "obs-fake-1",
                 "targets" => %{"e1" => %{"text" => "⚙"}},
                 "decision_records" => [record_id]
               }
             } = answer

      assert step =~ "the user is asked to approve it"
      refute_received {:asked, _}
      assert log(ctx)["clicks"] == []

      [entry] = Tools.Journal.read(task.id)
      assert entry["tool"] == "browser_assess" and entry["decision"] == "ran"
      assert entry["assessment"]["id"] == id
      assert entry["assessment"]["mode"] == "advice"
      assert entry["assessment"]["expected_effect"] == "opens the settings"
      assert entry["decisions"] == [record_id]

      [record] = Tools.Journal.decisions(task.id)
      assert record["schema"] == "browser-decision/2"
      assert record["assessment_id"] == id
      assert record["tool"] == "#{ctx.server}__browser_click"

      assert %{"task" => task_id, "lease" => task_id, "targets" => %{"e1" => "sig-" <> _}} =
               record["binding"]

      assert task_id == task.id
    end
  end

  describe "direct calls" do
    test "asking first and acting directly get the same checks", ctx do
      decisions(fn
        :sends, _, _ -> 0.9
        _, _, _ -> nil
      end)

      direct = open(ctx)
      assert click(ctx, direct)["isError"]
      assert_received {:asked, %{class: :outward, reason: reason}}
      questions = decided()
      assert :sends in questions

      asked = open(ctx)
      assert assess(ctx, asked, %{ref: "e1"})["disposition"] == "needs_approval"
      assert decided() == questions

      # The action itself reuses that assessment: no second judgment, same question.
      assert click(ctx, asked)["isError"]
      assert decided() == []
      assert_received {:asked, %{class: :outward, reason: ^reason}}

      [d] = Tools.Journal.read(direct.id)
      [_assess, a] = Tools.Journal.read(asked.id)
      assert d["assessment"]["reason_codes"] == a["assessment"]["reason_codes"]
      assert d["assessment"]["disposition"] == a["assessment"]["disposition"]
      assert a["assessment"]["reused_from"] != nil
      assert log(ctx)["clicks"] == []
    end

    test "an assessment is the task's own: another task can't use it, whatever it passes", ctx do
      mine = open(ctx)
      theirs = open(ctx)
      %{"decision_id" => id, "disposition" => "allowed"} = assess(ctx, mine, %{ref: "e1"})

      # The decision service goes down.
      decisions(fn _, _, _ -> {:error, :down} end)

      result =
        click(ctx, theirs, %{
          ref: "e1",
          decision_id: id,
          _tinyaxe_tab: mine.id,
          _tinyaxe_expect: %{"targets" => %{}}
        })

      assert result["isError"] and text(result) =~ "decision service is unavailable"
      assert log(ctx)["clicks"] == []
      # It looked with its own tab lease, not the one it passed.
      assert Enum.all?(log(ctx)["inspects"], &(&1["_tinyaxe_tab"] in [mine.id, theirs.id]))
      assert List.last(log(ctx)["inspects"])["_tinyaxe_tab"] == theirs.id

      # The task that asked acts on its own assessment, in its own tab, with
      # the target signature for the browser's final check.
      refute click(ctx, mine)["isError"]
      assert [clicked] = log(ctx)["clicks"]
      assert clicked["_tinyaxe_tab"] == mine.id

      assert %{"observation" => "obs-fake-1", "targets" => %{"e1" => "sig-" <> _}} =
               clicked["_tinyaxe_expect"]
    end

    test "a target that changes while the user decides isn't clicked", ctx do
      page(ctx, %{label: "Send note"})
      task = open(ctx)

      result =
        click(ctx, task, %{ref: "e1"}, :once, fn -> page(ctx, %{label: "Delete everything"}) end)

      assert_received {:asked, %{class: :outward, reason: ~s(clicks "Send note") <> _}}
      assert result["isError"]
      assert text(result) =~ "stale_target"
      assert text(result) =~ "fresh browser_snapshot"
      assert log(ctx)["clicks"] == []
      assert [_] = log(ctx)["stale"]

      # Asked again, it's judged afresh: the user sees what it is now.
      click(ctx, task, %{ref: "e1"}, :deny)
      assert_received {:asked, %{reason: ~s(clicks "Delete everything") <> _}}
    end

    test "a reused assessment whose target changes while the user decides is dropped", ctx do
      page(ctx, %{label: "Send note"})
      task = open(ctx)
      %{"decision_id" => id} = assess(ctx, task, %{ref: "e1"})

      result =
        click(ctx, task, %{ref: "e1"}, :once, fn -> page(ctx, %{label: "Delete everything"}) end)

      assert text(result) =~ "stale_target"
      assert List.last(Tools.Journal.read(task.id))["assessment"]["reused_from"] == id
      assert log(ctx)["clicks"] == []

      # The old record is gone: the next call is judged afresh and the user
      # sees what the button is now.
      click(ctx, task, %{ref: "e1"}, :deny)
      assert_received {:asked, %{reason: ~s(clicks "Send note") <> _}}
      assert_received {:asked, %{reason: ~s(clicks "Delete everything") <> _}}
      assert List.last(Tools.Journal.read(task.id))["assessment"]["reused_from"] == nil
    end

    test "a target that changed in place since it was assessed is refused as stale, once", ctx do
      task = open(ctx)
      assert assess(ctx, task, %{ref: "e1"})["disposition"] == "allowed"
      page(ctx, %{label: "Delete everything"})

      result = click(ctx, task)
      assert text(result) =~ ~s(it was "⚙", now "Delete everything")
      refute_received {:asked, _}
      assert log(ctx)["clicks"] == []

      [_, entry] = Tools.Journal.read(task.id)
      assert entry["assessment"]["reason_codes"] == ["stale_target"]

      # The stale record is gone: the next call is assessed afresh.
      click(ctx, task, %{ref: "e1"}, :deny)
      assert_received {:asked, %{class: :outward}}
    end

    test "a purchase signal for a target holds against later, weaker or missing answers", ctx do
      task = open(ctx)

      decisions(fn
        :spends, _, _ -> 0.9
        _, _, _ -> nil
      end)

      assert %{"disposition" => "refused", "reason_codes" => codes} =
               assess(ctx, task, %{ref: "e1"})

      assert "purchase_signal" in codes and "purchases_disabled" in codes

      # The page reloads (a new observation), so that assessment isn't reused;
      # now an answer goes missing, then the decider says it spends nothing.
      page(ctx, %{observation: "obs-fake-2"})
      decisions(fn _, _, _ -> :unknown end)
      assert text(click(ctx, task)) =~ "couldn't check"

      decisions(fn _, _, _ -> nil end)
      result = click(ctx, task)
      assert result["isError"] and text(result) =~ "spending money isn't enabled"
      refute_received {:asked, _}
      assert log(ctx)["clicks"] == []

      entry = List.last(Tools.Journal.read(task.id))
      assert "prior_restriction" in entry["assessment"]["reason_codes"]
    end

    test "closing a task frees the tabs it used; one that never used the browser has none", ctx do
      used = open(ctx)
      click(ctx, used)
      Gate.close_task(used.id)
      assert [%{"_tinyaxe_tab" => id}] = log(ctx)["releases"]
      assert id == used.id

      idle = open(ctx)
      Gate.close_task(idle.id)
      assert [_] = log(ctx)["releases"]
    end
  end

  describe "every driver" do
    defp driver(choice) do
      models = Application.get_env(:tiny_axe, :models, [])
      Application.put_env(:tiny_axe, :models, Keyword.put(models, :agent, choice))
    end

    # Runs the agent as the TUI does, denying any approval; returns its
    # events and the gate task it ran in.
    defp run(ctx, prompt) do
      me = self()
      before = tasks()

      task =
        Task.async(fn -> Agent.run([], prompt, &send(me, {:event, &1}), remote: :allowed) end)

      events = collect(task, [])
      # Other test runs may share the state folder: the task is the new one
      # that called this test's own server.
      [id] = for id <- tasks() -- before, ran_on?(id, ctx.server), do: id
      {events, id}
    end

    defp tasks do
      case File.ls(Path.join(TinyAxe.Ops.Journal.state_dir(), "tasks")) do
        {:ok, ids} -> ids
        _ -> []
      end
    end

    defp ran_on?(id, server),
      do: Enum.any?(Tools.Journal.read(id), &(JSON.encode!(&1) =~ server <> "__"))

    defp collect(task, acc) do
      receive do
        {:event, {:tool_approval, ask} = e} ->
          send(ask.reply_to, {:tool_answer, ask.ref, :deny})
          collect(task, [e | acc])

        {:event, {:ask_remote, ask} = e} ->
          send(ask.reply_to, {:remote_answer, ask.ref, true})
          collect(task, [e | acc])

        {:event, e} ->
          collect(task, [e | acc])

        {ref, _} when ref == task.ref ->
          Process.demonitor(ref, [:flush])
          Enum.reverse(acc)
      after
        30_000 -> flunk("the agent never finished")
      end
    end

    # The local model calls the tool once, then answers; it reports the
    # instructions it was given.
    defp local_model(tool, args) do
      me = self()
      counter = :counters.new(1, [])

      Model.Script.script(fn messages, _opts ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          send(me, {:local_system, hd(messages).content})

          JSON.encode!(%{thought: "", tool: tool, arguments: JSON.encode!(args), answer: ""})
        else
          JSON.encode!(%{thought: "", tool: "", arguments: "{}", answer: "done"})
        end
      end)
    end

    # Each driver makes the same direct click; returns what it was told and
    # what the gate did.
    defp drive(ctx, choice) do
      tool = "#{ctx.server}__browser_click"
      scenario = ~s(SCENARIO:tool:#{tool}:{"ref":"e1"})
      driver(choice)
      if match?({:ollama, _}, choice), do: local_model(tool, %{ref: "e1"})
      {events, id} = run(ctx, scenario)

      told =
        case choice do
          {:ollama, _} ->
            assert_received {:local_system, system}
            system

          {:claude, _} ->
            args = JSON.decode!(done(events))["args"]
            args |> Enum.drop_while(&(&1 != "--system-prompt")) |> Enum.at(1)

          {:codex, _} ->
            JSON.decode!(done(events))["stdin"]
        end

      calls = for {:tool_call, c} <- events, do: Map.take(c, [:tool, :class, :reason])
      asked = for {:tool_approval, a} <- events, do: Map.take(a, [:tool, :class, :reason])
      [entry] = Tools.Journal.read(id)
      records = Tools.Journal.decisions(id)

      %{
        told: told,
        calls: calls,
        asked: asked,
        decision: entry["decision"],
        assessment: Map.take(entry["assessment"], ["mode", "disposition", "reason_codes"]),
        records:
          Enum.map(records, &Map.take(&1, ["disposition", "reason_codes", "policy_version"]))
      }
    end

    defp done(events),
      do: Enum.find_value(events, fn e -> match?({:done, _}, e) && elem(e, 1) end)

    @drivers [{:claude, "haiku"}, {:codex, "gpt-6-luna"}, {:ollama, "local-test"}]

    test "drivers can name the action as they see it when they ask first", ctx do
      tool = "#{ctx.server}__browser_click"

      for {choice, seen} <- [
            {{:claude, "haiku"}, "mcp__tinyaxe__" <> tool},
            {{:codex, "gpt-6-luna"}, "mcp__tinyaxe__" <> tool},
            {{:codex, "gpt-6-luna"}, "tinyaxe." <> tool}
          ] do
        driver(choice)
        args = JSON.encode!(%{tool: seen, arguments: %{ref: "e1"}})
        {events, _id} = run(ctx, "SCENARIO:tool:browser_assess:#{args}")
        result = JSON.decode!(done(events))["tool_result"]

        refute result["error"], inspect({choice, seen, result})
        assert %{"disposition" => "allowed"} = JSON.decode!(result["text"])
      end
    end

    test "every driver gets the same instructions and the same mandatory checks", ctx do
      decisions(fn
        :sends, _, _ -> 0.9
        _, _, _ -> nil
      end)

      outward = Enum.map(@drivers, &drive(ctx, &1))

      for seen <- outward do
        assert seen.told =~ Decisions.instructions()

        assert [%{class: :outward, reason: ~s(acts on "⚙", which may send or change something)}] =
                 seen.calls

        assert seen.asked == Enum.map(seen.calls, &Map.put(&1, :class, :outward))
        assert seen.decision == "denied"

        assert seen.assessment == %{
                 "mode" => "execute",
                 "disposition" => "needs_approval",
                 "reason_codes" => ["sends_signal"]
               }
      end

      assert outward |> Enum.map(&Map.drop(&1, [:told])) |> Enum.uniq() |> length() == 1

      # The decision service down: refused, the same way, without asking.
      decisions(fn _, _, _ -> {:error, :down} end)
      unavailable = Enum.map(@drivers, &drive(ctx, &1))

      for seen <- unavailable do
        assert seen.asked == []
        assert seen.decision == "refused"
        assert seen.assessment["reason_codes"] == ["decision_unavailable"]
      end

      assert unavailable |> Enum.map(&Map.drop(&1, [:told])) |> Enum.uniq() |> length() == 1
      assert log(ctx)["clicks"] == []
    end
  end
end
