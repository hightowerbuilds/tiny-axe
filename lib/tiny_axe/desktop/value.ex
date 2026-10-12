defmodule TinyAxe.Desktop.Value do
  @moduledoc """
  Checks a value a model gave for a setting (`TinyAxe.Desktop.Settings`)
  and puts it in the form the setting takes. Mistakes come back in plain
  words with the real choices, for the model to correct.

      iex> TinyAxe.Desktop.Value.parse({:int, 6, 40}, "+2", "12")
      {:ok, "14"}
      iex> TinyAxe.Desktop.Value.parse({:enum, ~w(on off)}, "enabled", nil)
      {:ok, "on"}
      iex> TinyAxe.Desktop.Value.parse({:float, 0.3, 1.0}, "80%", "1")
      {:ok, "0.8"}
      iex> TinyAxe.Desktop.Value.parse(:reminder, "in 10 minutes: check the oven", nil)
      {:ok, "10 check the oven"}
      iex> TinyAxe.Desktop.Value.parse(:url, "github.com/hightowerbuilds", nil)
      {:ok, "https://github.com/hightowerbuilds"}
  """

  alias TinyAxe.Desktop.Settings

  @images ~w(.png .jpg .jpeg .webp .gif .bmp)
  @yes ~w(on yes true enable enabled show shown visible 1)
  @no ~w(off no false disable disabled hide hidden 0)

  @doc "`{:ok, value}` or `{:error, why}`; `current` makes `+2`/`-2` mean something."
  @spec parse(term(), String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def parse(kind, raw, current)

  def parse(:action, _raw, _current), do: {:ok, "now"}

  def parse({:choice, fun}, raw, _current) do
    choices = fun.()

    cond do
      choices == [] -> {:error, "the list of choices couldn't be read from the computer"}
      hit = match(raw, choices) -> {:ok, hit}
      true -> {:error, "#{inspect(raw)} isn't one of: #{Enum.join(choices, ", ")}"}
    end
  end

  # A long list read from the computer (installed apps): not shown to the
  # model in full, so a miss suggests the closest names.
  def parse({:lookup, fun}, raw, _current) do
    names = fun.()

    case match(raw, names) || contains(raw, names) do
      nil ->
        {:error,
         "#{inspect(raw)} isn't one of the installed names; the closest are: " <>
           (names |> closest(raw) |> Enum.join(", "))}

      hit ->
        {:ok, hit}
    end
  end

  def parse(:url, raw, _current) do
    url = raw |> to_string() |> String.trim()
    url = if url =~ ~r{^[a-z][a-z0-9+.-]*://}i, do: url, else: "https://" <> url

    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        if host =~ ~r/^[A-Za-z0-9.-]+$/ and String.contains?(host, "."),
          do: {:ok, url},
          else: {:error, "#{inspect(raw)} isn't a web address"}

      _ ->
        {:error, "#{inspect(raw)} isn't a web address (only http and https open)"}
    end
  end

  # "10 check the oven", "10 minutes check the oven", "in 10 min: tea".
  def parse(:reminder, raw, _current) do
    text = raw |> to_string() |> String.trim()

    case Regex.run(~r/^(?:in\s+)?(\d{1,4})\s*(?:m|min|mins|minutes?)?\b[\s:,-]*(.*)$/is, text) do
      [_, minutes, message] when minutes != "0" ->
        message = message |> String.trim() |> String.replace(~r/\s+/, " ")
        {:ok, String.trim("#{String.to_integer(minutes)} #{message}")}

      _ ->
        {:error, "a reminder is minutes from now, then the message, e.g. \"10 check the oven\""}
    end
  end

  def parse({:enum, names}, raw, current) do
    word = norm(raw)

    word =
      cond do
        names == ~w(on off) and word in @yes ->
          "on"

        names == ~w(on off) and word in @no ->
          "off"

        names == ~w(on off) and word in ~w(toggle switch flip) and current in names ->
          other(current)

        true ->
          word
      end

    case match(word, names) do
      nil -> {:error, "#{inspect(raw)} isn't one of: #{Enum.join(names, ", ")}"}
      hit -> {:ok, hit}
    end
  end

  def parse({:or, words, kind}, raw, current) do
    case match(norm(raw), words) do
      nil -> parse(kind, raw, current)
      word -> {:ok, word}
    end
  end

  def parse(:image, raw, _current) do
    path = raw |> String.trim() |> String.trim("\"") |> Path.expand()

    cond do
      not File.regular?(path) -> {:error, "#{raw} isn't a file"}
      String.downcase(Path.extname(path)) not in @images -> {:error, "#{raw} isn't an image"}
      true -> {:ok, path}
    end
  end

  def parse({:int, lo, hi}, raw, current) do
    with {:ok, n} <- number(raw, current, :int) do
      n = round(n)

      if n in lo..hi,
        do: {:ok, Integer.to_string(n)},
        else: {:error, "#{n} is outside #{lo}–#{hi}"}
    end
  end

  def parse({:float, lo, hi}, raw, current) do
    with {:ok, n} <- number(raw, current, :float) do
      n = n / 1

      if n >= lo and n <= hi,
        do: {:ok, Settings.format_float(n)},
        else: {:error, "#{Settings.format_float(n)} is outside #{lo}–#{hi}"}
    end
  end

  # "14", "14pt", "+2", "-2" (from the current value), "bigger"/"smaller"
  # (a step); "80%" means 0.8 for a fraction (opacity), 80 otherwise.
  @more ~w(bigger larger more increase higher up louder)
  @less ~w(smaller less decrease lower down quieter softer)

  defp number(raw, current, type) do
    text = raw |> to_string() |> String.trim() |> String.downcase()
    # "bigger" is one step: 2 for whole numbers, 0.1 for fractions;
    # "louder" and "quieter" are 10 (percent).
    step =
      cond do
        text in ~w(louder quieter softer) -> "10"
        type == :int -> "2"
        true -> "0.1"
      end

    text =
      cond do
        text in @more -> "+" <> step
        text in @less -> "-" <> step
        true -> text
      end

    relative = Regex.match?(~r/^[+-]\s*\d/, text)
    percent = String.ends_with?(text, "%")

    case Float.parse(Regex.replace(~r/[^\d.-]/, text, "")) do
      {n, _} ->
        n = if percent and type == :float, do: n / 100, else: n

        cond do
          not relative -> {:ok, n}
          base = current && parse_float(current) -> {:ok, base + n}
          true -> {:error, "#{raw} is relative, but the current value isn't known; give a number"}
        end

      :error ->
        {:error, "#{inspect(raw)} isn't a number"}
    end
  end

  defp parse_float(text) do
    case Float.parse(to_string(text)) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp other("on"), do: "off"
  defp other("off"), do: "on"

  defp contains(raw, names) do
    key = squash(raw)

    case Enum.filter(names, &(key != "" and String.contains?(squash(&1), key))) do
      [one] -> one
      _ -> nil
    end
  end

  defp closest(names, raw) do
    names
    |> Enum.sort_by(
      &(-String.jaro_distance(String.downcase(&1), String.downcase(to_string(raw))))
    )
    |> Enum.take(8)
  end

  # Case, spaces, dashes and underscores don't matter: "tokyo-night" is
  # "Tokyo Night".
  defp match(raw, names) do
    key = squash(raw)
    Enum.find(names, &(squash(&1) == key))
  end

  defp squash(text),
    do: text |> to_string() |> String.downcase() |> String.replace(~r/[\s_-]+/, "")

  defp norm(text), do: text |> to_string() |> String.trim() |> String.downcase()
end
