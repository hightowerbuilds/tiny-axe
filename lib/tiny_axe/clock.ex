defmodule TinyAxe.Clock do
  @moduledoc """
  Times as people read them: Pacific time on a 12-hour clock, e.g.
  `Oct 13, 2026 · 6:56 AM PDT`. Stored times stay UTC (ISO 8601); this is
  only for showing them.

  There's no time zone database in tiny-axe, so the US rules are here:
  daylight time (PDT, UTC−7) from 2:00 AM on the second Sunday of March to
  2:00 AM on the first Sunday of November; standard time (PST, UTC−8) the
  rest of the year.
  """

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc "An ISO 8601 time (or a DateTime) in Pacific time; anything unreadable is shown as it is."
  @spec pacific(String.t() | DateTime.t() | nil) :: String.t()
  def pacific(%DateTime{} = utc) do
    utc = DateTime.shift_zone!(utc, "Etc/UTC")
    {offset, zone} = if daylight?(utc), do: {-7, "PDT"}, else: {-8, "PST"}
    local = DateTime.add(utc, offset * 3600, :second)

    hour12 = rem(local.hour + 11, 12) + 1
    ampm = if local.hour < 12, do: "AM", else: "PM"
    minute = local.minute |> Integer.to_string() |> String.pad_leading(2, "0")

    "#{Enum.at(@months, local.month - 1)} #{local.day}, #{local.year} · " <>
      "#{hour12}:#{minute} #{ampm} #{zone}"
  end

  def pacific(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, utc, _offset} -> pacific(utc)
      _ -> text
    end
  end

  def pacific(nil), do: "unknown time"

  # Daylight time starts at 2:00 AM PST (10:00 UTC) on the second Sunday of
  # March and ends at 2:00 AM PDT (09:00 UTC) on the first Sunday of November.
  defp daylight?(%DateTime{year: year} = utc) do
    starts = DateTime.new!(nth_sunday(year, 3, 2), ~T[10:00:00], "Etc/UTC")
    ends = DateTime.new!(nth_sunday(year, 11, 1), ~T[09:00:00], "Etc/UTC")
    DateTime.compare(utc, starts) != :lt and DateTime.compare(utc, ends) == :lt
  end

  defp nth_sunday(year, month, n) do
    first = Date.new!(year, month, 1)
    # Date.day_of_week: Monday 1 … Sunday 7.
    to_sunday = rem(7 - Date.day_of_week(first), 7)
    Date.add(first, to_sunday + (n - 1) * 7)
  end
end
