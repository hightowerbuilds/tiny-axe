defmodule TinyAxe.Appearance.Value do
  @moduledoc """
  Checks a value a model gave for a setting (`TinyAxe.Appearance.Settings`)
  and puts it in the form the setting takes. Mistakes come back in plain
  words with the real choices, for the model to correct.

      iex> TinyAxe.Appearance.Value.parse({:int, 6, 40}, "+2", "12")
      {:ok, "14"}
      iex> TinyAxe.Appearance.Value.parse({:enum, ~w(on off)}, "enabled", nil)
      {:ok, "on"}
      iex> TinyAxe.Appearance.Value.parse({:float, 0.3, 1.0}, "80%", "1")
      {:ok, "0.8"}
  """

  alias TinyAxe.Appearance.Settings

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
  @more ~w(bigger larger more increase higher up)
  @less ~w(smaller less decrease lower down)

  defp number(raw, current, type) do
    text = raw |> to_string() |> String.trim() |> String.downcase()
    # "bigger" is one step: 2 for whole numbers, 0.1 for fractions.
    step = if type == :int, do: "2", else: "0.1"

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
