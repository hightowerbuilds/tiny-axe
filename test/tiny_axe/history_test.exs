defmodule TinyAxe.HistoryTest do
  @moduledoc """
  The chat history (`TinyAxe.History`): every chat kept on disk, redacted,
  as `docs/plan-history.md` describes; and `/history` in the TUI
  (`TinyAxe.TUI.ChatHistory`), which lists and reopens them.
  """

  # One history folder for the test run, emptied before each test.
  use ExUnit.Case, async: false

  alias ExRatatui.Event
  alias TinyAxe.{History, TUI}
  alias TinyAxe.TUI.Chats

  setup do
    File.rm_rf!(History.dir())
    on_exit(fn -> File.rm_rf!(History.dir()) end)
    :ok
  end

  ## Helpers

  defp chat(id, transcript, extra \\ %{}) do
    Map.merge(%{saved_as: id, history: [], transcript: transcript, summary: nil}, Map.new(extra))
  end

  defp kept(chats) do
    History.save(chats)
    History.sync()
  end

  defp file(id), do: Path.join(History.dir(), id <> ".json")
  defp doc(id), do: id |> file() |> File.read!() |> JSON.decode!()

  defp key(state, code, mods \\ []) do
    {:noreply, state} =
      TUI.handle_event(%Event.Key{code: code, kind: "press", modifiers: mods}, state)

    state
  end

  defp type(state, text) do
    ExRatatui.textarea_set_value(state.input, text)
    key(state, "enter")
  end

  defp metas(state), do: for({:meta, text} <- state.transcript, do: text)

  defp tui do
    {:ok, state} = TUI.mount(test_mode: {110, 32})
    state
  end

  describe "keeping chats" do
    test "a chat is kept once the user has asked something, as the plan describes" do
      id = History.new_id()
      assert History.id?(id)

      kept([chat(id, [{:meta, "startup note"}])])
      refute File.exists?(file(id))

      kept([
        chat(id, [
          {:user, "how much free space do I have?\nand more"},
          {:meta, "🔧 shell_run (only reads)"},
          {:assistant, "You have **105G** free."}
        ])
      ])

      d = doc(id)
      assert d["version"] == 2
      assert d["id"] == id
      assert d["session"] == History.session()
      assert d["title"] == "how much free space do I have?"
      assert is_binary(d["folder"])
      assert {:ok, _, _} = DateTime.from_iso8601(d["started"])

      assert Enum.map(d["entries"], & &1["kind"]) == ["user", "meta", "assistant"]
      assert File.stat!(file(id)).mode |> Bitwise.band(0o777) == 0o600
    end

    test "card numbers, keys and tokens are removed from everything kept" do
      id = History.new_id()
      card = "4111 1111 1111 1111"
      key = "sk-ant-api03-abcdefghijklmnop1234567890"

      kept([
        chat(id, [{:user, "my card is #{card} and key #{key}"}, {:assistant, "noted #{key}"}],
          history: [%{role: "user", content: "card #{card}"}],
          summary: %{text: "they gave #{key}", turns: 1, check: 0.9}
        )
      ])

      body = File.read!(file(id))
      refute body =~ "4111"
      refute body =~ key
      assert body =~ "[card number removed]"
      assert body =~ "[token removed]"
    end

    test "an unchanged chat isn't written again; a changed one is" do
      id = History.new_id()
      c = chat(id, [{:user, "hello"}])
      kept([c])
      first = doc(id)["updated"]
      File.write!(file(id), File.read!(file(id)) |> String.replace(first, "2000-01-01T00:00:00Z"))

      kept([c])
      assert doc(id)["updated"] == "2000-01-01T00:00:00Z"

      kept([chat(id, [{:user, "hello"}, {:assistant, "hi"}])])
      refute doc(id)["updated"] == "2000-01-01T00:00:00Z"
    end

    test "a chat reopened in a later launch keeps its session, start and folder" do
      id = History.new_id()

      File.mkdir_p!(History.dir())

      File.write!(
        file(id),
        JSON.encode!(%{
          version: 1,
          id: id,
          session: "20200101-000000-0000",
          started: "2020-01-01T00:00:00Z",
          updated: "2020-01-01T00:00:00Z",
          title: "old",
          folder: "~/old",
          entries: [%{kind: "user", text: "old"}],
          context: %{history: [], summary: nil}
        })
      )

      kept([chat(id, [{:user, "old"}, {:assistant, "and new"}])])

      d = doc(id)

      assert {d["session"], d["started"], d["folder"]} ==
               {"20200101-000000-0000", "2020-01-01T00:00:00Z", "~/old"}

      assert length(d["entries"]) == 2
    end
  end

  test "tool output and local-only policy survive save and reopen" do
    id = History.new_id()

    kept([
      chat(id, [{:user, "show result"}, {:output, "echo result", "saved output", 0}],
        local_only: true
      )
    ])

    assert {:ok, loaded} = History.load(id)
    assert loaded.local_only
    assert {:output, "echo result", "saved output", 0} in loaded.transcript
    assert doc(id)["entries"] |> List.last() |> Map.fetch!("text") =~ "saved output"
    kept([chat(id, [{:user, "show result"}, {:assistant, "new turn"}], local_only: false)])
    assert doc(id)["local_only"] == true
  end

  describe "reading them back" do
    test "list: newest first, with what the TUI shows; searched; limited" do
      [a, b, c] = for _ <- 1..3, do: History.new_id()
      kept([chat(a, [{:user, "about volcanoes"}, {:assistant, "Etna erupts"}])])
      kept([chat(b, [{:user, "about rivers"}])])
      kept([chat(c, [{:user, "about lakes"}, {:meta, "ran df"}, {:assistant, "deep"}])])

      # Updated at the same second: order them by hand.
      for {id, t} <- [{a, "01"}, {b, "02"}, {c, "03"}] do
        File.write!(
          file(id),
          File.read!(file(id)) |> String.replace(doc(id)["updated"], "2026-01-01T00:00:#{t}Z")
        )
      end

      assert [%{id: ^c, title: "about lakes", messages: 2}, %{id: ^b}, %{id: ^a}] = History.list()
      assert [%{id: ^a}] = History.list(query: "ETNA")
      # Every word, anywhere in the chat, as on the website.
      assert [%{id: ^a}] = History.list(query: "erupts volcanoes")
      assert [] = History.list(query: "erupts rivers")
      assert [%{id: ^c}, %{id: ^b}] = History.list(limit: 2)
    end

    test "files that aren't chats are skipped; ids can't name other files" do
      id = History.new_id()
      kept([chat(id, [{:user, "real"}])])
      File.write!(Path.join(History.dir(), "notes.json"), "{}")
      File.write!(Path.join(History.dir(), "20260101-000000-abcd.json"), "not json")

      assert [%{id: ^id}] = History.list()
      assert {:error, :bad_id} = History.load("../../etc/passwd")
      assert {:error, _} = History.load("20260101-000000-abcd")
    end

    test "load gives the chat back as the TUI holds one" do
      id = History.new_id()

      kept([
        chat(id, [{:user, "q"}, {:meta, "m"}, {:assistant, "a"}],
          history: [%{role: "user", content: "q"}, %{role: "assistant", content: "a"}],
          summary: %{text: "earlier turns", turns: 3, check: 0.8}
        )
      ])

      assert {:ok, loaded} = History.load(id)
      assert loaded.saved_as == id
      assert loaded.transcript == [{:user, "q"}, {:meta, "m"}, {:assistant, "a"}]
      assert loaded.history == [%{role: "user", content: "q"}, %{role: "assistant", content: "a"}]
      assert loaded.summary == %{text: "earlier turns", turns: 3, check: 0.8}
    end
  end

  describe "the TUI" do
    test "every chat has its own id; ctrl+l starts a new one" do
      state = tui()
      assert History.id?(state.saved_as)

      state = type(state, "/new")
      [first, second] = state.chats.order
      refute Chats.kept_as(state, state.saved_as) == first
      assert Chats.kept_as(state, state.saved_as) == second

      before = state.saved_as
      state = key(state, "l", ["ctrl"])
      refute state.saved_as == before
    end

    test "chats that changed are kept when the TUI saves" do
      state = tui()
      now = %{state | transcript: [{:user, "keep me"}]}
      Chats.persist(now, state)
      History.sync()

      assert doc(now.saved_as)["title"] == "keep me"
    end

    test "/history lists the kept chats, numbered, and says which are open" do
      state = tui()
      assert metas(type(state, "/history")) |> List.last() =~ "no chats kept yet"

      other = History.new_id()
      kept([chat(other, [{:user, "an older chat"}, {:assistant, "yes"}])])
      kept([chat(state.saved_as, [{:user, "this one"}])])

      state = type(state, "/history")
      lines = metas(state)

      assert Enum.any?(lines, &(&1 =~ "recent chats, newest first · /history N reopens one"))
      assert Enum.any?(lines, &(&1 =~ ~r/^\d · .* · an older chat · 2 messages/))
      assert Enum.any?(lines, &(&1 =~ ~r/this one · 1 message.* ◂ open as chat 1/))
      assert length(state.history_shown) == 2

      assert type(state, "/history zeppelin") |> metas() |> List.last() =~
               "no kept chat has “zeppelin”"

      assert type(state, "/history 9") |> metas() |> List.last() =~ "no chat 9 in the last list"
    end

    test "/history N reopens a chat: in an empty chat, or as a new one" do
      id = History.new_id()

      kept([
        chat(id, [{:user, "about volcanoes"}, {:assistant, "Etna erupts"}],
          history: [
            %{role: "user", content: "about volcanoes"},
            %{role: "assistant", content: "Etna erupts"}
          ]
        )
      ])

      # Nothing asked here yet: it opens here.
      state = tui() |> type("/history volcanoes") |> type("/history 1")
      assert state.saved_as == id
      assert Chats.count(state) == 1
      assert {:assistant, "Etna erupts"} in state.transcript
      assert length(state.history) == 2
      assert metas(state) |> List.last() =~ "reopened “about volcanoes”"

      # Something asked: it opens as a new chat, and the first stays as it was.
      busy = %{tui() | transcript: [{:user, "something else"}]}
      state = busy |> type("/history") |> type("/history 1")
      assert Chats.count(state) == 2
      assert state.saved_as == id

      # Already open: /history N shows it.
      state = type(state, "/chat 1") |> type("/history") |> type("/history 1")
      assert Chats.count(state) == 2
      assert state.saved_as == id
    end
  end
end
