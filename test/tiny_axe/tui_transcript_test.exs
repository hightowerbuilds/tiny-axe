defmodule TinyAxe.TUITranscriptTest do
  use ExUnit.Case, async: true

  alias TinyAxe.TUI
  alias TinyAxe.TUI.Transcript

  defp state(entries, extra \\ %{}),
    do: Map.merge(%{transcript: entries, streaming: nil, running_cmd: nil}, extra)

  test "identical entries each contribute their height and separating line" do
    entry = {:assistant, "```elixir\ndef hello do\n  :hello\nend\n```"}
    single = Transcript.height(state([entry]), 60)

    assert Transcript.height(state([entry, entry]), 60) == single * 2 + 1
    assert [first, first] = Transcript.entries_markdown(state([entry, entry]))
    assert first =~ "\u00A0\u00A0:hello"
  end

  test "resizing recalculates wrapping and returning to the old width restores height" do
    chat = state([{:assistant, String.duplicate("a sentence with several words. ", 30)}])
    wide = Transcript.height(chat, 90)
    narrow = Transcript.height(chat, 25)

    assert narrow > wide
    assert Transcript.height(chat, 90) == wide
    assert Transcript.height(chat, 25) == narrow
  end

  test "replacing attempts evicts obsolete entries and measures the replacement" do
    old = state([{:assistant, String.duplicate("old ", 100)}])
    new = state([{:assistant, "new answer"}])
    assert Transcript.height(old, 40) > Transcript.height(new, 40)
    assert Transcript.entries_markdown(new) == ["#### ▍tiny-axe\n\nnew answer"]

    # The cache's retention policy matters: long discarded attempts must not
    # remain reachable in the UI process until the conversation is cleared.
    assert Map.keys(Process.get({Transcript, :entries})) == new.transcript
  end

  test "streaming output stays fresh without adding every partial answer to the cache" do
    entry = {:user, "explain"}

    for n <- 1..20 do
      chat =
        state([entry], %{
          streaming: "answer #{n}",
          running_cmd: %{command: "echo hi", output: "output #{n}"}
        })

      rendered = Transcript.entries_markdown(chat) |> Enum.join("\n")
      assert rendered =~ "answer #{n} ▌"
      assert rendered =~ "output #{n}"
      assert Transcript.height(chat, 60) > 0
      assert Map.keys(Process.get({Transcript, :entries})) == [entry]
    end
  end

  test "clearing the conversation releases formatted entries and measurements" do
    {:ok, chat} = TUI.mount(test_mode: {100, 30})
    chat = %{chat | transcript: [{:assistant, "old conversation"}]}
    Transcript.height(chat, 98)

    assert {:noreply, cleared} =
             TUI.handle_event(
               %ExRatatui.Event.Key{code: "l", modifiers: ["ctrl"], kind: "press"},
               chat
             )

    assert cleared.transcript == []
    assert Process.get({Transcript, :entries}) == nil
    assert Transcript.height(cleared, 98) == 0
  end
end
