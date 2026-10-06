defmodule TinyAxe.TUI.Presentation do
  @moduledoc """
  Shared text and score formatting for the screen and transcript events.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}

  # A score, not a probability: nothing has measured how often an 84 is right.
  def review_label(p) when is_number(p) do
    color = if p >= TinyAxe.Decider.review_threshold(), do: :green, else: :yellow
    {"review score #{score(p)}", color}
  end

  def review_label(_unknown), do: {"no review score: check this yourself", :yellow}

  def score(p) when is_number(p), do: "#{round(p * 100)}/100"
  def score(_), do: "?"

  def styled(text, fg \\ nil, modifiers \\ []) do
    Line.new([Span.new(text, style: %Style{fg: fg, modifiers: modifiers})])
  end

  # How the total must be typed: 16.00.
  def expected_total(%{"total" => total}) when is_number(total),
    do: :erlang.float_to_binary(total * 1.0, decimals: 2)

  def expected_total(_), do: "?"

  def describe_class(:handoff), do: "needs you in the browser"
  def describe_class(:payment_step), do: "sends card details; asks you first"
  def describe_class(class), do: TinyAxe.Tools.Policy.describe(class)
end
