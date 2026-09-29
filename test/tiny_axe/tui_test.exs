defmodule TinyAxe.TUITest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event
  alias TinyAxe.TUI

  @size {100, 30}

  defp draw(state) do
    {w, h} = @size
    terminal = ExRatatui.init_test_terminal(w, h)
    ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: w, height: h}))
    ExRatatui.get_buffer_content(terminal)
  end

  defp key(code, mods \\ []), do: %Event.Key{code: code, kind: "press", modifiers: mods}

  test "renders pipeline progress and the accepted answer" do
    {:ok, state} = TUI.mount(test_mode: @size)
    id = make_ref()

    state = %{
      state
      | run: {id, self()},
        pending_prompt: "reverse a list",
        transcript: [{:user, "reverse a list"}]
    }

    route = %{kind: %{choice: :code, probabilities: %{code: 0.97}, confidence: 0.9}}

    state =
      Enum.reduce(
        [{:route, route}, {:attempt, 1}, {:delta, "Use `Enum.reverse/1`."}],
        state,
        fn ev, st -> st |> then(&TUI.handle_info({:pipeline, id, ev}, &1)) |> elem(1) end
      )

    screen = draw(state)
    assert screen =~ "route → code (97%"
    assert screen =~ "Enum.reverse/1"

    {:noreply, state} =
      TUI.handle_info({:pipeline, id, {:verify, %{addresses: %{noul: 0.91}}}}, state)

    {:noreply, state} = TUI.handle_info({:pipeline, id, {:done, "Use `Enum.reverse/1`."}}, state)

    assert state.run == nil
    assert [%{role: "user"}, %{role: "assistant"}] = state.history
    assert List.last(state.transcript) == {:meta, "verifier: addresses request 91%"}
    assert draw(state) =~ "ready"
  end

  test "shows the web search step" do
    {:ok, state} = TUI.mount(test_mode: @size)
    id = make_ref()
    state = %{state | run: {id, self()}, transcript: [{:user, "latest ollama?"}]}

    route = %{
      kind: %{choice: :question, probabilities: %{question: 0.9}, confidence: 0.8},
      web: %{noul: 0.95}
    }

    search = %{query: "ollama latest version", engine: :duckduckgo, results: 8, read: 3}

    state =
      Enum.reduce([{:route, route}, {:search, search}], state, fn ev, st ->
        st |> then(&TUI.handle_info({:pipeline, id, ev}, &1)) |> elem(1)
      end)

    screen = draw(state)
    assert screen =~ "web 95%"
    assert screen =~ ~s(searched "ollama latest version" on duckduckgo)
  end

  @tag :tmp_dir
  test "shows a proposed edit as a diff and saves it on y", %{tmp_dir: dir} do
    previous = Application.get_env(:tiny_axe, :project_dir)
    Application.put_env(:tiny_axe, :project_dir, dir)
    on_exit(fn -> Application.put_env(:tiny_axe, :project_dir, previous) end)

    path = Path.join(dir, "demo.ex")
    File.write!(path, "defmodule Demo do\n  def hi, do: :hi\nend\n")
    new = "defmodule Demo do\n  def hi, do: :hello\nend\n"

    {:ok, state} = TUI.mount(test_mode: @size)
    id = make_ref()
    state = %{state | run: {id, self()}, pending_prompt: "change hi", transcript: [{:user, "x"}]}
    edit = %{path: "demo.ex", abs: path, old: File.read!(path), new: new}

    state =
      Enum.reduce(
        [{:attempt, 1}, {:edits, [edit]}, {:done, "```elixir demo.ex\n#{new}```"}],
        state,
        fn ev, st ->
          st |> then(&TUI.handle_info({:pipeline, id, ev}, &1)) |> elem(1)
        end
      )

    screen = draw(state)
    assert screen =~ "save this change?"
    assert screen =~ "- " <> "  def hi, do: :hi"
    assert screen =~ "+ " <> "  def hi, do: :hello"

    # Typing goes to the popup, not the prompt.
    {:noreply, state} = TUI.handle_event(key("x"), state)
    assert state.pending_edits != []

    {:noreply, state} = TUI.handle_event(key("y"), state)
    assert state.pending_edits == []
    assert File.read!(path) == new
    assert List.last(state.transcript) == {:meta, "✓ saved demo.ex (+1 −1)"}
  end

  describe "scrolling" do
    @answer """
    Here is a function:

    ```elixir
    defmodule Demo do
      def double(x), do: x * 2
    end
    ```

    - a point long enough to wrap around the edge of the terminal when it is rendered in the transcript
    - another point
    """

    defp long_session(n \\ 25) do
      {:ok, state} = TUI.mount(test_mode: @size)

      transcript =
        Enum.flat_map(1..n, fn i ->
          [{:user, "QUESTION #{i} ASKED"}, {:assistant, @answer}, {:meta, "END OF ANSWER #{i}"}]
        end)

      %{state | transcript: transcript}
    end

    defp press(state, code, times \\ 1) do
      Enum.reduce(1..times, state, fn _, st ->
        {:noreply, st} = TUI.handle_event(key(code), st)
        st
      end)
    end

    # The transcript rows between the borders.
    defp transcript_rows(screen) do
      {_w, h} = @size
      screen |> String.split("\n") |> Enum.slice(1, h - 1 - 6 - 2)
    end

    test "reaches the very top, and page down responds at once" do
      state = long_session() |> press("page_up", 500)
      screen = draw(state)
      assert screen =~ "QUESTION 1 ASKED"
      assert screen =~ "lines below · end to follow"

      # Scrolling past the top doesn't pile up: one page down moves the view.
      assert draw(press(state, "page_down")) != screen
    end

    test "follows new output down to the exact last line" do
      rows = long_session() |> draw() |> transcript_rows()
      assert List.last(rows) =~ "END OF ANSWER 25"
    end

    test "a scrolled-up view stays put while new output arrives" do
      state = long_session() |> press("page_up", 3)
      before = state |> draw() |> transcript_rows()

      more = state.transcript ++ [{:user, "QUESTION 26 ASKED"}, {:assistant, @answer}]
      assert %{state | transcript: more} |> draw() |> transcript_rows() == before
    end

    test "arrows, home and end scroll when the prompt is empty, and edit it otherwise" do
      state = long_session()
      assert draw(press(state, "home")) =~ "QUESTION 1 ASKED"
      assert press(state, "up").scroll != :bottom
      assert state |> press("home") |> press("end") |> Map.get(:scroll) == :bottom

      ExRatatui.textarea_set_value(state.input, "draft")
      assert press(state, "up").scroll == :bottom
    end

    test "code blocks keep their indentation" do
      {:ok, state} = TUI.mount(test_mode: @size)
      state = %{state | transcript: [{:assistant, @answer}]}
      assert draw(state) =~ ~r/\n│\s{2}def double/u
    end
  end

  test "ctrl+y copies the newest code block, then older ones, with ordinary spaces" do
    me = self()

    {:ok, state} =
      TUI.mount(test_mode: @size, clipboard: fn text -> send(me, {:copied, text}) && :ok end)

    first = "```python\ndef a():\n    return 1\n```"

    second =
      "Two blocks:\n\n```elixir\ndefmodule B do\n  def b, do: 2\nend\n```\n\n```bash\nmix test\n```"

    state = %{state | transcript: [{:assistant, first}, {:user, "more"}, {:assistant, second}]}

    state = press_ctrl_y(state)
    assert_received {:copied, "mix test\n"}
    assert state.status =~ "copied bash block 1 of 3"

    state = press_ctrl_y(state)
    assert_received {:copied, "defmodule B do\n  def b, do: 2\nend\n"}

    state = press_ctrl_y(state)
    assert_received {:copied, "def a():\n    return 1\n"}

    # Round again to the newest.
    press_ctrl_y(state)
    assert_received {:copied, "mix test\n"}
  end

  test "ctrl+y with no code blocks copies the last answer" do
    me = self()

    {:ok, state} =
      TUI.mount(test_mode: @size, clipboard: fn text -> send(me, {:copied, text}) && :ok end)

    state = press_ctrl_y(%{state | transcript: [{:assistant, "Just prose."}]})
    assert_received {:copied, "Just prose."}
    assert state.status =~ "copied the last answer"
  end

  defp press_ctrl_y(state) do
    {:noreply, state} = TUI.handle_event(key("y", ["ctrl"]), state)
    state
  end

  describe "context and compaction" do
    defp chat_session(turns) do
      {:ok, state} = TUI.mount(test_mode: {140, 36})

      {history, transcript} =
        Enum.reduce(1..turns, {[], []}, fn i, {h, t} ->
          q = "QUESTION #{i} " <> String.duplicate("words ", 40)
          a = "ANSWER #{i} " <> String.duplicate("more words ", 60)

          {h ++ [%{role: "user", content: q}, %{role: "assistant", content: a}],
           t ++ [{:user, q}, {:meta, "route"}, {:assistant, a}]}
        end)

      %{state | history: history, transcript: transcript, size: {140, 36}}
    end

    defp draw_at(state, {w, h}) do
      terminal = ExRatatui.init_test_terminal(w, h)
      ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: w, height: h}))
      ExRatatui.get_buffer_content(terminal)
    end

    test "the status bar shows how full the context window is" do
      assert draw_at(chat_session(3), {140, 36}) =~ ~r/ctx \d+%/
    end

    test "ctrl+t shows and hides the sidebar with the meter" do
      state = chat_session(1)
      refute draw_at(state, {140, 36}) =~ " context "

      {:noreply, state} = TUI.handle_event(key("t", ["ctrl"]), state)
      screen = draw_at(state, {140, 36})
      assert screen =~ " context "
      assert screen =~ "▰"
      assert screen =~ "compacts at 50%"

      {:noreply, state} = TUI.handle_event(key("t", ["ctrl"]), state)
      refute draw_at(state, {140, 36}) =~ " context "
    end

    test "a finished compaction keeps the newest turns, shows the summary and marks the spot" do
      state = chat_session(5)
      id = make_ref()
      state = %{state | run: {id, self()}, compacting: ""}

      {:noreply, state} =
        TUI.handle_info({:pipeline, id, {:compact_delta, "- User asked five questions"}}, state)

      assert draw_at(state, {140, 36}) =~ "compacting…"

      result = %{summary: "- User asked five questions about words", turns: 3, check: 0.91}
      {:noreply, state} = TUI.handle_info({:pipeline, id, {:compacted, result}}, state)

      assert state.run == nil

      assert Enum.map(state.history, &String.slice(&1.content, 0, 10)) ==
               ["QUESTION 4", "ANSWER 4 m", "QUESTION 5", "ANSWER 5 m"]

      assert state.summary.before > state.summary.after

      # The marker sits just before the first kept turn.
      i = Enum.find_index(state.transcript, &match?({:meta, "▲" <> _}, &1))
      assert {:user, "QUESTION 4" <> _} = Enum.at(state.transcript, i + 1)

      screen = draw_at(state, {140, 36})
      assert screen =~ "compacted · 3 turns"
      assert screen =~ "reviewer 91%"
      assert screen =~ "User asked five questions about words"
    end

    test "a summary that wouldn't save space is dropped, keeping the turns" do
      state = chat_session(3)
      id = make_ref()
      state = %{state | run: {id, self()}, compacting: ""}
      long = %{summary: String.duplicate("far too long ", 400), turns: 1, check: 0.9}

      {:noreply, after_} = TUI.handle_info({:pipeline, id, {:compacted, long}}, state)
      assert after_.history == state.history
      assert after_.summary == nil
      assert {:meta, "compaction skipped" <> _} = List.last(after_.transcript)
    end

    test "ctrl+k with only the newest turns says there's nothing to compact" do
      {:noreply, state} = TUI.handle_event(key("k", ["ctrl"]), chat_session(2))
      assert state.run == nil
      assert state.status =~ "nothing to compact yet"
    end
  end

  test "ignores events from a stale run" do
    {:ok, state} = TUI.mount(test_mode: @size)
    state = %{state | run: {make_ref(), self()}}

    assert {:noreply, ^state, render?: false} =
             TUI.handle_info({:pipeline, make_ref(), {:delta, "x"}}, state)
  end

  test "runs headlessly under the real runtime and accepts typing" do
    {:ok, pid} = TUI.start_link(test_mode: @size, name: nil)

    for c <- String.graphemes("hello"), do: ExRatatui.Runtime.inject_event(pid, key(c))
    ExRatatui.Runtime.inject_event(pid, key("enter", ["alt"]))
    ExRatatui.Runtime.inject_event(pid, key("w"))

    snapshot = ExRatatui.Runtime.snapshot(pid)
    assert snapshot.polling_enabled? == false
    assert snapshot.render_count > 0
    assert Process.alive?(pid)
  end
end
