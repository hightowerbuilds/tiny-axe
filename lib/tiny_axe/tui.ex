defmodule TinyAxe.TUI do
  @moduledoc """
  The terminal UI: a scrolling transcript, a status bar, and a multiline prompt.

  Keys: `enter` send · `alt+enter` newline · `esc` cancel · `pgup`/`pgdn` scroll
  (and `↑`/`↓`/`home`/`end` with an empty prompt) · `ctrl+y` copy the newest code
  block, again for the one before · `ctrl+z` undo the last file plan ·
  `ctrl+l` clear · `ctrl+c` quit. When the model proposes file edits, each is
  shown as a diff: `y` save · `n` skip · `esc` skip the rest · `↑`/`↓` scroll.
  """

  use ExRatatui.App

  alias ExRatatui.Event
  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Markdown, Paragraph, Popup, Textarea, Throbber}
  alias TinyAxe.Files

  @input_height 6
  @tick_ms 100

  @impl true
  def mount(opts) do
    input = ExRatatui.textarea_new()
    # Test-mode TUIs keep to themselves unless a test asks for the shared session.
    session? = Keyword.get(opts, :session, opts[:test_mode] == nil)

    saved =
      if session?,
        do: TinyAxe.Session.restore(),
        else: %{history: [], transcript: [], crashed: nil}

    restored =
      if saved.crashed,
        do: [
          {:meta,
           "the screen crashed (#{crash_summary(saved.crashed)}) and restarted; your conversation was restored"}
        ],
        else: []

    size =
      case Keyword.get(opts, :test_mode) || ExRatatui.terminal_size() do
        {w, h} -> {w, h}
        _ -> {80, 24}
      end

    {:ok,
     %{
       input: input,
       # Completed turns sent back to the model as context.
       history: saved.history,
       # What the transcript shows: {:user | :assistant | :meta, text}
       transcript: saved.transcript ++ restored,
       streaming: nil,
       pending_prompt: nil,
       # Transcript index where the current attempt's meta lines start.
       attempt_meta_from: 0,
       run: nil,
       # Proposed file edits awaiting y/n, first one shown; each carries its diff.
       pending_edits: [],
       edit_scroll: 0,
       # A file plan awaiting y/n, the plan being carried out, and a monitor on
       # the Runner so a crash there surfaces as an interrupted plan.
       pending_plan: nil,
       plan_scroll: 0,
       ops_job: nil,
       ops_monitor: nil,
       # An interrupted plan found in the journal, awaiting r/c/k.
       recovery: List.first(TinyAxe.Ops.Journal.interrupted()),
       # The plan ctrl+z would undo, awaiting y/n.
       confirm_undo: nil,
       status: "ready",
       # :bottom follows new output; a line number keeps the view on that line.
       scroll: :bottom,
       size: size,
       tick: 0,
       halt_on_exit: Keyword.get(opts, :halt_on_exit, false),
       session?: session?,
       # How many code blocks back the next ctrl+y copies; reset by each new request.
       copy_back: 0,
       # Tests swap in a function that doesn't touch the real clipboard.
       clipboard: Keyword.get(opts, :clipboard, &TinyAxe.Clipboard.copy/1)
     }}
  end

  ## Rendering

  @impl true
  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [transcript_area, status_area, input_area] = split(area)

    size = {frame.width, frame.height}

    transcript = %Markdown{
      content: Enum.join(entries_markdown(state), "\n\n"),
      scroll: {view_top(state, size), 0},
      block: %Block{
        title: title(state, size),
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray}
      }
    }

    input = %Textarea{
      state: state.input,
      placeholder: "Ask for code or text…  (enter to send, alt+enter for newline)",
      placeholder_style: %Style{fg: :dark_gray},
      wrap_mode: :word,
      block: %Block{
        title: " prompt ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: if(state.run, do: :dark_gray, else: :cyan)}
      }
    }

    [{transcript, transcript_area}, {status_widget(state), status_area}, {input, input_area}] ++
      overlay(state, area)
  end

  # At most one popup at a time, most urgent first.
  defp overlay(%{recovery: plan} = state, area) when plan != nil do
    done = map_size(plan.done)

    lines =
      [
        styled("A plan was interrupted after #{done} of #{length(plan.steps)} steps.", :yellow, [
          :bold
        ]),
        styled("Request: #{plan.request}"),
        styled("")
      ] ++
        (plan.steps
         |> Enum.with_index()
         |> Enum.map(fn {op, i} ->
           {mark, color} =
             cond do
               Map.has_key?(plan.done, i) -> {"✓ ", :green}
               i == plan.in_progress -> {"… ", :yellow}
               true -> {"  ", :dark_gray}
             end

           styled(mark <> TinyAxe.Ops.describe(op), color)
         end)) ++
        [
          styled(""),
          styled(
            "r roll back (undo the finished steps) · c continue · k keep as is · esc later",
            :dark_gray
          )
        ]

    popup(" recover interrupted plan ", lines, state.plan_scroll, area)
  end

  defp overlay(%{confirm_undo: plan} = state, area) when plan != nil do
    steps = plan.done |> Map.keys() |> Enum.sort() |> Enum.map(&Enum.at(plan.steps, &1))

    lines =
      [styled("Undo this plan?", :cyan, [:bold]), styled("Request: #{plan.request}"), styled("")] ++
        Enum.map(steps, &styled("↶ " <> TinyAxe.Ops.describe(&1))) ++
        [
          styled(""),
          styled(
            "Anything changed since is left alone; files taken away go to tiny-axe's trash.",
            :dark_gray
          ),
          styled("y undo · n keep", :dark_gray)
        ]

    popup(" undo ", lines, state.plan_scroll, area)
  end

  defp overlay(%{pending_plan: plan} = state, area) when plan != nil do
    review_color = if plan.review >= 0.5, do: :green, else: :yellow

    header = [
      Line.new([
        Span.new("tiny-axe will do this once you approve", style: %Style{modifiers: [:bold]}),
        Span.new(" · reviewer: #{pct(plan.review)}", style: %Style{fg: review_color})
      ]),
      styled("y do it · n cancel · ↑/↓ scroll", :dark_gray),
      styled("")
    ]

    body = Enum.flat_map(plan.ops, &plan_step_lines/1)
    popup(" carry out this plan? ", header ++ body, state.plan_scroll, area)
  end

  defp overlay(state, area), do: edit_popup(state, area)

  defp plan_step_lines(op) do
    doubt =
      case op[:review] do
        p when is_number(p) and p < 0.5 ->
          Span.new("  ⚠ reviewer #{pct(p)}", style: %Style{fg: :yellow})

        _ ->
          Span.new("")
      end

    # Trash steps stand out: they're the ones that take things away.
    style = if op.op == :trash, do: %Style{fg: :red}, else: %Style{}
    step = Line.new([Span.new("• " <> TinyAxe.Ops.describe(op), style: style), doubt])

    case op do
      %{op: :write, content: content} = w ->
        {lines, added, removed} = Files.diff(w.old, content)
        check = if w[:check], do: " · reviewer #{pct(w.check)}", else: ""
        summary = if w.old, do: "+#{added} −#{removed}", else: "#{added} lines"

        [step, styled("    #{summary}#{check}", :dark_gray)] ++
          Enum.map(lines, &diff_line(&1, "    ")) ++ [styled("")]

      _ ->
        [step]
    end
  end

  defp diff_line({:ins, l}, pad), do: styled(pad <> "+ " <> l, :green)
  defp diff_line({:del, l}, pad), do: styled(pad <> "- " <> l, :red)
  defp diff_line({:eq, l}, pad), do: styled(pad <> "  " <> l, :dark_gray)
  defp diff_line(:gap, pad), do: styled(pad <> "  ⋯", :dark_gray)

  defp styled(text, fg \\ nil, modifiers \\ []) do
    Line.new([Span.new(text, style: %Style{fg: fg, modifiers: modifiers})])
  end

  defp popup(title, lines, scroll, area) do
    [
      {%Popup{
         content: %Paragraph{text: lines, scroll: {scroll, 0}},
         block: %Block{
           title: title,
           borders: [:all],
           border_type: :rounded,
           border_style: %Style{fg: :cyan}
         },
         percent_width: 90,
         percent_height: 85
       }, area}
    ]
  end

  defp edit_popup(%{pending_edits: []}, _area), do: []

  defp edit_popup(%{pending_edits: [edit | rest]} = state, area) do
    {lines, added, removed} = edit.diff
    dim = %Style{fg: :dark_gray}

    summary =
      if edit.old == nil, do: " (new file, #{added} lines)", else: " (+#{added} −#{removed})"

    shrunk? = edit.old != nil and String.length(edit.new) < String.length(edit.old) / 2

    header =
      [
        Line.new([
          Span.new(edit.path, style: %Style{fg: :cyan, modifiers: [:bold]}),
          Span.new(summary)
        ]),
        shrunk? &&
          Line.new([
            Span.new("⚠ The new version is less than half the size. Check nothing was dropped.",
              style: %Style{fg: :yellow}
            )
          ]),
        Line.new([Span.new("y save · n skip · esc skip the rest · ↑/↓ scroll", style: dim)]),
        Line.new([Span.new("")])
      ]
      |> Enum.filter(& &1)

    body =
      Enum.map(lines, fn
        {:ins, l} -> Line.new([Span.new("+ " <> l, style: %Style{fg: :green})])
        {:del, l} -> Line.new([Span.new("- " <> l, style: %Style{fg: :red})])
        {:eq, l} -> Line.new([Span.new("  " <> l, style: dim)])
        :gap -> Line.new([Span.new("  ⋯", style: dim)])
      end)

    more = if rest == [], do: "", else: " · #{length(rest)} more after this"

    popup = %Popup{
      content: %Paragraph{text: header ++ body, scroll: {state.edit_scroll, 0}},
      block: %Block{
        title: " save this change?#{more} ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :cyan}
      },
      percent_width: 90,
      percent_height: 85
    }

    [{popup, area}]
  end

  defp split(area) do
    Layout.split(area, :vertical, [{:fill, 1}, {:length, 1}, {:length, @input_height}])
  end

  # When scrolled up, how far is shown first, so a long title can't cut it off.
  defp title(state, size) do
    scroll =
      if state.scroll == :bottom,
        do: "",
        else: " ↓#{max_top(state, size) - view_top(state, size)} lines below · end to follow ·"

    "#{scroll} tiny-axe · #{Files.display(Files.root())} · #{model()} · decider: #{decider_name()} "
  end

  defp status_widget(%{run: nil} = state) do
    %Paragraph{
      text:
        " #{state.status}  ·  pgup/pgdn/↑/↓ scroll · ctrl+y copy code · ctrl+z undo · ctrl+l clear · ctrl+c quit",
      style: %Style{fg: :dark_gray}
    }
  end

  defp status_widget(state) do
    %Throbber{label: " " <> state.status, step: state.tick, throbber_style: %Style{fg: :cyan}}
  end

  # One Markdown string per transcript entry; the transcript is these joined
  # by blank lines, which renders exactly as tall as the entries plus one line
  # between each.
  defp entries_markdown(state) do
    streaming = if state.streaming, do: [{:assistant, state.streaming <> " ▌"}], else: []
    Enum.map(state.transcript ++ streaming, &entry_markdown/1)
  end

  defp entry_markdown({:user, text}), do: "#### ▍you\n\n" <> keep_indent(text)
  defp entry_markdown({:assistant, text}), do: "#### ▍tiny-axe\n\n" <> keep_indent(text)
  defp entry_markdown({:meta, text}), do: "*· " <> text <> "*"

  # The Markdown widget wraps with trimming, which strips the indentation from
  # code blocks. Non-breaking spaces survive trimming, so leading spaces in
  # code blocks (including one still streaming) become those.
  defp keep_indent(text) do
    Regex.replace(~r/```.*?(```|\z)/s, text, fn block, _ ->
      Regex.replace(~r/^[ \t]+/m, block, fn indent ->
        indent |> String.replace("\t", "  ") |> String.replace(" ", "\u00A0")
      end)
    end)
  end

  ## Scrolling

  # The first transcript line in view.
  defp view_top(state, size) do
    case state.scroll do
      :bottom -> max_top(state, size)
      top -> min(top, max_top(state, size))
    end
  end

  defp max_top(state, {w, h}) do
    inner_h = max(h - 1 - @input_height - 2, 1)
    max(transcript_height(state, max(w - 2, 1)) - inner_h, 0)
  end

  # Scrolling to the end resumes following new output.
  defp scroll_to(state, top) do
    top = max(top, 0)

    if top >= max_top(state, state.size),
      do: %{state | scroll: :bottom},
      else: %{state | scroll: top}
  end

  defp scroll_by(state, lines), do: scroll_to(state, view_top(state, state.size) + lines)

  # The rendered height of the transcript at `width`. The Markdown widget can't
  # report it and an estimate drifts (25 lines over 800), so entries are
  # rendered off-screen and measured. Finished entries never change, so their
  # heights are cached, in the process dictionary because render can't update
  # state; only the entry still streaming is measured every frame.
  defp transcript_height(state, width) do
    {cached_width, cache} = Process.get(:tiny_axe_heights, {width, %{}})
    cache = if cached_width == width, do: cache, else: %{}

    {heights, cache} =
      Enum.map_reduce(state.transcript, cache, fn entry, cache ->
        md = entry_markdown(entry)
        key = {:erlang.phash2(md), byte_size(md)}

        case cache do
          %{^key => height} ->
            {height, cache}

          _ ->
            height = measure(md, width)
            {height, Map.put(cache, key, height)}
        end
      end)

    Process.put(:tiny_axe_heights, {width, cache})

    streaming =
      if state.streaming,
        do: [measure(entry_markdown({:assistant, state.streaming <> " ▌"}), width)],
        else: []

    heights = heights ++ streaming
    Enum.sum(heights) + max(length(heights) - 1, 0)
  end

  @max_rows 60_000

  defp measure(md, width, rows \\ nil) do
    rows =
      rows ||
        min(2 * (length(String.split(md, "\n")) + div(String.length(md), width)) + 8, @max_rows)

    terminal = ExRatatui.init_test_terminal(width, rows)

    ExRatatui.draw(terminal, [
      {%Markdown{content: md}, %Rect{x: 0, y: 0, width: width, height: rows}}
    ])

    lines = terminal |> ExRatatui.get_buffer_content() |> String.split("\n")
    blank_tail = lines |> Enum.reverse() |> Enum.take_while(&(String.trim(&1) == "")) |> length()
    used = length(lines) - blank_tail

    # Filled to the last row: it may not have fit, so measure again with room to spare.
    if used >= rows and rows < @max_rows,
      do: measure(md, width, min(rows * 2, @max_rows)),
      else: used
  end

  ## Input

  # Every event and message goes through these, so the conversation is saved
  # outside this process after any change (see TinyAxe.Session).
  @impl true
  def handle_event(event, state), do: event |> on_event(state) |> saved(state)

  @impl true
  def handle_info(msg, state), do: msg |> on_info(state) |> saved(state)

  defp saved(result, before) do
    now = elem(result, 1)

    if now.session? and (now.transcript != before.transcript or now.history != before.history),
      do: TinyAxe.Session.save(now.history, now.transcript)

    result
  end

  defp on_event(%Event.Key{kind: "release"}, state), do: {:noreply, state}

  defp on_event(%Event.Key{code: "c", modifiers: ["ctrl"]}, state), do: {:stop, cancel(state)}

  # While a popup is on screen, keys answer it instead of going to the prompt.
  defp on_event(%Event.Key{code: code}, %{recovery: plan} = state) when plan != nil do
    action =
      case code do
        "r" -> &TinyAxe.Ops.Runner.roll_back/2
        "c" -> &TinyAxe.Ops.Runner.continue/2
        "k" -> &TinyAxe.Ops.Runner.keep/2
        _ -> nil
      end

    cond do
      action ->
        {:noreply, start_ops(%{state | recovery: nil, plan_scroll: 0}, plan.id, action)}

      code == "esc" ->
        meta = "the interrupted plan is still in the journal; tiny-axe will ask again next start"
        {:noreply, %{state | recovery: nil, transcript: state.transcript ++ [{:meta, meta}]}}

      true ->
        {:noreply, scroll_plan(code, state)}
    end
  end

  defp on_event(%Event.Key{code: code}, %{confirm_undo: plan} = state) when plan != nil do
    case code do
      "y" ->
        state = %{state | confirm_undo: nil, plan_scroll: 0}
        {:noreply, start_ops(state, plan.id, &TinyAxe.Ops.Runner.undo_plan/2)}

      c when c in ["n", "esc"] ->
        {:noreply, %{state | confirm_undo: nil, plan_scroll: 0, status: "ready"}}

      _ ->
        {:noreply, scroll_plan(code, state)}
    end
  end

  defp on_event(%Event.Key{code: code}, %{pending_plan: plan} = state) when plan != nil do
    case code do
      "y" ->
        state = %{state | pending_plan: nil, plan_scroll: 0}

        {:noreply,
         start_ops(state, nil, fn _id, me ->
           TinyAxe.Ops.Runner.run(plan.request, plan.ops, me)
         end)}

      c when c in ["n", "esc"] ->
        meta = "plan cancelled; nothing changed"

        {:noreply,
         %{
           state
           | pending_plan: nil,
             plan_scroll: 0,
             status: "ready",
             transcript: state.transcript ++ [{:meta, meta}]
         }}

      _ ->
        {:noreply, scroll_plan(code, state)}
    end
  end

  defp on_event(%Event.Key{code: "z", modifiers: ["ctrl"]}, %{run: nil, ops_job: nil} = state) do
    case TinyAxe.Ops.Journal.last_undoable() do
      nil -> {:noreply, %{state | transcript: state.transcript ++ [{:meta, "nothing to undo"}]}}
      plan -> {:noreply, %{state | confirm_undo: plan, plan_scroll: 0}}
    end
  end

  # While an edit is on screen, keys answer it instead of going to the prompt.
  defp on_event(%Event.Key{code: code}, %{pending_edits: [edit | _]} = state) do
    {:noreply, edit_key(code, edit, state)}
  end

  defp on_event(%Event.Key{code: "esc"}, %{run: run} = state) when run != nil do
    {:noreply, %{cancel(state) | status: "cancelled"}}
  end

  defp on_event(%Event.Key{code: "l", modifiers: ["ctrl"]}, %{run: nil} = state) do
    {:noreply,
     %{state | history: [], transcript: [], pending_edits: [], scroll: :bottom, status: "cleared"}}
  end

  defp on_event(%Event.Key{code: "enter", modifiers: []}, state), do: submit(state)

  defp on_event(%Event.Key{code: "enter"}, state) do
    ExRatatui.textarea_handle_key(state.input, "enter", [])
    {:noreply, state}
  end

  defp on_event(%Event.Key{code: "y", modifiers: ["ctrl"]}, state), do: {:noreply, copy(state)}

  defp on_event(%Event.Key{code: "page_up"}, state),
    do: {:noreply, scroll_by(state, -page(state))}

  defp on_event(%Event.Key{code: "page_down"}, state),
    do: {:noreply, scroll_by(state, page(state))}

  # With an empty prompt, arrows, home and end scroll the transcript. Terminals
  # also turn the mouse wheel into arrow keys, so this makes the wheel scroll.
  defp on_event(%Event.Key{code: code, modifiers: []} = key, state)
       when code in ["up", "down", "home", "end"] do
    if ExRatatui.textarea_get_value(state.input) == "" do
      {:noreply,
       case code do
         "up" -> scroll_by(state, -3)
         "down" -> scroll_by(state, 3)
         "home" -> scroll_to(state, 0)
         "end" -> %{state | scroll: :bottom}
       end}
    else
      ExRatatui.textarea_handle_key(state.input, key.code, key.modifiers)
      {:noreply, state}
    end
  end

  defp on_event(%Event.Key{code: code, modifiers: mods}, state) do
    ExRatatui.textarea_handle_key(state.input, code, mods)
    {:noreply, state}
  end

  defp on_event(%Event.Paste{content: content}, state) do
    ExRatatui.textarea_insert_str(state.input, content)
    {:noreply, state}
  end

  defp on_event(%Event.Resize{width: w, height: h}, state) do
    {:noreply, %{state | size: {w, h}}}
  end

  defp on_event(_event, state), do: {:noreply, state}

  ## Copying

  # Copies the newest code block, then older ones on each press; with no code
  # blocks, the last answer. The transcript keeps the original text, so the
  # copy has ordinary spaces (not the ones used to keep indentation on screen).
  defp copy(state) do
    answers = for {:assistant, text} <- Enum.reverse(state.transcript), do: text

    blocks =
      Enum.flat_map(answers, fn text ->
        ~r/```([^\n]*)\n(.*?)```/s
        |> Regex.scan(text, capture: :all_but_first)
        |> Enum.reverse()
      end)

    {text, label} =
      case {blocks, answers} do
        {[], []} ->
          {nil, nil}

        {[], [last | _]} ->
          {last, "the last answer"}

        _ ->
          [info, code] = Enum.at(blocks, rem(state.copy_back, length(blocks)))
          lang = info |> String.split() |> List.first("code")
          n = rem(state.copy_back, length(blocks)) + 1
          lines = code |> String.split("\n", trim: true) |> length()
          {code, "#{lang} block #{n} of #{length(blocks)} (#{lines} lines)"}
      end

    if text == nil do
      %{state | status: "nothing to copy yet"}
    else
      case state.clipboard.(text) do
        :ok ->
          more = if length(blocks) > 1, do: " · ctrl+y again for the one before", else: ""
          %{state | copy_back: state.copy_back + 1, status: "copied #{label}#{more}"}

        {:error, reason} ->
          hint = if reason == :no_clipboard_tool, do: " (install wl-clipboard)", else: ""
          %{state | status: "couldn't copy: #{inspect(reason)}#{hint}"}
      end
    end
  end

  defp page(%{size: {_w, h}}), do: max(h - @input_height - 4, 1)

  defp edit_key("y", edit, state) do
    meta =
      case Files.write(edit.abs, edit.new, edit.old) do
        :ok ->
          {_, added, removed} = edit.diff
          "✓ saved #{edit.path} (+#{added} −#{removed})"

        {:error, :changed_on_disk} ->
          "✗ didn't save #{edit.path}: it changed on disk since tiny-axe read it"

        {:error, reason} ->
          "✗ couldn't save #{edit.path}: #{inspect(reason)}"
      end

    next_edit(state, meta)
  end

  defp edit_key("n", edit, state), do: next_edit(state, "skipped the change to #{edit.path}")

  defp edit_key("esc", _edit, state) do
    skipped = Enum.map(state.pending_edits, &{:meta, "skipped the change to #{&1.path}"})
    %{state | pending_edits: [], transcript: state.transcript ++ skipped, status: "ready"}
  end

  defp edit_key(code, _edit, state) when code in ["down", "j"],
    do: %{state | edit_scroll: state.edit_scroll + 1}

  defp edit_key(code, _edit, state) when code in ["up", "k"],
    do: %{state | edit_scroll: max(state.edit_scroll - 1, 0)}

  defp edit_key("page_down", _edit, state),
    do: %{state | edit_scroll: state.edit_scroll + page(state)}

  defp edit_key("page_up", _edit, state),
    do: %{state | edit_scroll: max(state.edit_scroll - page(state), 0)}

  defp edit_key(_code, _edit, state), do: state

  defp next_edit(%{pending_edits: [_ | rest]} = state, meta) do
    %{
      state
      | pending_edits: rest,
        edit_scroll: 0,
        transcript: state.transcript ++ [{:meta, meta}],
        status: if(rest == [], do: "ready", else: state.status)
    }
  end

  defp submit(%{run: run} = state) when run != nil, do: {:noreply, state}

  defp submit(state) do
    prompt = state.input |> ExRatatui.textarea_get_value() |> String.trim()

    if prompt == "" do
      {:noreply, state}
    else
      ExRatatui.textarea_set_value(state.input, "")
      {:noreply, start_run(state, prompt)}
    end
  end

  defp start_run(state, prompt) do
    tui = self()
    id = make_ref()
    history = state.history

    {:ok, pid} =
      Task.Supervisor.start_child(TinyAxe.TaskSupervisor, fn ->
        TinyAxe.Pipeline.run(history, prompt, &send(tui, {:pipeline, id, &1}))
      end)

    Process.monitor(pid)
    Process.send_after(self(), :tick, @tick_ms)

    %{
      state
      | run: {id, pid},
        pending_prompt: prompt,
        transcript: state.transcript ++ [{:user, prompt}],
        streaming: nil,
        scroll: :bottom,
        copy_back: 0,
        status: "routing…"
    }
  end

  defp cancel(%{run: nil} = state), do: state

  defp cancel(%{run: {_id, pid}} = state) do
    Process.exit(pid, :kill)
    partial = if state.streaming in [nil, ""], do: [], else: [{:assistant, state.streaming}]

    %{
      state
      | run: nil,
        streaming: nil,
        transcript: state.transcript ++ partial ++ [{:meta, "cancelled"}]
    }
  end

  ## Pipeline events

  defp on_info({:pipeline, id, event}, %{run: {id, _pid}} = state) do
    {:noreply, apply_event(event, state)}
  end

  defp on_info({:pipeline, _stale_id, _event}, state), do: {:noreply, state, render?: false}

  defp on_info(:tick, %{run: nil} = state), do: {:noreply, state, render?: false}

  defp on_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, %{state | tick: state.tick + 1}}
  end

  defp on_info({:DOWN, _ref, :process, pid, reason}, %{run: {_id, pid}} = state)
       when reason not in [:normal, :killed] do
    {:noreply, fail(state, Exception.format_exit(reason))}
  end

  defp on_info({:ops, id, event}, %{ops_job: id} = state),
    do: {:noreply, ops_event(event, state)}

  # A result for a job the user already moved past (e.g. after a Runner restart).
  defp on_info({:ops, _id, event}, state), do: {:noreply, ops_event(event, state)}

  # The Runner died mid-job: the plan is now interrupted in the journal.
  defp on_info({:DOWN, ref, :process, _pid, reason}, %{ops_monitor: ref} = state) do
    meta = "the file runner crashed (#{inspect(reason)}); its plan is safe in the journal"

    {:noreply,
     %{
       state
       | ops_job: nil,
         ops_monitor: nil,
         recovery: List.first(TinyAxe.Ops.Journal.interrupted()),
         transcript: state.transcript ++ [{:meta, meta}],
         status: "ready"
     }}
  end

  defp on_info(_msg, state), do: {:noreply, state, render?: false}

  ## File plans

  # `fun` is a Runner call taking (id, reply_to).
  defp start_ops(state, id, fun) do
    case fun.(id, self()) do
      result when result == :ok or elem(result, 0) == :ok ->
        id = if result == :ok, do: id, else: elem(result, 1)
        ref = Process.monitor(TinyAxe.Ops.Runner)
        %{state | ops_job: id, ops_monitor: ref, status: "working on files…"}

      {:error, reason} ->
        meta = "✗ couldn't start: #{inspect(reason)}"
        %{state | transcript: state.transcript ++ [{:meta, meta}], status: "ready"}
    end
  end

  defp scroll_plan(code, state) do
    case code do
      c when c in ["down", "j"] -> %{state | plan_scroll: state.plan_scroll + 1}
      c when c in ["up", "k"] -> %{state | plan_scroll: max(state.plan_scroll - 1, 0)}
      "page_down" -> %{state | plan_scroll: state.plan_scroll + page(state)}
      "page_up" -> %{state | plan_scroll: max(state.plan_scroll - page(state), 0)}
      _ -> state
    end
  end

  defp ops_event({:progress, i, total}, state), do: %{state | status: "step #{i} of #{total}…"}
  defp ops_event({:note, text}, state), do: add_meta(state, "· " <> text)

  defp ops_event({:finished, n}, state),
    do: ops_done(state, ["✓ done: #{n} #{plural(n, "step")} · ctrl+z undoes it"])

  defp ops_event({:stopped, i, error}, state) do
    ops_done(state, [
      "✗ stopped at step #{i + 1}: #{error}",
      "the steps before it stand · ctrl+z undoes them"
    ])
  end

  defp ops_event({:interrupted, reason}, state) do
    state = ops_done(state, ["✗ the plan was interrupted (#{inspect(reason)})"])
    %{state | recovery: List.first(TinyAxe.Ops.Journal.interrupted())}
  end

  defp ops_event({:continue_refused, problems}, state) do
    state = ops_done(state, ["✗ can't continue the plan:" | Enum.map(problems, &("  " <> &1))])
    %{state | recovery: List.first(TinyAxe.Ops.Journal.interrupted())}
  end

  defp ops_event({kind, notes}, state) when kind in [:rolled_back, :kept, :undone] do
    label = %{rolled_back: "↶ rolled back", kept: "kept the plan as it was", undone: "↶ undone"}
    ops_done(state, [label[kind] | Enum.map(notes, &("  " <> &1))])
  end

  defp ops_event(_event, state), do: state

  defp ops_done(state, lines) do
    if state.ops_monitor, do: Process.demonitor(state.ops_monitor, [:flush])
    state = Enum.reduce(lines, state, &add_meta(&2, &1))
    %{state | ops_job: nil, ops_monitor: nil, status: "ready"}
  end

  defp add_meta(state, text), do: %{state | transcript: state.transcript ++ [{:meta, text}]}

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp apply_event({:route, %{kind: kind} = route}, state) do
    web =
      Enum.map_join([web: "web", files: "files", change: "change"], fn {key, label} ->
        if route[key], do: " · #{label} #{pct(route[key].noul)}", else: ""
      end)

    meta =
      "route → #{kind.choice} (#{pct(kind.probabilities[kind.choice])}, confidence #{pct(kind.confidence)})" <>
        web

    %{
      state
      | transcript: state.transcript ++ [{:meta, meta}],
        status: "generating (#{kind.choice})…"
    }
  end

  defp apply_event({:search, s}, state) do
    meta =
      "web: searched #{inspect(s.query)} on #{s.engine} · #{s.results} results, read #{s.read} pages"

    %{state | transcript: state.transcript ++ [{:meta, meta}], status: "generating…"}
  end

  defp apply_event({:files, %{read: read, listed: n}}, state) do
    what = if read == [], do: "no file contents", else: Enum.join(read, ", ")
    meta = "files: read #{what} · #{n} files in the project"
    %{state | transcript: state.transcript ++ [{:meta, meta}], status: "generating…"}
  end

  defp apply_event({:edits, edits}, state) do
    edits = Enum.map(edits, &Map.put(&1, :diff, Files.diff(&1.old, &1.new)))
    %{state | pending_edits: state.pending_edits ++ edits, edit_scroll: 0}
  end

  defp apply_event({:edit_refused, %{path: path, reason: reason}}, state) do
    %{
      state
      | transcript:
          state.transcript ++ [{:meta, "✗ not offering the change to #{path}: #{reason}"}]
    }
  end

  defp apply_event({:plan, plan}, state), do: %{state | pending_plan: plan, plan_scroll: 0}

  defp apply_event({:looked, dirs}, state),
    do: add_meta(state, "looked in #{Enum.join(dirs, ", ")}")

  defp apply_event({:plan_problems, problems}, state),
    do: add_meta(state, "plan sent back to the model: " <> Enum.join(problems, " "))

  defp apply_event({:wrote, %{path: path, check: p}}, state),
    do: add_meta(state, "drafted #{path} (reviewer #{pct(p)})")

  defp apply_event({:review, _}, state), do: state

  defp apply_event({:search_failed, s}, state) do
    meta =
      "web: search for #{inspect(s.query)} failed (#{inspect(s.reason)}), answering without it"

    %{state | transcript: state.transcript ++ [{:meta, meta}], status: "generating…"}
  end

  defp apply_event({:attempt, 1}, state),
    do: %{state | streaming: "", attempt_meta_from: length(state.transcript)}

  defp apply_event({:attempt, n}, state) do
    transcript = state.transcript ++ [{:meta, "retrying (attempt #{n})"}]

    %{
      state
      | streaming: "",
        transcript: transcript,
        attempt_meta_from: length(transcript),
        status: "generating (attempt #{n})…"
    }
  end

  defp apply_event({:stage, label}, state), do: %{state | status: label}

  defp apply_event({:check, {:skipped, reason}}, state)
       when reason in ["no Elixir or Python code", "disabled"],
       do: state

  defp apply_event({:check, {:skipped, reason}}, state) do
    %{state | transcript: state.transcript ++ [{:meta, "· code not checked: #{reason}"}]}
  end

  defp apply_event({:check, {:ran, %{status: :passed} = r}}, state) do
    %{state | transcript: state.transcript ++ [{:meta, "✓ #{r.language}: #{r.summary}"}]}
  end

  defp apply_event({:check, {:ran, %{status: :failed} = r}}, state) do
    first_line = r.output |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 120)
    detail = if first_line == "", do: "", else: " — `#{first_line}`"
    %{state | transcript: state.transcript ++ [{:meta, "✗ #{r.language}: #{r.summary}#{detail}"}]}
  end

  defp apply_event({:delta, text}, state),
    do: %{state | streaming: (state.streaming || "") <> text}

  defp apply_event({:verify, %{addresses: v}}, state) do
    %{
      state
      | transcript: state.transcript ++ [{:meta, "verifier: addresses request #{pct(v.noul)}"}],
        status: "verifying…"
    }
  end

  # The answer will be an earlier attempt, so it goes below every attempt's lines.
  defp apply_event({:chose, c}, state) do
    meta = "showing attempt #{c.attempt} of #{c.attempts}, the highest-rated (#{pct(c.score)})"
    transcript = state.transcript ++ [{:meta, meta}]
    %{state | transcript: transcript, attempt_meta_from: length(transcript)}
  end

  defp apply_event({:done, text}, state) do
    turn = [%{role: "user", content: state.pending_prompt}, %{role: "assistant", content: text}]

    # The answer goes above the check/verifier lines that judged it.
    {before, judged} = Enum.split(state.transcript, state.attempt_meta_from)

    %{
      state
      | run: nil,
        streaming: nil,
        pending_prompt: nil,
        history: state.history ++ turn,
        transcript: before ++ [{:assistant, text} | judged],
        status: if(state.pending_edits == [], do: "ready", else: "review the proposed change")
    }
  end

  defp apply_event({:error, reason}, state), do: fail(state, inspect(reason))

  defp fail(state, message) do
    %{
      state
      | run: nil,
        streaming: nil,
        pending_prompt: nil,
        transcript: state.transcript ++ [{:meta, "error: " <> message}],
        status: "error"
    }
  end

  defp pct(nil), do: "?"
  defp pct(p), do: "#{round(p * 100)}%"

  @impl true
  # Only a real quit stops tiny-axe. After a crash the supervisor restarts the
  # TUI, which restores the conversation from TinyAxe.Session.
  def terminate(reason, state) do
    if quit?(reason) do
      if state.halt_on_exit, do: System.stop(0)
    else
      if state.session?, do: TinyAxe.Session.crashed(reason)
    end
  end

  defp quit?(reason), do: reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)

  defp crash_summary(reason) do
    reason |> Exception.format_exit() |> String.split("\n") |> hd() |> String.slice(0, 120)
  end

  defp model, do: Application.get_env(:tiny_axe, :model)

  defp decider_name do
    TinyAxe.Decider.impl() |> Module.split() |> List.last() |> String.downcase()
  end
end
