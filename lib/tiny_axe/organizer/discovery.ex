defmodule TinyAxe.Organizer.Discovery do
  @moduledoc """
  Builds the filesystem evidence used by the organizer and its reviewer.
  Listings have explicit size limits and hide dotfiles; search uses fd when
  available. Discovery reads the filesystem without proposing or applying changes.
  """

  alias TinyAxe.Ops

  @doc "A two-level map of visible home-directory entries."
  def home_map do
    root = Ops.root()

    root
    |> visible_entries()
    |> Enum.map_join("\n", fn name ->
      abs = Path.join(root, name)

      if File.dir?(abs) do
        inner = visible_entries(abs)
        shown = inner |> Enum.take(15) |> Enum.map(&entry_name(abs, &1))
        more = if length(inner) > 15, do: ", … (#{length(inner) - 15} more)", else: ""
        "#{Ops.show(abs)}/: #{Enum.join(shown, ", ")}#{more}"
      else
        Ops.show(abs)
      end
    end)
  end

  @doc "Listings of model-selected folders, resolved from the current location."
  def listings(paths) do
    paths
    |> Enum.map(&Ops.resolve/1)
    |> Enum.map_join("\n\n", &listing/1)
  end

  @doc "A bounded folder listing, excluding hidden entries."
  def listing(abs) do
    cond do
      not File.dir?(abs) ->
        "#{Ops.show(abs)} is not a folder."

      hidden?(abs) ->
        "#{Ops.show(abs)} is hidden and off limits."

      true ->
        entries = visible_entries(abs)
        shown = Enum.take(entries, 80)

        lines =
          Enum.map(shown, fn name ->
            path = Path.join(abs, name)

            case File.stat(path) do
              {:ok, %{type: :directory}} -> "  #{name}/"
              {:ok, %{size: size}} -> "  #{name}  (#{human_size(size)})"
              _ -> "  #{name}"
            end
          end)

        more = if length(entries) > 80, do: "\n  … (#{length(entries) - 80} more)", else: ""

        "Inside #{Ops.show(abs)}/ (#{length(entries)} entries):\n" <>
          Enum.join(lines, "\n") <> more
    end
  end

  defp visible_entries(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.reject(&String.starts_with?(&1, ".")) |> Enum.sort()
      _ -> []
    end
  end

  defp entry_name(dir, name), do: if(File.dir?(Path.join(dir, name)), do: name <> "/", else: name)

  defp hidden?(abs) do
    abs != Ops.root() and
      abs
      |> Path.relative_to(Ops.root())
      |> Path.split()
      |> Enum.any?(&String.starts_with?(&1, "."))
  end

  defp human_size(n) when n < 1024, do: "#{n} B"
  defp human_size(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp human_size(n), do: "#{Float.round(n / 1024 / 1024, 1)} MB"

  @stopwords ~w(move copy make folder folders file files into from with what that this the
                 have them there their some every each please about write notes note create
                 organise organize rename where want would could should)

  # Names on disk matching words in the request, found with fd (hidden files
  # and .gitignored paths skipped).
  def search(prompt) do
    words =
      ~r/[\p{L}\p{N}_-]{4,}/u
      |> Regex.scan(String.downcase(prompt))
      |> List.flatten()
      |> Enum.reject(&(&1 in @stopwords))
      |> Enum.uniq()

    with [_ | _] <- words, fd when fd != nil <- System.find_executable("fd") do
      pattern = Enum.map_join(words, "|", &Regex.escape/1)

      args =
        ~w(--ignore-case --max-depth 6 --max-results 30 --exclude node_modules --exclude _build --exclude deps)

      case System.cmd(fd, args ++ [pattern, Ops.root()], stderr_to_stdout: true) do
        {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&Ops.show/1)
        _ -> []
      end
    else
      _ -> []
    end
  end
end
