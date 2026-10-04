defmodule TinyAxe.Tools.Redact do
  @moduledoc """
  Removes payment card numbers from tool results and records before any
  model, Jev, log or journal sees them. A card number is 13–19 digits (spaces
  or dashes allowed between them) that pass the Luhn check, so order numbers
  and phone numbers are mostly left alone.

  This is the backstop for every tool. The browser server will redact on the
  page itself, by field, before anything leaves it (passwords included).
  """

  @card ~r/(?<![\d])(?:\d[ -]?){12,18}\d(?![\d])/

  @spec text(String.t()) :: String.t()
  def text(text) when is_binary(text) do
    Regex.replace(@card, text, fn match ->
      digits = String.replace(match, ~r/\D/, "")
      if luhn?(digits), do: "[card number removed]", else: match
    end)
  end

  @doc "Redacts every text item of an MCP result's `content`."
  @spec result(map()) :: map()
  def result(%{"content" => content} = result) when is_list(content) do
    %{
      result
      | "content" =>
          Enum.map(content, fn
            %{"type" => "text", "text" => t} = item -> %{item | "text" => text(t)}
            item -> item
          end)
    }
  end

  def result(other), do: other

  @doc "Redacts every string inside a term (tool arguments, say)."
  @spec deep(term()) :: term()
  def deep(s) when is_binary(s), do: text(s)
  def deep(%{} = m), do: Map.new(m, fn {k, v} -> {k, deep(v)} end)
  def deep(l) when is_list(l), do: Enum.map(l, &deep/1)
  def deep(other), do: other

  @doc false
  def luhn?(digits) when byte_size(digits) in 13..19 do
    sum =
      digits
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.map(&String.to_integer/1)
      |> Enum.with_index()
      |> Enum.reduce(0, fn
        {d, i}, acc when rem(i, 2) == 1 -> acc + if(d * 2 > 9, do: d * 2 - 9, else: d * 2)
        {d, _}, acc -> acc + d
      end)

    rem(sum, 10) == 0
  end

  def luhn?(_digits), do: false
end
