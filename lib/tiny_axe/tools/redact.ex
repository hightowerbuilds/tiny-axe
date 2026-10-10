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

  @email ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/
  @phone ~r/(?<![\w.])\+?\(?\d[\d\s().-]{5,}\d(?![\w])/
  @date ~r/\A\d{4}-\d{2}-\d{2}\z/
  @street ~r/\b\d{1,5}[A-Za-z]?\s+(?:[A-Z][A-Za-z'-]+\s+){1,4}(?:St|Street|Rd|Road|Ave|Avenue|Ln|Lane|Way|Dr|Drive|Blvd|Boulevard|Ct|Court|Pl|Place|Terrace|Close|Crescent|Square|Row)\b\.?/
  @token ~r/(?<![A-Za-z0-9_-])(?=[A-Za-z0-9_-]*\d)(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{24,}(?![A-Za-z0-9_-])/

  @doc """
  Also removes personal details, for content kept long-term (reviewed
  browser examples, `TinyAxe.Browser.Examples`): card numbers, email
  addresses, phone numbers (seven digits or more; not dates), street
  addresses (a number, capitalised words and a street type), and
  token-like strings (24+ letters and digits mixed).
  """
  @spec personal(String.t()) :: String.t()
  def personal(text) when is_binary(text) do
    text
    |> text()
    |> then(&Regex.replace(@email, &1, "[email removed]"))
    |> then(&Regex.replace(@token, &1, "[token removed]"))
    |> then(&Regex.replace(@street, &1, "[address removed]"))
    |> then(
      &Regex.replace(@phone, &1, fn match ->
        digits = String.replace(match, ~r/\D/, "")

        if String.length(digits) >= 7 and not (String.trim(match) =~ @date),
          do: "[phone removed]",
          else: match
      end)
    )
  end

  @doc "`personal/1` over every string in a term."
  def personal_deep(s) when is_binary(s), do: personal(s)
  def personal_deep(%{} = m), do: Map.new(m, fn {k, v} -> {k, personal_deep(v)} end)
  def personal_deep(l) when is_list(l), do: Enum.map(l, &personal_deep/1)
  def personal_deep(other), do: other

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
