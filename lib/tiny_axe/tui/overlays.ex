defmodule TinyAxe.TUI.Overlays do
  @moduledoc """
  Builds the highest-priority approval or recovery popup from UI state.
  Rendering never accepts a decision or advances a workflow.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph, Popup}
  alias TinyAxe.Files
  import TinyAxe.TUI.Presentation

  # At most one popup at a time, most urgent first.
  def render(%{card_flow: flow}, area) when flow != nil do
    alias TinyAxe.TUI.CardFlow
    {name, kind, question} = CardFlow.step(flow)

    input =
      case kind do
        :secret ->
          [
            Line.new([
              Span.new("> " <> flow.display <> "▌",
                style: %Style{fg: :yellow, modifiers: [:bold]}
              )
            ])
          ]

        :text ->
          [
            Line.new([
              Span.new("> " <> flow.buffer <> "▌", style: %Style{fg: :yellow, modifiers: [:bold]})
            ])
          ]

        :choice ->
          Enum.map(CardFlow.choices(name), fn {k, _v, label} -> styled("  #{k}  #{label}") end)
      end

    lines =
      [
        styled(
          "Card details go only to tiny-axe's card vault (and your keyring, if it's remembered): " <>
            "never to a model, the transcript or a log. In the browser they're filled in only " <>
            "over https, after you confirm a purchase, and shown as dots.",
          :dark_gray
        ),
        styled("")
      ] ++
        Enum.map(CardFlow.summary_lines(flow), &styled("✓ " <> &1, :green)) ++
        [styled(""), styled(question, nil, [:bold])] ++
        input ++
        [
          flow.error && styled("✗ " <> flow.error, :red),
          styled(""),
          styled("enter next · esc cancel (nothing is saved)", :dark_gray)
        ]

    popup(" add a card ", Enum.filter(lines, & &1), 0, area)
  end

  def render(%{purchase_ask: ask}, area) when ask != nil do
    s = ask.summary
    red = %Style{fg: :red, modifiers: [:bold]}
    card_step? = ask[:mode] == :card_step

    warning =
      if card_step?,
        do: "This sends your card details to #{s["host"]}. Nothing is bought yet.",
        else: "This spends money. It can't be undone with ctrl+z."

    lines =
      [
        Line.new([Span.new(warning, style: red)]),
        styled(""),
        styled("Shop: #{s["host"]}", nil, [:bold]),
        !card_step? && styled("Total: #{s["total_text"]} #{s["currency"]}", nil, [:bold])
      ] ++
        Enum.map(s["items"] || [], &styled("  · " <> &1)) ++
        [
          s["ship_to"] && styled("Ship to: #{s["ship_to"]}"),
          styled("Paying with: #{s["paying_with"] || s["payment"] || "(not shown)"}"),
          styled("")
        ] ++
        Enum.map(ask.checks, fn
          {:ok, text} -> styled("✓ " <> text, :green)
          {:fail, text} -> styled("✗ " <> text, :red)
        end) ++
        [styled("")] ++
        purchase_prompt(ask) ++
        [
          ask[:hint] && styled(ask.hint, :yellow),
          styled("esc refuse", :dark_gray)
        ]

    [
      {%Popup{
         content: %Paragraph{text: Enum.filter(lines, & &1), wrap: true},
         block: %Block{
           title: if(card_step?, do: " use your card here? ", else: " buy this? "),
           borders: [:all],
           border_type: :rounded,
           border_style: %Style{fg: :red}
         },
         percent_width: 80,
         percent_height: 80
       }, area}
    ]
  end

  def render(%{asking: ask}, area) when ask != nil do
    lines = [
      styled("Send this request to #{ask.to}?", :cyan, [:bold]),
      styled(""),
      styled("Why: #{ask.reason}."),
      styled(""),
      styled(
        "It leaves this machine: the request, the recent conversation, any files and web " <>
          "pages it was given, and what its tools return go to #{ask.to} on your " <>
          "subscription (never an API key).",
        :yellow
      ),
      styled(""),
      styled("y yes, for this session · n no, keep everything local this session", :dark_gray)
    ]

    popup(" use a bigger model? ", lines, 0, area)
  end

  # The agent needs the user to do something in the browser window.
  def render(%{tool_ask: %{class: :handoff} = ask}, area) do
    lines = [
      styled("Your turn in the browser", :cyan, [:bold]),
      styled(""),
      styled("The agent needs you to: #{ask[:reason] || "do something in the browser"}."),
      styled(""),
      styled(
        "Do it in the browser window (tiny-axe never types passwords or card numbers), " <>
          "then come back here.",
        :yellow
      ),
      styled(""),
      styled("y done · n I won't", :dark_gray)
    ]

    popup(" over to you ", lines, 0, area)
  end

  def render(%{tool_ask: ask}, area) when ask != nil do
    args =
      case ask.args do
        args when args == %{} -> ["(no arguments)"]
        args -> args |> JSON.encode!() |> pretty_json() |> String.split("\n")
      end

    lines =
      [
        Line.new([
          Span.new("The agent wants to use ", style: %Style{modifiers: [:bold]}),
          Span.new(ask.tool, style: %Style{fg: :cyan, modifiers: [:bold]})
        ]),
        styled(
          "from the #{ask.server} MCP server · #{TinyAxe.Tools.Policy.describe(ask.class)}",
          :yellow
        ),
        ask[:reason] && styled("It #{ask.reason}.", :yellow, [:bold]),
        styled(""),
        ask.description && styled(ask.description, :dark_gray),
        ask.description && styled(""),
        styled("With:", nil, [:bold])
      ]
      |> Enum.filter(& &1)

    body = Enum.map(args, &styled("  " <> &1))

    keys =
      if Map.get(ask, :session_ok, true),
        do: "y allow once · a allow this tool for the session · n refuse",
        else: "y allow · n refuse"

    footer = [styled(""), styled(keys, :dark_gray)]

    popup(" allow this tool call? ", lines ++ body ++ footer, 0, area)
  end

  def render(%{recovery: plan} = state, area) when plan != nil do
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

  def render(%{confirm_undo: plan} = state, area) when plan != nil do
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

  def render(%{pending_commands: plan} = state, area) when plan != nil do
    {review_text, review_color} = review_label(plan.review)

    header = [
      Line.new([
        Span.new("tiny-axe will run these once you approve", style: %Style{modifiers: [:bold]}),
        Span.new(" · #{review_text}", style: %Style{fg: review_color})
      ]),
      # On its own line, so a long path can't push the note off the edge.
      styled("in #{TinyAxe.Ops.show(plan.dir)}", :cyan),
      styled("only this folder can be changed; network on", :cyan),
      styled("y run · n cancel · ↑/↓ scroll", :dark_gray),
      styled("")
    ]

    commands =
      Enum.map(plan.commands, fn c ->
        review_threshold = TinyAxe.Decider.review_threshold()

        doubt =
          case c.review do
            p when is_number(p) and p < review_threshold ->
              Span.new("  ⚠ review score #{score(p)}", style: %Style{fg: :yellow})

            _ ->
              Span.new("")
          end

        Line.new([Span.new("$ " <> c.command, style: %Style{modifiers: [:bold]}), doubt])
      end)

    footer = [styled(""), styled("Commands can't be undone with ctrl+z.", :dark_gray)]
    popup(" run these commands? ", header ++ commands ++ footer, state.plan_scroll, area)
  end

  def render(%{pending_plan: plan} = state, area) when plan != nil do
    {review_text, review_color} = review_label(plan.review)

    header = [
      Line.new([
        Span.new("tiny-axe will do this once you approve", style: %Style{modifiers: [:bold]}),
        Span.new(" · #{review_text}", style: %Style{fg: review_color})
      ]),
      styled("y do it · n cancel · ↑/↓ scroll", :dark_gray),
      styled("")
    ]

    body = Enum.flat_map(plan.ops, &plan_step_lines/1)
    popup(" carry out this plan? ", header ++ body, state.plan_scroll, area)
  end

  def render(state, area), do: edit_popup(state, area)

  defp plan_step_lines(op) do
    review_threshold = TinyAxe.Decider.review_threshold()

    doubt =
      case op[:review] do
        p when is_number(p) and p < review_threshold ->
          Span.new("  ⚠ review score #{score(p)}", style: %Style{fg: :yellow})

        _ ->
          Span.new("")
      end

    # Trash steps stand out: they're the ones that take things away.
    style = if op.op == :trash, do: %Style{fg: :red}, else: %Style{}
    step = Line.new([Span.new("• " <> TinyAxe.Ops.describe(op), style: style), doubt])

    case op do
      %{op: :write, content: content} = w ->
        {lines, added, removed} = Files.diff(w.old, content)
        check = if w[:check], do: " · review score #{score(w.check)}", else: ""
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

  # Long lines wrap rather than run off the edge: a command or warning cut off
  # there is one the user approves without seeing in full.
  defp popup(title, lines, scroll, area) do
    [
      {%Popup{
         content: %Paragraph{text: lines, scroll: {scroll, 0}, wrap: true},
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

  defp purchase_prompt(%{stage: :consent} = ask),
    do: [styled("Fill #{ask.summary["paying_with"]} in and continue? y yes · n no", nil, [:bold])]

  defp purchase_prompt(%{stage: :total} = ask) do
    [
      Line.new([
        Span.new("Type #{expected_total(ask.summary)} and press enter to buy: ",
          style: %Style{modifiers: [:bold]}
        ),
        Span.new(ask.typed <> "▌", style: %Style{fg: :yellow, modifiers: [:bold]})
      ])
    ]
  end

  defp purchase_prompt(%{stage: {:unlock, field}} = ask) do
    what = if field == :pin, do: "its PIN", else: "its CVC"

    [
      Line.new([
        Span.new("Type #{what} (it's sent only to tiny-axe's card vault), then enter: ",
          style: %Style{modifiers: [:bold]}
        ),
        Span.new(ask.masked <> "▌", style: %Style{fg: :yellow, modifiers: [:bold]})
      ])
    ]
  end

  defp pretty_json(json) do
    # Two-space indentation for nested arguments; short ones stay on one line.
    if String.length(json) < 70,
      do: json,
      else: json |> :json.decode() |> :json.format() |> IO.iodata_to_binary()
  end
end
