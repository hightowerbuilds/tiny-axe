defmodule TinyAxe.BrowserVerifyTest do
  @moduledoc """
  Outcome verification through the gate, without Chrome: the fake browser
  (test/support/fake_mcp/browser) reports what a click did (its POST
  answered, lost, a 502) and what a fresh look at the page shows. Covers the
  gate-owned `browser_verify` tool, unresolved actions that can't be
  repeated, and the completion check every driver's answer goes through.
  The real browser and fixture site are in browser_outcome_test.exs.
  """

  # Swaps the app-wide decider, model and roles, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Agent, Decider, MCP, Model, Tools}
  alias TinyAxe.Tools.Gate

  @browser Path.expand("../support/fake_mcp/browser", __DIR__)
  @keys ~w(model_backend decider script_model script_decider models code_check web_search)a

  @policy %{
    "browser" => true,
    "read" => ["browser_snapshot"],
    "hidden" => ["browser_inspect", "browser_release", "browser_observe", "fake_page", "fake_log"]
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
    page(%{server: name}, %{label: "Send note"})
    pages_say(0.9)
    %{server: name}
  end

  # The decider reads the pages as the scripted one does: a page saying
  # "sent" shows the effect. `claims` is how surely an answer claims success.
  defp pages_say(claims) do
    Decider.Script.script(fn
      :took_effect, _, state -> if state.now.text =~ "sent", do: 0.9, else: 0.1
      :claim_1, _, _ -> claims
      _, _, _ -> nil
    end)
  end

  defp open(ctx) do
    me = self()
    {:ok, task} = Gate.open_task(&send(me, {:gate, &1}), servers: [ctx.server])
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

  # One call through the gate, approving whatever it asks.
  defp call(task, name, args) do
    caller = Task.async(fn -> rpc(task, "tools/call", %{name: name, arguments: args}) end)
    await(caller)
  end

  defp await(caller) do
    receive do
      {:gate, {:tool_approval, ask}} ->
        send(self(), {:asked, ask})
        # Doing again what may already have gone through: only if the test says.
        answer = if ask[:repeat] && !Process.get(:approve_repeat), do: :deny, else: :once
        send(ask.reply_to, {:tool_answer, ask.ref, answer})
        await(caller)

      {ref, result} when ref == caller.ref ->
        Process.demonitor(ref, [:flush])
        result
    after
      15_000 -> flunk("the call never finished")
    end
  end

  defp text(%{"content" => content}), do: Enum.map_join(content, "\n", & &1["text"])

  defp click(ctx, task, args \\ %{ref: "e1"}),
    do: call(task, "#{ctx.server}__browser_click", args)

  defp verify(task, args), do: JSON.decode!(text(call(task, "browser_verify", args)))

  defp log(ctx) do
    {:ok, result} = MCP.call(ctx.server, "fake_log", %{})
    JSON.decode!(text(result))
  end

  defp page(ctx, args), do: {:ok, _} = MCP.call(ctx.server, "fake_page", args)

  defp action_id(result) do
    [_, id] = Regex.run(~r/(act-[0-9a-f]+)/, text(result))
    id
  end

  test "browser_verify is offered with a browser, under any name a driver shows", ctx do
    task = open(ctx)
    names = for t <- rpc(task, "tools/list", %{})["tools"], do: t["name"]
    assert "browser_verify" in names
    refute "#{ctx.server}__browser_observe" in names

    # Nothing to verify yet; browser_assess can't assess it.
    for name <- ["browser_verify", "mcp__tinyaxe__browser_verify", "tinyaxe.browser_verify"] do
      assert text(call(task, name, %{})) =~ "no browser action in this task to verify"
    end

    result = call(task, "browser_assess", %{tool: "browser_verify", arguments: %{}})
    assert text(result) =~ "only assesses this task's browser actions"
  end

  test "a sent action is confirmed from a fresh look at the page, and the record links it", ctx do
    page(ctx, %{outcome: "ok", text: "Note sent"})
    task = open(ctx)
    result = click(ctx, task)
    assert text(result) =~ "call browser_verify with this action_id"
    id = action_id(result)

    v = verify(task, %{action_id: id, claimed_outcome: "the note was sent"})

    assert %{
             "status" => "succeeded",
             "reason_codes" => ["effect_observed"],
             "claim" => "consistent"
           } =
             v

    assert v["evidence"]["observation"]["observation"] == "obs-fake-1"
    assert [%{"check" => "request", "result" => "pass"}] = v["evidence"]["checks"]
    assert_received {:gate, {:outcome, %{id: ^id, status: :succeeded, by: :agent}}}

    [click_entry, verify_entry] = Tools.Journal.read(task.id)
    assert click_entry["action"]["id"] == id and click_entry["action"]["status"] == "pending"
    assert verify_entry["verification"]["action_id"] == id
    assert verify_entry["verification"]["status"] == "succeeded"
    # One record for the outcome, one for the claim, both linked.
    records =
      for r <- Tools.Journal.decisions(task.id), r["id"] in verify_entry["decisions"], do: r

    assert length(records) == 2

    for record <- records do
      assert record["schema"] == "browser-decision/3" and record["kind"] == "verify"
      assert record["action_id"] == id and record["disposition"] == "succeeded"
    end

    # Another task can't see this task's actions.
    assert text(call(open(ctx), "browser_verify", %{action_id: id})) =~ "no browser action #{id}"
  end

  test "a lost response leaves it unresolved: never repeated, even when verifying fails", ctx do
    page(ctx, %{outcome: "lost"})
    task = open(ctx)
    result = click(ctx, task)
    refute result["isError"]
    assert text(result) =~ "outcome_unresolved: response_lost"
    assert text(result) =~ "Don't repeat it"
    id = action_id(result)
    assert_received {:gate, {:outcome, %{id: ^id, status: :unresolved}}}
    assert [_] = log(ctx)["clicks"]
    assert_received {:asked, _}

    # Repeated directly: the user is asked whether to do it again (and says
    # no); nothing is clicked. Asked about first: refused.
    repeat = click(ctx, task)
    assert repeat["isError"] and text(repeat) =~ "may already have gone through"
    assert_received {:asked, %{repeat: true}}
    refute_received {:asked, _}

    assess =
      JSON.decode!(
        text(
          call(task, "browser_assess", %{
            tool: "#{ctx.server}__browser_click",
            arguments: %{ref: "e1"}
          })
        )
      )

    assert assess["disposition"] == "refused" and "outcome_unresolved" in assess["reason_codes"]

    # The page can't be read: still unresolved, still not repeated.
    page(ctx, %{observe: "fail"})
    v = verify(task, %{action_id: id})
    assert v["status"] == "unresolved" and "observation_failed" in v["reason_codes"]
    assert click(ctx, task)["isError"]
    assert [_] = log(ctx)["clicks"]

    # The page, loaded again (a new observation), shows it arrived:
    # confirmed, and no longer held.
    page(ctx, %{observe: nil, text: "Your note was sent", observation: "obs-fake-2"})
    assert verify(task, %{})["status"] == "succeeded"
    refute click(ctx, task)["isError"]
    assert_received {:asked, _}
    assert [_, _] = log(ctx)["clicks"]
  end

  test "a hold outlasts its task: the next task on the tab can't resend it, until it expires",
       ctx do
    page(ctx, %{outcome: "lost"})
    first = open(ctx)
    assert text(click(ctx, first)) =~ "outcome_unresolved"
    Gate.close_task(first.id)

    # A new task ("try again"): refused, unless the user says otherwise (here no).
    second = open(ctx)
    repeat = click(ctx, second)
    assert repeat["isError"] and text(repeat) =~ "may already have gone through"
    assert_received {:asked, %{repeat: true, reason: reason}}
    assert reason =~ ~s(an earlier click "Send note" couldn't be confirmed)
    assert [_] = log(ctx)["clicks"]

    # Holds expire (`:hold_ttl`).
    tools = Application.get_env(:tiny_axe, :tools, [])
    on_exit(fn -> Application.put_env(:tiny_axe, :tools, tools) end)
    Application.put_env(:tiny_axe, :tools, Keyword.put(tools, :hold_ttl, 100))
    page(ctx, %{label: "Send memo", outcome: "lost"})
    third = open(ctx)
    click(ctx, third)
    Process.sleep(200)
    page(ctx, %{outcome: "ok"})
    refute click(ctx, open(ctx))["isError"]
  end

  test "only the user's go-ahead lifts a hold, through the usual approval", ctx do
    page(ctx, %{outcome: "lost"})
    task = open(ctx)
    click(ctx, task)

    # The agent alone can't: browser_assess still says refused.
    assess =
      JSON.decode!(
        text(
          call(task, "browser_assess", %{
            tool: "#{ctx.server}__browser_click",
            arguments: %{ref: "e1"}
          })
        )
      )

    assert "outcome_unresolved" in assess["reason_codes"]

    # The user approves doing it again: it runs, and the hold is gone.
    Process.put(:approve_repeat, true)
    page(ctx, %{outcome: "ok"})
    refute click(ctx, task)["isError"]
    assert_received {:asked, %{repeat: true}}
    assert [_, _] = log(ctx)["clicks"]

    refute "outcome_unresolved" in hd(
             for e <- Enum.reverse(Tools.Journal.read(task.id)),
                 e["action"],
                 do: e["action"]["codes"]
           )
  end

  test "unresolved records are never pushed out by later ones", ctx do
    page(ctx, %{outcome: "lost"})
    task = open(ctx)
    id = action_id(click(ctx, task))

    # Fifty-one settled actions later, on other targets.
    page(ctx, %{outcome: "ok"})

    for i <- 1..51 do
      page(ctx, %{label: "Note #{i}"})
      refute click(ctx, task, %{ref: "e1", element: "note #{i}"})["isError"]
    end

    # The task still holds its record: it can be verified by its id, and is
    # still unresolved.
    result = call(task, "browser_verify", %{action_id: id})
    refute result["isError"], text(result)
    v = JSON.decode!(text(result))
    assert v["action_id"] == id and v["status"] == "unresolved"
  end

  describe "the completion check, for every driver" do
    defp driver(choice) do
      models = Application.get_env(:tiny_axe, :models, [])
      Application.put_env(:tiny_axe, :models, Keyword.put(models, :agent, choice))
    end

    defp run(ctx, prompt) do
      me = self()
      before = tasks()

      task =
        Task.async(fn -> Agent.run([], prompt, &send(me, {:event, &1}), remote: :allowed) end)

      events = collect(task, [])
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
          send(ask.reply_to, {:tool_answer, ask.ref, :once})
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

    defp local_model(tool) do
      counter = :counters.new(1, [])

      Model.Script.script(fn _messages, _opts ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1,
          do: JSON.encode!(%{thought: "", tool: tool, arguments: ~s({"ref":"e1"}), answer: ""}),
          else:
            JSON.encode!(%{
              thought: "",
              tool: "",
              arguments: "{}",
              answer: "Done: the note was sent."
            })
      end)
    end

    # Each driver approves the same click, then answers; what the user is shown.
    defp drive(ctx, choice) do
      tool = "#{ctx.server}__browser_click"
      driver(choice)
      if match?({:ollama, _}, choice), do: local_model(tool)
      {events, id} = run(ctx, ~s(SCENARIO:tool:#{tool}:{"ref":"e1"}))
      done = Enum.find_value(events, fn e -> match?({:done, _}, e) && elem(e, 1) end)
      [completion] = for e <- Tools.Journal.read(id), e["tool"] == "tiny-axe/completion", do: e

      delivered =
        case done do
          "⚠ tiny-axe couldn't confirm" <> _ -> {:noted, hd(String.split(done, "\n\n", parts: 2))}
          "tiny-axe held back" <> _ -> done
          _ -> :as_said
        end

      # Nothing of the driver's own text reaches the user before the check.
      assert for({:delta, _} <- events, do: :streamed) == []

      %{
        delivered: delivered,
        completion: %{
          "outcome" => completion["completion"]["outcome"],
          "contradicted" => length(completion["completion"]["contradicted"])
        },
        events: for({:completion, c} <- events, do: c.outcome)
      }
    end

    @drivers [{:claude, "haiku"}, {:codex, "gpt-6-luna"}, {:ollama, "local-test"}]

    test "an answer a failed action contradicts is replaced, the same for every driver", ctx do
      # The site rejects the note (a 400); every answer says it was sent.
      page(ctx, %{outcome: "rejected", text: "Bad request"})
      seen = Enum.map(@drivers, &drive(ctx, &1))

      for s <- seen do
        assert s.delivered =~ "tiny-axe held back the agent's reply"
        assert s.delivered =~ ~s(✗ not done: click "Send note": the site rejected it)
        assert s.completion == %{"outcome" => "replaced", "contradicted" => 1}
        assert s.events == [:replaced]
      end

      assert seen |> Enum.uniq() |> length() == 1
    end

    test "an unresolved action keeps each driver's answer, under a note naming it", ctx do
      page(ctx, %{outcome: "bad_gateway", text: "502 Bad Gateway: may not have been saved"})
      seen = Enum.map(@drivers, &drive(ctx, &1))

      for s <- seen do
        assert {:noted, note} = s.delivered

        assert note ==
                 "⚠ tiny-axe couldn't confirm all of this answer. Not confirmed:\n" <>
                   ~s(? click "Send note": the site answered with an error, so it may or may ) <>
                   "not have gone through. tiny-axe won't repeat it; check before trying again."

        assert s.completion == %{"outcome" => "caveated", "contradicted" => 0}
      end

      assert seen |> Enum.uniq() |> length() == 1
      # Each driver's click happened once; none was repeated.
      assert length(log(ctx)["clicks"]) == 3
    end

    test "a confirmed outcome lets the answer through unchanged, for every driver", ctx do
      page(ctx, %{outcome: "ok", text: "Note sent"})
      seen = Enum.map(@drivers, &drive(ctx, &1))

      for s <- seen do
        assert s.delivered == :as_said
        assert s.completion == %{"outcome" => "delivered", "contradicted" => 0}
      end

      # Verified once, at completion, by a fresh look at the page.
      assert length(log(ctx)["observes"]) == 3
    end
  end
end
