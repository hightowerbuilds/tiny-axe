defmodule TinyAxe.TUIEscalationTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event
  alias TinyAxe.TUI

  @size {110, 32}

  defp draw(state) do
    {w, h} = @size
    terminal = ExRatatui.init_test_terminal(w, h)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: w, height: h}))
    ExRatatui.get_buffer_content(terminal)
  end

  defp key(code), do: %Event.Key{code: code, kind: "press", modifiers: []}

  defp running do
    {:ok, state} = TUI.mount(test_mode: @size)
    id = make_ref()

    %{
      state
      | run: {id, self()},
        pending_prompt: "something hard",
        transcript: [{:user, "something hard"}]
    }
  end

  defp event(%{run: {id, _}} = state, event) do
    {:noreply, state} = TUI.handle_info({:pipeline, id, event}, state)
    state
  end

  defp ask(state) do
    ref = make_ref()

    ask = %{
      to: "Claude haiku",
      reason: "no answer reached the verifier's threshold (the best scored 50/100)",
      reply_to: self(),
      ref: ref
    }

    {event(state, {:ask_remote, ask}), ref}
  end

  test "asks before the first request leaves the machine, saying what would go" do
    {state, _ref} = ask(running())
    screen = draw(state)

    assert screen =~ "Send this request to Claude haiku?"
    # Long lines wrap, so each ends on screen rather than being cut off.
    assert screen =~ "50/100)."
    assert screen =~ "It leaves this machine"
    assert screen =~ "on your subscription (never an API key)."
    assert screen =~ "y yes, for this session"
  end

  test "y answers the waiting request and allows it for the rest of the session" do
    {state, ref} = ask(running())
    {:noreply, state} = TUI.handle_event(key("y"), state)

    assert_received {:remote_answer, ^ref, true}
    assert state.asking == nil
    assert state.remote == true
    assert List.last(state.transcript) |> elem(1) =~ "allowed Claude and Codex for this session"
  end

  test "n (or esc) keeps everything local for the session" do
    for k <- ["n", "esc"] do
      {state, ref} = ask(running())
      {:noreply, state} = TUI.handle_event(key(k), state)

      assert_received {:remote_answer, ^ref, false}
      assert state.remote == false
      assert state.run != nil, "#{k} answered the question; it didn't cancel the request"
    end
  end

  test "other keys don't answer, and don't reach the prompt" do
    {state, _ref} = ask(running())
    {:noreply, state} = TUI.handle_event(key("x"), state)

    refute_received {:remote_answer, _, _}
    assert state.asking != nil
    assert ExRatatui.textarea_get_value(state.input) == ""
  end

  test "escalation, a skipped rung (once per request) and who answered are shown" do
    state =
      running()
      |> event({:escalate, %{to: "Claude haiku", reason: "the code still failed its check"}})
      |> event(
        {:escalate_skipped, %{to: "Claude sonnet", reason: "the claude subscription is at 93%"}}
      )
      |> event(
        {:escalate_skipped, %{to: "Claude sonnet", reason: "the claude subscription is at 93%"}}
      )
      |> event({:escalate_failed, %{to: "Codex gpt-6-luna", reason: {:not_logged_in, :codex}}})
      |> event({:answered_by, %{model: "Claude haiku"}})

    metas = for {:meta, m} <- state.transcript, do: m

    assert "↗ Claude haiku: the local model fell short (the code still failed its check)" in metas
    assert Enum.count(metas, &(&1 =~ "not using a bigger model")) == 1
    assert "✗ Codex gpt-6-luna couldn't answer: not logged in: run `codex login`" in metas
    assert "→ answered by Claude haiku, off this machine" in metas
  end

  test "the status bar counts calls that left the machine" do
    :telemetry.execute([:tiny_axe, :model, :call], %{ms: 1}, %{remote: true, backend: :claude})

    assert Enum.any?(1..50, fn _ ->
             Process.sleep(10)
             TinyAxe.Escalation.stats().remote_calls > 0
           end)

    {:ok, state} = TUI.mount(test_mode: @size)
    assert draw(state) =~ "off-machine"
  end
end
