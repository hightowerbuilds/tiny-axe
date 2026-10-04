defmodule TinyAxe.EscalationTest do
  @moduledoc """
  Escalation: when the local model falls short, the ladder (Claude haiku, then
  sonnet) is tried, if the user allows it. The local model is scripted; the
  bigger models are the fake `claude` (test/support/fake_cli), which answers
  with what it was given, so no test uses a real subscription.
  """

  # Swaps the app-wide model, decider and folders, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Decider, Model, Pipeline}

  @moduletag :tmp_dir

  @keys ~w(model_backend decider script_model script_decider fs_root project_dir code_check web_search escalate)a

  setup %{tmp_dir: dir} do
    previous = Map.new(@keys, &{&1, Application.get_env(:tiny_axe, &1)})

    on_exit(fn ->
      for {k, v} <- previous,
          do:
            if(v == nil,
              do: Application.delete_env(:tiny_axe, k),
              else: Application.put_env(:tiny_axe, k, v)
            )

      set_claude_usage(0.1)
      TinyAxe.Location.reset()
    end)

    Application.put_env(:tiny_axe, :fs_root, dir)
    Application.put_env(:tiny_axe, :project_dir, dir)
    Application.put_env(:tiny_axe, :code_check, false)
    Application.put_env(:tiny_axe, :web_search, false)
    TinyAxe.Location.reset()
    set_claude_usage(0.1)
    %{dir: dir}
  end

  # The fake claude's answers are JSON of what it was given; these start so.
  defp from_claude?(text), do: String.starts_with?(text, ~s({"args":))

  defp model_of(text), do: text |> JSON.decode!() |> Map.fetch!("args") |> after_flag("--model")
  defp after_flag(args, flag), do: args |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)

  defp set_claude_usage(five_hour),
    do:
      :telemetry.execute([:tiny_axe, :model, :quota], %{}, %{
        backend: :claude,
        quota: %{status: "allowed", five_hour: five_hour, seven_day: 0.2}
      })

  # The local model answers "local N"; the verifier rejects those and accepts
  # anything from Claude (or, with `claude_ok: false`, rejects that too).
  defp script(opts \\ []) do
    counter = :counters.new(1, [])

    Model.Script.script(fn _, _ ->
      :counters.add(counter, 1, 1)
      "local #{:counters.get(counter, 1)}"
    end)

    local_scores = %{"local 1" => 0.3, "local 2" => 0.5, "local 3" => 0.4}
    claude = if Keyword.get(opts, :claude_ok, true), do: 0.95, else: 0.2

    Decider.Script.script(fn
      :kind, _, _ -> :question
      :addresses, _, %{response: r} -> if from_claude?(r), do: claude, else: local_scores[r]
      _, _, _ -> nil
    end)
  end

  # Runs a request in a task, as the TUI does; `answer` replies to {:ask_remote, ...}.
  defp run(prompt, remote, answer \\ nil) do
    me = self()

    task =
      Task.async(fn ->
        Pipeline.run([], prompt, &send(me, {:event, &1}), remote: remote)
      end)

    # collect/3 takes the task's reply itself, so there's nothing to await.
    events = collect(task, answer, [])
    events ++ drain([])
  end

  defp collect(task, answer, acc) do
    receive do
      {:event, {:ask_remote, ask} = e} ->
        send(ask.reply_to, {:remote_answer, ask.ref, answer})
        collect(task, answer, [e | acc])

      {:event, e} ->
        collect(task, answer, [e | acc])

      {ref, _result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        Enum.reverse(acc)
    after
      30_000 -> flunk("the request never finished")
    end
  end

  defp drain(acc) do
    receive do
      {:event, e} -> drain([e | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp done(events), do: Enum.find_value(events, fn e -> match?({:done, _}, e) && elem(e, 1) end)
  defp all(events, tag), do: for({^tag, v} <- events, do: v)

  describe "answering" do
    test "when the local model falls short and the user allows it, Claude answers" do
      script()
      events = run("Something hard", :allowed)

      assert [%{to: "Claude haiku", reason: why}] = all(events, :escalate)
      assert why =~ "no answer reached the verifier's threshold (the best scored 50/100)"
      assert from_claude?(done(events))
      assert model_of(done(events)) == "haiku"
      assert {:answered_by, %{model: "Claude haiku"}} in events
      # Three local attempts, then Claude's first.
      assert length(all(events, :attempt)) == 4
    end

    test "Claude starts afresh: it gets the request, not the local model's failed attempts" do
      script()
      events = run("Something hard", :allowed)

      stdin = done(events) |> JSON.decode!() |> Map.fetch!("stdin")
      assert stdin =~ "Something hard"
      refute stdin =~ "local 1"
    end

    test "a request the local model handles never leaves the machine" do
      Model.Script.script(fn _, _ -> "Paris." end)

      Decider.Script.script(fn
        :kind, _, _ -> :question
        :addresses, _, _ -> 0.95
        _, _, _ -> nil
      end)

      events = run("Capital of France?", :ask, true)
      assert done(events) == "Paris."
      assert all(events, :ask_remote) == [] and all(events, :escalate) == []
    end

    test "with :ask, the user is asked once; yes lets Claude answer" do
      script()
      events = run("Something hard", :ask, true)

      assert [%{to: "Claude haiku", reason: _}] = all(events, :ask_remote)
      assert from_claude?(done(events))
    end

    test "no keeps everything local, and the best local attempt is the answer" do
      script()
      events = run("Something hard", :ask, false)

      assert length(all(events, :ask_remote)) == 1
      assert all(events, :escalate) == []

      assert [%{reason: "you said no to sending requests off this machine"}] =
               all(events, :escalate_skipped)

      assert done(events) == "local 2"
      assert {:chose, %{attempt: 2, score: 0.5, attempts: 3}} in events
    end

    test "denied for the session: nothing is asked or sent" do
      script()
      events = run("Something hard", :denied)

      assert all(events, :ask_remote) == [] and all(events, :escalate) == []
      assert done(events) == "local 2"
    end

    test "escalation switched off in config: the ladder is empty" do
      script()
      Application.put_env(:tiny_axe, :escalate, false)
      events = run("Something hard", :allowed)

      assert all(events, :escalate) == [] and all(events, :escalate_skipped) == []
      assert done(events) == "local 2"
    end

    test "if haiku falls short too, sonnet is next; if both do, the best attempt overall wins" do
      script(claude_ok: false)
      events = run("Something hard", :allowed)

      assert [
               %{to: "Claude haiku"},
               %{to: "Claude sonnet", reason: "Claude haiku fell short too"}
             ] =
               all(events, :escalate)

      # Two attempts each for haiku and sonnet; none beat local 2's 50.
      assert length(all(events, :attempt)) == 7
      assert done(events) == "local 2"
      refute Enum.any?(events, &match?({:answered_by, _}, &1))
    end

    test "Claude near its usage limit is skipped, so tiny-axe never uses up the user's quota" do
      script()
      set_claude_usage(0.93)
      events = run("Something hard", :allowed)

      assert all(events, :escalate) == []
      assert [%{reason: why} | _] = all(events, :escalate_skipped)
      assert why =~ "at 93% of its 5-hour window"
      assert done(events) == "local 2"
    end

    test "a bigger model that errors is reported, and the local answer still comes back" do
      script()
      events = run("SCENARIO:not_logged_in Something hard", :allowed)

      assert [%{to: "Claude haiku", reason: {:not_logged_in, :claude}}, %{to: "Claude sonnet"}] =
               all(events, :escalate_failed)

      assert done(events) == "local 2"
    end

    @tag :sandbox
    test "code that still fails its check escalates, with the failure as the reason" do
      Application.put_env(:tiny_axe, :code_check, true)

      Model.Script.script(fn _, _ ->
        "```elixir\ndefmodule Broken do\n  def f(, do: 1\nend\n```"
      end)

      Decider.Script.script(fn
        :kind, _, _ -> :code
        :addresses, _, %{response: r} -> if from_claude?(r), do: 0.95, else: 0.9
        _, _, _ -> nil
      end)

      events = run("Write a module", :allowed)

      assert [%{reason: why}] = all(events, :escalate)
      assert why =~ "the code still failed its check (does not compile) after 3 attempts"
      assert from_claude?(done(events))
    end
  end

  describe "planning" do
    test "a file plan the local model can't make work goes to Claude", %{dir: dir} do
      # Every local plan moves a file that doesn't exist.
      Model.Script.script(fn _, _ ->
        JSON.encode!(%{
          look: [],
          mkdir: [],
          copy: [],
          trash: [],
          move: [%{from: "~/nowhere.pdf", to: "~/Papers/"}],
          write: [],
          reply: "Moving it."
        })
      end)

      Decider.Script.script(fn
        :organize, _, _ -> 0.95
        _, _, _ -> nil
      end)

      File.mkdir_p!(Path.join(dir, "Papers"))
      events = run("Move nowhere.pdf into Papers", :allowed)

      assert [%{to: "Claude haiku", reason: "its file plan still had problems after 5 tries"}] =
               all(events, :escalate)

      # The fake answers the plan's JSON Schema with a reply and no steps.
      assert done(events) =~ "--json-schema"
      assert {:answered_by, %{model: "Claude haiku"}} in events
    end

    test "commands the local model can't get past the checks go to Claude", %{dir: dir} do
      app = Path.join(dir, "app")
      File.mkdir_p!(app)
      {:ok, _} = TinyAxe.Location.cd(app)

      Model.Script.script(fn _, _ ->
        JSON.encode!(%{commands: ["sudo npm install"], reply: "Installing."})
      end)

      Decider.Script.script(fn
        :command, _, _ -> 0.95
        _, _, _ -> nil
      end)

      events = run("Install the dependencies", :allowed)

      assert [%{to: "Claude haiku", reason: "its commands still had problems after 4 tries"}] =
               all(events, :escalate)

      assert done(events) =~ "--json-schema"
    end
  end

  test "calls that leave the machine are counted, and Claude's usage kept" do
    before = TinyAxe.Escalation.stats().remote_calls
    {:ok, _} = Model.chat([%{role: "user", content: "hi"}], use: {:claude, "haiku"})

    # Counted by a cast, so wait for it to land.
    assert Enum.any?(1..50, fn _ ->
             Process.sleep(10)
             TinyAxe.Escalation.stats().remote_calls > before
           end)

    assert TinyAxe.Escalation.stats().quota.claude.five_hour == 0.09
  end
end
