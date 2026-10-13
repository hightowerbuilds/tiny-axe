defmodule TinyAxe.ClockTest do
  use ExUnit.Case, async: true

  import TinyAxe.Clock, only: [pacific: 1]

  test "Pacific time on a 12-hour clock, daylight or standard as the date says" do
    assert pacific("2026-10-13T13:56:26Z") == "Oct 13, 2026 · 6:56 AM PDT"
    assert pacific("2026-01-05T03:07:00Z") == "Jan 4, 2026 · 7:07 PM PST"
    assert pacific("2026-07-04T19:00:00Z") == "Jul 4, 2026 · 12:00 PM PDT"
    assert pacific("2026-12-01T08:05:00Z") == "Dec 1, 2026 · 12:05 AM PST"
  end

  test "the switch to daylight time and back, to the minute" do
    # 2026: second Sunday of March is the 8th, first Sunday of November the 1st.
    assert pacific("2026-03-08T09:59:00Z") == "Mar 8, 2026 · 1:59 AM PST"
    assert pacific("2026-03-08T10:00:00Z") == "Mar 8, 2026 · 3:00 AM PDT"
    assert pacific("2026-11-01T08:59:00Z") == "Nov 1, 2026 · 1:59 AM PDT"
    assert pacific("2026-11-01T09:00:00Z") == "Nov 1, 2026 · 1:00 AM PST"
    # 2027: March 14 and November 7.
    assert pacific("2027-03-14T10:00:00Z") == "Mar 14, 2027 · 3:00 AM PDT"
    assert pacific("2027-11-07T09:00:00Z") == "Nov 7, 2027 · 1:00 AM PST"
  end

  test "other offsets are converted; what isn't a time is shown as it is" do
    assert pacific("2026-10-13T08:56:26-05:00") == "Oct 13, 2026 · 6:56 AM PDT"
    assert pacific("yesterday") == "yesterday"
    assert pacific(nil) == "unknown time"
  end
end
