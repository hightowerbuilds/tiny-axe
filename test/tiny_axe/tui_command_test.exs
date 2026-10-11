defmodule TinyAxe.TUICommandTest do
  @moduledoc "The command popup, driven through the real sandbox."

  # Running commands moves tiny-axe's (app-wide) location, so not async.
  use ExUnit.Case, async: false

  alias ExRatatui.Event
  alias TinyAxe.TUI

  @size {110, 40}
  @moduletag :tmp_dir

  setup do
    TinyAxe.Location.reset()
    on_exit(&TinyAxe.Location.reset/0)
    if TinyAxe.Shell.available?(), do: :ok, else: {:skip, "bwrap not installed"}
  end

  defp draw(state) do
    {w, h} = @size
    terminal = ExRatatui.init_test_terminal(w, h)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: w, height: h}))
    ExRatatui.get_buffer_content(terminal)
  end

  defp key(state, code) do
    {:noreply, state} =
      TUI.handle_event(%Event.Key{code: code, kind: "press", modifiers: []}, state)

    state
  end

  # Feeds the command runner's events to the TUI until the commands finish.
  defp settle(%{run: {id, _}} = state) do
    receive do
      {:pipeline, ^id, _} = msg ->
        {:noreply, state} = TUI.handle_info(msg, state)
        if state.run, do: settle(state), else: state
    after
      10_000 -> flunk("the commands never finished")
    end
  end

  defp plan(dir, commands) do
    %{
      request: "do it",
      dir: dir,
      commands: Enum.map(commands, &%{command: &1, review: 0.9}),
      review: 0.88
    }
  end

  defp with_plan(dir, commands) do
    {:ok, state} = TUI.mount(test_mode: @size)

    %{
      state
      | pending_commands: plan(dir, commands),
        history: [
          %{role: "user", content: "do it"},
          %{role: "assistant", content: "I'll run them."}
        ]
    }
  end

  test "approving runs the commands in the sandbox, streams output and records the results", %{
    tmp_dir: dir
  } do
    state =
      with_plan(dir, [
        "echo hello from the sandbox",
        "echo made > made.txt && false",
        "echo never"
      ])

    screen = draw(state)
    assert screen =~ "run these commands?"
    assert screen =~ "only this folder and tool installs"
    assert screen =~ "$ echo hello from the sandbox"

    state = state |> key("y") |> settle()

    assert File.read!(Path.join(dir, "made.txt")) == "made\n"

    assert Enum.any?(
             state.transcript,
             &match?({:output, "echo hello from the sandbox", "hello from the sandbox", 0}, &1)
           )

    assert Enum.any?(
             state.transcript,
             &match?({:output, "echo made > made.txt && false", "", 1}, &1)
           )

    refute Enum.any?(state.transcript, &match?({:output, "echo never", _, _}, &1))

    assert Enum.any?(
             state.transcript,
             &match?({:meta, "✗ stopped: `echo made > made.txt && false` exit 1" <> _}, &1)
           )

    # The location follows the commands to the folder they ran in.
    assert TinyAxe.Location.current() == dir
    assert {:meta, "📍 moved to " <> _} = List.last(state.transcript)

    # The model's next turn will know what actually ran: the proposal became
    # the record, led by what ran (later turns see only the start).
    record = List.last(state.history).content

    assert record =~
             ~r/\A\*Ran in .+, after you approved: `echo hello from the sandbox` → exit 0; /

    assert record =~ "(stopped there; 1 more didn't run)"
    assert record =~ "$ echo hello from the sandbox\nhello from the sandbox"
    refute record =~ "I'll run them."

    screen = draw(state)
    assert screen =~ "✓ exit 0"
    assert screen =~ "✗ exit 1"
  end

  test "n cancels without running anything, and the proposal says so", %{tmp_dir: dir} do
    state = with_plan(dir, ["touch ran.txt"])

    state = %{
      state
      | history: [
          %{role: "user", content: "do it"},
          %{role: "assistant", content: "**Commands** (waiting for your approval, in ~/x)"}
        ]
    }

    state = key(state, "n")
    assert state.pending_commands == nil
    refute File.exists?(Path.join(dir, "ran.txt"))
    assert List.last(state.history).content == "**Commands** (not run: you said no, in ~/x)"
  end

  test "the model reads an approved run's output and answers", %{tmp_dir: dir} do
    for {key, value} <- [command_answer: true, model_backend: nil, script_model: nil] do
      previous = Application.get_env(:tiny_axe, key)

      on_exit(fn ->
        if previous == nil,
          do: Application.delete_env(:tiny_axe, key),
          else: Application.put_env(:tiny_axe, key, previous)
      end)

      if value != nil, do: Application.put_env(:tiny_axe, key, value)
    end

    me = self()

    TinyAxe.Model.Script.script(fn messages, _opts ->
      send(me, {:asked, messages})
      "It printed 42."
    end)

    state = with_plan(dir, ["echo 42"]) |> key("y") |> settle()

    assert_received {:asked, [%{role: "system"}, %{role: "user", content: asked}]}
    assert asked =~ "Request: do it"
    assert asked =~ "$ echo 42\n(exit 0)\n42"

    assert {:assistant, "It printed 42."} in state.transcript
    assert state.streaming == nil
    [record, answer | _] = String.split(List.last(state.history).content, "\n\n")
    assert record =~ "*Ran in "
    assert answer == "It printed 42."
  end

  test "commands that only look show what's running instead of asking", %{tmp_dir: dir} do
    {:ok, state} = TUI.mount(test_mode: @size)
    plan = plan(dir, ["df -h"]) |> Map.put(:read_only, true)
    state = TinyAxe.TUI.CommandWorkflow.event({:command_plan, plan}, state)

    assert state.pending_commands == nil

    assert {:meta, "running without asking (they only look), in " <> rest} =
             List.last(state.transcript)

    assert rest =~ "`df -h`"
  end

  test "esc stops a running command, sandbox included", %{tmp_dir: dir} do
    state = with_plan(dir, ["echo started; sleep 30; touch finished.txt"]) |> key("y")
    %{run: {id, _}} = state

    # Wait until the command is running and its pid is known.
    state =
      Enum.reduce_while(1..200, state, fn _, st ->
        receive do
          {:pipeline, ^id, _} = msg ->
            {:noreply, st} = TUI.handle_info(msg, st)

            if st.running_cmd && st.running_cmd.os_pid && st.running_cmd.output =~ "started",
              do: {:halt, st},
              else: {:cont, st}
        after
          5_000 -> flunk("the command never started")
        end
      end)

    os_pid = state.running_cmd.os_pid
    state = key(state, "esc")

    assert state.run == nil
    assert Enum.any?(state.transcript, &match?({:output, _, "started", "cancelled"}, &1))
    Process.sleep(200)
    assert {_, 1} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    refute File.exists?(Path.join(dir, "finished.txt"))
  end
end
