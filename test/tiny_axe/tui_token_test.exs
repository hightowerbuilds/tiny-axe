defmodule TinyAxe.TUITokenTest do
  @moduledoc "/token, the panel's Token tab (`TinyAxe.TUI.TokenDash`): each part, the empty state, keys."

  use ExUnit.Case, async: false

  alias ExRatatui.Event
  alias TinyAxe.TUI

  @size {100, 50}

  defp draw(state) do
    {w, h} = @size
    terminal = ExRatatui.init_test_terminal(w, h)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: w, height: h}))
    ExRatatui.get_buffer_content(terminal)
  end

  defp key(state, code) do
    case TUI.handle_event(%Event.Key{code: code, kind: "press", modifiers: []}, state) do
      {:noreply, state} -> state
      {:noreply, state, _opts} -> state
    end
  end

  defp type(state, text) do
    ExRatatui.textarea_set_value(state.input, text)
    key(state, "enter")
  end

  defp mounted do
    {:ok, state} = TUI.mount(test_mode: @size)
    state
  end

  defp backend(fields \\ %{}) do
    Map.merge(
      %{
        calls: 0,
        errors: 0,
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        by_kind: %{}
      },
      fields
    )
  end

  defp range(fields \\ %{}),
    do: Map.merge(%{claude: backend(), jev: backend(), ollama: backend()}, fields)

  defp zero_hours, do: List.duplicate(0, 24)

  defp summary(fields) do
    Map.merge(
      %{
        session: range(),
        today: range(),
        week: range(),
        hours: %{claude: zero_hours(), jev: zero_hours(), ollama: zero_hours()},
        quota: nil
      },
      fields
    )
  end

  defp with_summary(state, s),
    do: %{state | panel: %{state.panel | token: %{state.panel.token | summary: s}}}

  defp busy do
    claude = fn n ->
      backend(%{
        calls: n,
        input: 1_000 * n,
        cache_write: 200 * n,
        cache_read: 30_000 * n,
        output: 400 * n,
        by_kind: %{answer: 1, agent: n - 2, subagent: 1}
      })
    end

    summary(%{
      session:
        range(%{claude: claude.(3), jev: backend(%{calls: 12, input: 21_400, output: 912})}),
      today:
        range(%{
          claude: claude.(4),
          jev: backend(%{calls: 40, errors: 1, input: 66_000, output: 2_800}),
          ollama: backend(%{calls: 52, input: 96_000, output: 8_000})
        }),
      week:
        range(%{
          claude: claude.(9),
          jev: backend(%{calls: 904, errors: 3, input: 498_000, output: 21_100}),
          ollama: backend(%{calls: 1_100, input: 2_100_000, output: 180_000})
        }),
      hours: %{
        claude: List.replace_at(zero_hours(), 14, 5_000),
        jev: zero_hours() |> List.replace_at(9, 100) |> List.replace_at(10, 800),
        ollama: zero_hours()
      },
      quota: %{five_hour: 0.41, seven_day: 0.93, resets_at: nil, status: "allowed"}
    })
  end

  test "/token opens the panel on its tab without asking a model; esc closes it" do
    state = mounted() |> type("/token")
    assert state.panel.tab == :token
    assert state.run == nil
    assert state.transcript == []
    assert ExRatatui.textarea_get_value(state.input) == ""
    assert draw(state) =~ "updates as calls finish"

    # Keys don't reach the prompt while it's open.
    state = key(state, "x")
    assert state.panel.tab == :token
    assert ExRatatui.textarea_get_value(state.input) == ""

    state = key(state, "esc")
    assert state.panel == nil
    refute draw(state) =~ "updates as calls finish"
  end

  test "each part: Haiku, its windows, Jev, Gemma, today by hour" do
    screen = mounted() |> type("/token") |> with_summary(busy()) |> draw()

    # Haiku: calls, input with cache writes, cache reads, output, the kinds.
    assert screen =~ ~r/Claude Haiku 5\.5\s+session\s+today\s+7 days/
    assert screen =~ ~r/calls\s+3\s+4\s+9/
    assert screen =~ ~r/input\s+3\.6k\s+4\.8k\s+11k/
    assert screen =~ ~r/read from cache\s+90k\s+120k\s+270k/
    assert screen =~ ~r/output\s+1\.2k\s+1\.6k\s+3\.6k/
    assert screen =~ "7 days: 1 answers · 7 agent runs · 1 sub-agents"

    # The numbers' right edges line up under the headings', and rows are indented.
    edge = fn re ->
      [line] = screen |> String.split("\n") |> Enum.filter(&(&1 =~ re))
      [{pos, len}] = Regex.run(re, line, return: :index)
      String.length(binary_part(line, 0, pos + len))
    end

    heading = edge.(~r/Claude Haiku 5\.5\s+session\s+today\s+7 days/)
    assert edge.(~r/Gemma\s+session\s+today\s+7 days/) == heading
    assert edge.(~r/calls\s+3\s+4\s+9/) == heading
    assert edge.(~r/read from cache\s+90k\s+120k\s+270k/) == heading
    assert edge.(~r/decisions\s+12\s+40\s+904/) == heading
    assert edge.(~r/calls\s+0\s+52\s+1\.1k/) == heading
    assert screen =~ "│     read from cache"

    # Its windows, and where tiny-axe stops.
    assert screen =~ ~r/5-hour window\s+█+░+\s+41%/u
    assert screen =~ ~r/7-day window\s+█+░*\s+93%/u
    assert screen =~ "tiny-axe stops using Claude at 90% of either"

    # Jev, with its errors; Gemma, with the local model's name.
    assert screen =~ ~r/decisions\s+12\s+40\s+904/
    assert screen =~ ~r/errors\s+0\s+1\s+3/
    assert screen =~ ~r/Gemma\s+session\s+today\s+7 days/
    assert screen =~ "gemma4:e4b-it-qat, on this computer"
    assert screen =~ ~r/input\s+0\s+96k\s+2\.1M/

    # Today by hour: a row for each backend used today, none for one that wasn't.
    assert screen =~ "Today by hour"
    assert screen =~ ~r/Haiku\s+·{14}█·{9}\s+5\.0k/u
    assert screen =~ ~r/Jev\s+·{9}▁█·{13}\s+900/u
    refute screen =~ ~r/Gemma\s+[·▁-█]{24}/u
  end

  test "nothing yet: says so, and when Claude's windows will show" do
    screen = mounted() |> type("/token") |> with_summary(summary(%{})) |> draw()
    assert screen =~ "No Haiku, Jev or Gemma calls in the last 7 days yet."
    assert screen =~ "Claude's usage windows show once it answers this session"
    refute screen =~ "Today by hour"
  end

  test "a backend with no calls says none; the others still show" do
    s = summary(%{week: range(%{jev: backend(%{calls: 2, input: 10, output: 1})})})
    screen = mounted() |> type("/token") |> with_summary(s) |> draw()
    assert screen =~ ~r/decisions\s+0\s+0\s+2/
    assert length(Regex.scan(~r/none in the last 7 days/, screen)) == 2
  end

  test "it updates while open: a call recorded shows on the next refresh" do
    state = mounted() |> type("/token")
    %{ref: ref} = state.panel.token
    before = state.panel.token.summary.session.jev.calls

    TinyAxe.Usage.emit(:jev, :decision, "jev-token-dash", %{input: 5, output: 1}, true, 3)

    # The refresh it scheduled for itself, which schedules the next.
    assert_receive {:token_dash, ^ref}, 2_000
    {:noreply, state} = TUI.handle_info({:token_dash, ref}, state)
    assert state.panel.token.summary.session.jev.calls == before + 1
    assert state.panel.token.ref != ref

    # An old refresh, or one after it's closed, does nothing.
    {:noreply, same} = TUI.handle_info({:token_dash, ref}, state)
    assert same.panel.token == state.panel.token

    closed = key(state, "esc")
    assert {:noreply, ^closed, _} = TUI.handle_info({:token_dash, state.panel.token.ref}, closed)
  end

  test "a question that comes up while it's open goes on top and gets the keys" do
    state = mounted() |> type("/token")

    ask = %{
      tool: "create_issue",
      server: "github",
      class: :outward,
      args: %{},
      description: nil,
      reply_to: self(),
      ref: make_ref()
    }

    state = %{state | tool_ask: ask}
    assert draw(state) =~ "allow this tool call?"

    state = key(state, "y")
    assert_receive {:tool_answer, _, :once}
    assert state.tool_ask == nil
    assert draw(state) =~ "updates as calls finish"
  end

  test "short counts" do
    alias TinyAxe.TUI.TokenDash

    assert Enum.map([0, 912, 4_100, 612_000, 2_140_000, 21_000_000], &TokenDash.short/1) ==
             ["0", "912", "4.1k", "612k", "2.1M", "21M"]
  end
end
