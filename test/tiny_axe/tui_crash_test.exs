defmodule TinyAxe.TUICrashTest do
  @moduledoc "A crash in the TUI restarts it with the conversation restored."

  # Uses the app's shared session store, so not async.
  use ExUnit.Case, async: false

  # Crashes here are deliberate; keep their logs out of the test output.
  @moduletag :capture_log

  alias TinyAxe.TUI

  test "the supervisor restarts a crashed TUI, which restores the conversation" do
    Agent.update(TinyAxe.Session, fn _ -> %{history: [], transcript: [], crashed: nil} end)

    start_supervised!({TUI, test_mode: {100, 30}, session: true, name: :crash_test_tui})
    tui = Process.whereis(:crash_test_tui)

    # Something worth keeping: a line in the transcript.
    send(tui, {:ops, "plan", {:note, "moved 3 files"}})
    assert eventually(fn -> TinyAxe.Session.restore().transcript != [] end)

    # A malformed message makes the TUI raise, as a bug would.
    ref = Process.monitor(tui)
    send(tui, {:ops, "plan", {:rolled_back, :not_a_list}})
    assert_receive {:DOWN, ^ref, :process, ^tui, _reason}, 5_000

    restarted =
      eventually(fn -> (pid = Process.whereis(:crash_test_tui)) && pid != tui && pid end)

    assert Process.alive?(restarted)

    %{transcript: transcript} = :sys.get_state(restarted).user_state
    assert {:meta, "· moved 3 files"} in transcript
    assert Enum.any?(transcript, fn {_, text} -> text =~ "the screen crashed" end)
  end

  defp eventually(fun, tries \\ 100) do
    case fun.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(20)
        eventually(fun, tries - 1)

      result ->
        result
    end
  end
end
