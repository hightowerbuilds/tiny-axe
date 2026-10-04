defmodule TinyAxe.TUIToolsTest do
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
    %{state | run: {make_ref(), self()}, transcript: [{:user, "post the release notes"}]}
  end

  defp event(%{run: {id, _}} = state, event) do
    {:noreply, state} = TUI.handle_info({:pipeline, id, event}, state)
    state
  end

  defp asking(state) do
    ref = make_ref()

    ask = %{
      tool: "github__create_issue",
      server: "github",
      description: "Opens an issue in a repository.",
      args: %{"repo" => "hightowerbuilds/tiny-axe", "title" => "Release notes for 0.2"},
      class: :outward,
      reply_to: self(),
      ref: ref
    }

    {event(state, {:tool_approval, ask}), ref}
  end

  test "an outward call shows the tool, what it does, and exactly what it would send" do
    {state, _} = asking(running())
    screen = draw(state)

    assert screen =~ "The agent wants to use github__create_issue"
    assert screen =~ "sends something off this machine"
    assert screen =~ "Release notes for 0.2"
    assert screen =~ "y allow once · a allow this tool for the session · n refuse"
  end

  test "y, a and n answer the waiting call" do
    for {k, answer} <- [{"y", :once}, {"a", :session}, {"n", :deny}, {"esc", :deny}] do
      {state, ref} = asking(running())
      {:noreply, state} = TUI.handle_event(key(k), state)

      assert_received {:tool_answer, ^ref, ^answer}
      assert state.tool_ask == nil
    end
  end

  test "cancelling the request refuses a waiting call, so the gate lets it go" do
    {state, ref} = asking(running())
    {:noreply, state} = TUI.handle_event(key("esc"), %{state | tool_ask: state.tool_ask})
    assert_received {:tool_answer, ^ref, :deny}
    assert state.tool_ask == nil
  end

  test "tool calls and refusals appear in the transcript" do
    state =
      running()
      |> event({:tool_call, %{tool: "web__search", class: :read, args: %{"q" => "elixir 1.19"}}})
      |> event(
        {:tool_result, %{tool: "web__search", decision: :ran, error: false, summary: "..."}}
      )
      |> event(
        {:tool_result,
         %{
           tool: "github__delete_repo",
           decision: :refused,
           error: true,
           summary: "tiny-axe stopped this call: tiny-axe doesn't allow this tool."
         }}
      )
      |> event({:tool_limit, %{reason: "the task reached its limit of 60 tool calls"}})

    metas = for {:meta, m} <- state.transcript, do: m

    assert ~s[🔧 web__search {"q":"elixir 1.19"} (only reads)] in metas
    assert Enum.any?(metas, &(&1 =~ "✗ github__delete_repo: tiny-axe stopped this call"))
    assert "⚠ the agent was stopped: the task reached its limit of 60 tool calls" in metas
    # A call that went through needs no line of its own.
    assert length(metas) == 3
  end
end
