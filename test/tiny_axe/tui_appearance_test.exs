defmodule TinyAxe.TUIAppearanceTest do
  @moduledoc "The appearance popup: a plan the reviewer doubted, approved with y."

  use ExUnit.Case, async: false

  alias ExRatatui.Event
  alias TinyAxe.{FakeDesktop, TUI}

  @size {110, 40}

  setup do
    on_exit(fn ->
      FakeDesktop.reset()
      File.rm(TinyAxe.Appearance.Undo.path())
    end)

    FakeDesktop.script(fn
      "omarchy", ["theme", "list"] -> {"Solitude\nGruvbox\n", 0}
      "omarchy", ["theme", "current"] -> {"Solitude\n", 0}
      "omarchy", ["theme", "set", _] -> {"", 0}
      _, _ -> {"", 1}
    end)

    :ok
  end

  defp draw(state) do
    {w, h} = @size
    terminal = ExRatatui.init_test_terminal(w, h)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: w, height: h}))
    ExRatatui.get_buffer_content(terminal)
  end

  defp settle(%{run: {id, _}} = state) do
    receive do
      {:pipeline, ^id, _} = msg ->
        {:noreply, state} = TUI.handle_info(msg, state)
        if state.run, do: settle(state), else: state
    after
      10_000 -> flunk("the change never finished")
    end
  end

  test "the popup shows the changes; y makes them and records the result" do
    {:ok, state} = TUI.mount(test_mode: @size)

    plan = %{
      kind: :appearance,
      request: "use gruvbox",
      changes: [%{"setting" => "theme", "value" => "Gruvbox"}],
      commands: [%{command: "theme → Gruvbox", review: nil}],
      review: nil,
      dir: TinyAxe.Location.current()
    }

    state = TinyAxe.TUI.CommandWorkflow.event({:appearance_plan, plan}, state)
    assert state.pending_commands == plan

    state = %{
      state
      | history: [
          %{role: "user", content: "use gruvbox"},
          %{role: "assistant", content: "**Appearance changes** (waiting for your approval)"}
        ]
    }

    screen = draw(state)
    assert screen =~ "change the look?"
    assert screen =~ "theme → Gruvbox"

    {:noreply, state} =
      TUI.handle_event(%Event.Key{code: "y", kind: "press", modifiers: []}, state)

    state = settle(state)
    assert state.pending_commands == nil
    assert_received {:desktop, "omarchy", ["theme", "set", "Gruvbox"]}
    assert List.last(state.history).content =~ "theme: Solitude → Gruvbox"
    assert List.last(state.history).content =~ "(approved)"
  end
end
