defmodule TinyAxe.TUI.TokenDash do
  @moduledoc """
  `/token`: a popup of token use by Claude Haiku, Jev and the local model
  (`TinyAxe.Usage`), for this session, today and the last 7 days; Claude's
  usage windows; and today's tokens by hour. It refreshes every second while
  open, so a request finishing shows up; `esc` (or `q`) closes it. Questions
  (a tool call, a purchase) still come first, on top of it. Nothing in it
  goes to a model.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  import TinyAxe.TUI.Presentation, only: [styled: 1, styled: 2, styled: 3]

  @refresh 1_000
  @label 22
  @column 10
  @ranges [:session, :today, :week]
  @blocks ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

  @doc "Opens it: the numbers now, and the first refresh scheduled."
  def open, do: schedule(%{summary: fetch(), ref: nil})

  @doc "A refresh, if it's this dashboard's (an old one's is ignored)."
  def refresh(%{ref: ref} = dash, ref), do: schedule(%{dash | summary: fetch()})
  def refresh(dash, _stale), do: dash

  defp schedule(dash) do
    ref = make_ref()
    Process.send_after(self(), {:token_dash, ref}, @refresh)
    %{dash | ref: ref}
  end

  defp fetch do
    TinyAxe.Usage.summary()
  catch
    :exit, _ -> nil
  end

  @doc "How wide its widest line is."
  def width, do: 66

  @doc "Whether a key closes it; every other key is ignored while it's open."
  def close?(code), do: code in ["esc", "q", "enter"]

  ## What it shows

  def lines(dash, opts \\ [])

  def lines(%{summary: nil}, opts) do
    [
      styled(
        "tiny-axe isn't counting tokens right now (its usage record didn't answer).",
        :yellow
      ),
      styled(""),
      styled(if(opts[:page], do: "r refresh", else: "esc close"), :dark_gray)
    ]
  end

  def lines(%{summary: s}, opts) do
    body =
      if Enum.all?([:claude, :jev, :ollama], &(s.week[&1].calls == 0)) do
        [
          styled("No Haiku, Jev or Gemma calls in the last 7 days yet."),
          styled("They show up here as they happen.", :dark_gray),
          styled("")
        ] ++ windows(s.quota)
      else
        claude(s) ++ [styled("")] ++ jev(s) ++ [styled("")] ++ gemma(s) ++ hours(s.hours)
      end

    hint =
      if opts[:page],
        do: "updates as calls finish · r refresh",
        else: "updates as calls finish · esc close"

    body ++ [styled(""), styled(hint, :dark_gray)]
  end

  defp claude(s) do
    totals = for r <- @ranges, do: s[r].claude

    if List.last(totals).calls == 0 do
      [heading("Claude Haiku 5.5"), none()] ++ windows(s.quota)
    else
      [
        heading("Claude Haiku 5.5"),
        row("calls", totals, & &1.calls),
        row("input", totals, &(&1.input + &1.cache_write)),
        row("  read from cache", totals, & &1.cache_read),
        row("output", totals, & &1.output)
      ] ++
        errors(totals) ++
        kinds(List.last(totals).by_kind) ++
        windows(s.quota)
    end
  end

  defp jev(s) do
    totals = for r <- @ranges, do: s[r].jev

    if List.last(totals).calls == 0 do
      [heading("Jev"), none()]
    else
      [
        heading("Jev"),
        row("decisions", totals, & &1.calls),
        row("input", totals, & &1.input),
        row("output", totals, & &1.output)
      ] ++ errors(totals)
    end
  end

  defp gemma(s) do
    totals = for r <- @ranges, do: s[r].ollama
    model = Application.get_env(:tiny_axe, :model)
    which = if model, do: [styled("  #{model}, on this computer", :dark_gray)], else: []

    if List.last(totals).calls == 0 do
      [heading("Gemma")] ++ which ++ [none()]
    else
      [heading("Gemma")] ++
        which ++
        [
          row("calls", totals, & &1.calls),
          row("input", totals, & &1.input),
          row("output", totals, & &1.output)
        ] ++ errors(totals)
    end
  end

  defp heading(name) do
    columns = Enum.map_join(["session", "today", "7 days"], &String.pad_leading(&1, @column))

    Line.new([
      Span.new(String.pad_trailing(name, @label), style: %Style{fg: :cyan, modifiers: [:bold]}),
      Span.new(columns, style: %Style{fg: :dark_gray})
    ])
  end

  defp row(label, totals, fun) do
    styled(
      "  " <>
        String.pad_trailing(label, @label - 2) <>
        Enum.map_join(totals, &String.pad_leading(short(fun.(&1)), @column))
    )
  end

  defp none, do: styled("  none in the last 7 days", :dark_gray)

  defp errors(totals) do
    if List.last(totals).errors > 0, do: [row("errors", totals, & &1.errors)], else: []
  end

  defp kinds(by_kind) do
    parts =
      for {kind, word} <- [answer: "answers", agent: "agent runs", subagent: "sub-agents"],
          n = by_kind[kind] || 0,
          n > 0,
          do: "#{n} #{word}"

    if parts == [], do: [], else: [styled("  7 days: " <> Enum.join(parts, " · "), :dark_gray)]
  end

  # Claude's 5-hour and 7-day windows, as its CLI last reported them.
  defp windows(quota) do
    stop = Application.get_env(:tiny_axe, :quota_stop, 0.9)

    shown =
      for {key, name} <- [five_hour: "5-hour window", seven_day: "7-day window"],
          used = (quota || %{})[key],
          is_number(used),
          do: window(name, used, stop)

    if shown == [] do
      [styled("  Claude's usage windows show once it answers this session", :dark_gray)]
    else
      resets = resets(quota[:resets_at])

      shown ++
        [
          styled(
            "  tiny-axe stops using Claude at #{round(stop * 100)}% of either" <>
              if(resets, do: " · resets #{resets}", else: ""),
            :dark_gray
          )
        ]
    end
  end

  defp window(name, used, stop) do
    filled = used |> min(1.0) |> max(0.0) |> Kernel.*(16) |> round()
    color = if used >= stop, do: :red, else: if(used >= 0.7, do: :yellow, else: :green)

    Line.new([
      Span.new("  " <> String.pad_trailing(name, @label - 2)),
      Span.new(String.duplicate("█", filled), style: %Style{fg: color}),
      Span.new(String.duplicate("░", 16 - filled), style: %Style{fg: :dark_gray}),
      Span.new(String.pad_leading("#{round(used * 100)}%", 5))
    ])
  end

  defp resets(at) when is_integer(at) do
    with {:ok, time} <- DateTime.from_unix(at) do
      {{_, _, _} = date, {h, m, _}} =
        time
        |> DateTime.to_naive()
        |> NaiveDateTime.to_erl()
        |> :calendar.universal_time_to_local_time()

      {today, _} = :calendar.local_time()
      clock = :io_lib.format("~2..0B:~2..0B", [h, m]) |> to_string()

      if date == today,
        do: clock,
        else: Calendar.strftime(Date.from_erl!(date), "%a ") <> clock
    else
      _ -> nil
    end
  end

  defp resets(_), do: nil

  # Today's tokens (in and out) by local hour, one mark an hour, each
  # backend scaled to its own busiest hour.
  defp hours(hours) do
    rows =
      for {backend, name} <- [claude: "Haiku", jev: "Jev", ollama: "Gemma"],
          by_hour = hours[backend],
          Enum.sum(by_hour) > 0 do
        top = Enum.max(by_hour)

        marks =
          Enum.map_join(by_hour, fn
            0 -> "·"
            n -> Enum.at(@blocks, min(7, max(0, ceil(n / top * 8) - 1)))
          end)

        Line.new([
          Span.new("  " <> String.pad_trailing(name, 7)),
          Span.new(marks, style: %Style{fg: :cyan}),
          Span.new(String.pad_leading(short(Enum.sum(by_hour)), 8))
        ])
      end

    if rows == [] do
      []
    else
      [styled(""), styled("Today by hour", :cyan, [:bold])] ++
        rows ++ [styled("         0     6     12    18   23", :dark_gray)]
    end
  end

  @doc "A token count, short: 912, 4.1k, 612k, 2.1M."
  def short(n) when n < 1000, do: "#{n}"
  def short(n) when n < 10_000, do: "#{Float.round(n / 1000, 1)}k"
  def short(n) when n < 1_000_000, do: "#{round(n / 1000)}k"
  def short(n) when n < 10_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def short(n), do: "#{round(n / 1_000_000)}M"
end
