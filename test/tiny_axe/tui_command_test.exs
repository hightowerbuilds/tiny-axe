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
    assert screen =~ "only this folder can be changed; network on"
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
             &match?({:meta, "✗ stopped: `echo made > made.txt && false` exited with 1" <> _}, &1)
           )

    # The location follows the commands to the folder they ran in.
    assert TinyAxe.Location.current() == dir
    assert {:meta, "📍 moved to " <> _} = List.last(state.transcript)

    # The model's next turn will know what actually ran.
    assert List.last(state.history).content =~ "$ echo hello from the sandbox → exited 0"

    screen = draw(state)
    assert screen =~ "✓ exit 0"
    assert screen =~ "✗ exit 1"
  end

  test "n cancels without running anything", %{tmp_dir: dir} do
    state = with_plan(dir, ["touch ran.txt"]) |> key("n")
    assert state.pending_commands == nil
    refute File.exists?(Path.join(dir, "ran.txt"))
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
