defmodule TinyAxe.Appearance.ConfigFiles do
  @moduledoc """
  The two config files appearance settings write, and only the lines they own:

    * Ghostty's `~/.config/ghostty/config`: one `key = value` line per
      setting (replaced where it is, added at the end otherwise), then every
      Ghostty window reloads (`omarchy restart terminal`, which signals them)
    * Hyprland's `~/.config/hypr/looknfeel.lua`: a block between
      `-- tiny-axe: begin` and `-- tiny-axe: end` holding one `hl.config({…})`
      with the values tiny-axe set (also kept as JSON on the block's second
      line, so they're read back without parsing Lua). Nothing outside the
      block changes. After writing, Hyprland reloads and `hyprctl
      configerrors` is read: any new error puts the file back as it was and
      reloads again, so the desktop is never left on a broken config.

  Every write returns the file's content from before, which the undo record
  keeps (`TinyAxe.Appearance.Undo`).
  """

  alias TinyAxe.Appearance.Runner

  @begin "-- tiny-axe: begin (settings tiny-axe made; `/look undo` puts back the last change, or delete this block)"
  @values "-- tiny-axe-values: "
  @finish "-- tiny-axe: end"

  def ghostty_path, do: path(:ghostty_config, "~/.config/ghostty/config")
  def hypr_path, do: path(:hypr_look, "~/.config/hypr/looknfeel.lua")

  defp path(key, default) do
    Application.get_env(:tiny_axe, :appearance, [])
    |> Keyword.get(key, default)
    |> Path.expand()
  end

  ## Ghostty

  @doc "A key's value in the Ghostty config (the last one wins, as in Ghostty), or nil."
  @spec ghostty_get(String.t()) :: String.t() | nil
  def ghostty_get(key) do
    case File.read(ghostty_path()) do
      {:ok, text} ->
        ~r/^[ \t]*#{Regex.escape(key)}[ \t]*=[ \t]*(.*?)[ \t]*$/m
        |> Regex.scan(text)
        |> List.last()
        |> case do
          [_, value] -> value |> String.trim("\"")
          nil -> nil
        end

      {:error, _} ->
        nil
    end
  end

  @doc """
  Sets `key = value` lines in the Ghostty config and reloads Ghostty.
  `{:ok, before}` with the file's earlier content, or `{:error, why}`.
  """
  @spec ghostty_set([{String.t(), String.t()}]) :: {:ok, String.t()} | {:error, String.t()}
  def ghostty_set(pairs) do
    file = ghostty_path()

    with {:ok, before} <- read_existing(file, "Ghostty's config") do
      after_text = Enum.reduce(pairs, before, fn {k, v}, text -> put_line(text, k, v) end)

      with :ok <- write(file, after_text) do
        reload_terminals()
        {:ok, before}
      end
    end
  end

  # Every uncommented `key = …` line is replaced; with none, one is added.
  defp put_line(text, key, value) do
    re = ~r/^[ \t]*#{Regex.escape(key)}[ \t]*=.*$/m
    line = "#{key} = #{value}"

    if Regex.match?(re, text),
      do: Regex.replace(re, text, line),
      else: String.trim_trailing(text) <> "\n" <> line <> "\n"
  end

  @doc "Every Ghostty window re-reads its config."
  def reload_terminals, do: Runner.cmd("omarchy", ["restart", "terminal"])

  ## Hyprland

  @doc "The values in tiny-axe's block (`%{\"decoration.rounding\" => 8}`)."
  @spec hypr_values() :: map()
  def hypr_values do
    with {:ok, text} <- File.read(hypr_path()),
         [_, json] <- Regex.run(~r/^#{Regex.escape(@values)}(.*)$/m, text),
         {:ok, map} when is_map(map) <- JSON.decode(json) do
      map
    else
      _ -> %{}
    end
  end

  @doc """
  Sets values in tiny-axe's block (dotted Hyprland option names, `nil`
  removes one), reloads Hyprland and checks it took the config.
  `{:ok, before}` or `{:error, why}` (the file is then as it was).
  """
  @spec hypr_set(map()) :: {:ok, String.t()} | {:error, String.t()}
  def hypr_set(changes) do
    file = hypr_path()

    with {:ok, before} <- read_existing(file, "Hyprland's looknfeel.lua") do
      values =
        Enum.reduce(changes, hypr_values(), fn
          {k, nil}, acc -> Map.delete(acc, k)
          {k, v}, acc -> Map.put(acc, k, v)
        end)

      errors_before = config_errors()

      with :ok <- write(file, put_block(before, values)) do
        reload_hyprland()

        case config_errors() do
          errors when errors == "" or errors == errors_before ->
            {:ok, before}

          errors ->
            write(file, before)
            reload_hyprland()
            {:error, "Hyprland refused the change, so it was put back: #{errors}"}
        end
      end
    end
  end

  @doc "Puts a file back as it was (for undo); reloads what reads it."
  @spec restore(String.t(), String.t()) :: :ok | {:error, String.t()}
  def restore(file, content) do
    with :ok <- write(file, content) do
      cond do
        file == hypr_path() -> reload_hyprland()
        file == ghostty_path() -> reload_terminals()
        true -> :ok
      end

      :ok
    end
  end

  def reload_hyprland, do: Runner.cmd("hyprctl", ["reload"])

  defp config_errors do
    case Runner.cmd("hyprctl", ["configerrors"]) do
      {out, 0} -> String.trim(out)
      _ -> ""
    end
  end

  @doc false
  def put_block(text, values) do
    stripped =
      Regex.replace(~r/\n*^-- tiny-axe: begin.*?^#{Regex.escape(@finish)}[^\n]*\n?/ms, text, "")

    if values == %{} do
      String.trim_trailing(stripped) <> "\n"
    else
      String.trim_trailing(stripped) <> "\n\n" <> block(values)
    end
  end

  defp block(values) do
    """
    #{@begin}
    #{@values}#{JSON.encode!(values)}
    hl.config(#{lua(nest(values), 0)})
    #{@finish}
    """
  end

  defp nest(values) do
    Enum.reduce(values, %{}, fn {dotted, v}, acc ->
      put_in(acc, Enum.map(String.split(dotted, "."), &Access.key(&1, %{})), v)
    end)
  end

  defp lua(map, depth) when is_map(map) do
    pad = String.duplicate("  ", depth + 1)

    inner =
      map
      |> Enum.sort()
      |> Enum.map_join("", fn {k, v} -> "#{pad}#{k} = #{lua(v, depth + 1)},\n" end)

    "{\n#{inner}#{String.duplicate("  ", depth)}}"
  end

  defp lua(v, _) when is_boolean(v), do: to_string(v)
  defp lua(v, _) when is_integer(v), do: Integer.to_string(v)
  defp lua(v, _) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)
  defp lua(v, _) when is_binary(v), do: inspect(v)

  ## Files

  defp read_existing(file, name) do
    case File.read(file) do
      {:ok, text} -> {:ok, text}
      {:error, :enoent} -> {:error, "#{name} (#{file}) doesn't exist"}
      {:error, reason} -> {:error, "couldn't read #{name}: #{:file.format_error(reason)}"}
    end
  end

  # Written beside the file, then renamed over it, so it's never half written.
  # A symlinked config is written where the link points.
  defp write(file, content) do
    real = TinyAxe.Shell.real_path(file)
    tmp = real <> ".tiny-axe-tmp"

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, real) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, "couldn't write #{file}: #{:file.format_error(reason)}"}
    end
  end
end
