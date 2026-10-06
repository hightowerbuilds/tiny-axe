defmodule TinyAxe.OrganizerTest do
  use ExUnit.Case, async: false

  alias TinyAxe.{Decider, Model, Ops, Organizer}
  alias TinyAxe.Organizer.{Discovery, Documents}

  @moduletag :tmp_dir
  @keys ~w(model_backend decider script_model script_decider fs_root project_dir review_threshold)a

  setup %{tmp_dir: dir} do
    previous = Map.new(@keys, &{&1, Application.fetch_env(:tiny_axe, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:tiny_axe, key, value)
          :error -> Application.delete_env(:tiny_axe, key)
        end
      end

      TinyAxe.Location.reset()
    end)

    Application.put_env(:tiny_axe, :fs_root, dir)
    Application.put_env(:tiny_axe, :project_dir, dir)
    Application.put_env(:tiny_axe, :review_threshold, 0.5)
    TinyAxe.Location.reset()

    path = Path.join(dir, "notes.md")
    op = %{op: :write, path: path, about: "summarize the source", sources: []}
    %{dir: dir, path: path, op: op}
  end

  test "planning a document carries its sources and snapshot through approval", %{
    dir: dir,
    path: path
  } do
    source = Path.join(dir, "source.txt")
    File.write!(source, "The observation was made on Tuesday.")
    File.write!(path, "original notes")
    me = self()

    Model.Script.script(fn messages, opts ->
      if opts[:format] do
        JSON.encode!(%{
          look: [],
          mkdir: [],
          copy: [],
          move: [],
          trash: [],
          write: [%{path: path, about: "summarize the source", sources: [source]}],
          reply: "Proposed notes."
        })
      else
        prompt = List.last(messages).content
        assert prompt =~ "The observation was made on Tuesday."
        assert prompt =~ "original notes"
        # An independent editor saves while generation is in progress.
        File.write!(path, "a newer edit")
        "```markdown\n# Tuesday\n```"
      end
    end)

    Decider.Script.script(fn _, _, _ -> 0.9 end)

    assert :ok =
             Organizer.run([], "Summarize the source in notes.md", [], &send(me, {:event, &1}))

    assert_received {:event, {:plan, %{ops: [draft]}}}
    assert draft.content == "# Tuesday\n"
    assert draft.old_hash == Ops.hash("original notes")
    assert File.read!(path) == "a newer edit"

    assert {:error, reason} = Ops.step(draft, Path.join(dir, "backup"))
    assert reason =~ "changed since tiny-axe read it"
    assert File.read!(path) == "a newer edit"
  end

  test "a weaker second draft does not replace the first draft", %{op: op, path: path} do
    replies = start_supervised!({Agent, fn -> ["first", "second"] end})

    Model.Script.script(fn _, _ ->
      Agent.get_and_update(replies, fn [reply | rest] -> {reply, rest} end)
    end)

    Decider.Script.script(fn :fits, _, state ->
      if state.document == "first\n", do: 0.4, else: 0.1
    end)

    draft = Documents.prepare(op, "Write notes", "write notes.md", [], fn _ -> :ok end)
    assert draft.content == "first\n"
    assert draft.check == 0.4
    assert Agent.get(replies, & &1) == []
    refute File.exists?(path)
  end

  test "an unavailable document review keeps the draft and reports uncertainty", %{op: op} do
    me = self()

    Model.Script.script(fn _, _ ->
      send(me, :generated)
      "draft"
    end)

    Decider.Script.script(fn _, _, _ -> :unknown end)

    draft = Documents.prepare(op, "Write notes", "write notes.md", [], &send(me, {:event, &1}))

    assert draft.content == "draft\n"
    assert draft.check == nil
    assert_received :generated
    refute_received :generated
    assert_received {:event, {:decider_unavailable, "checking ~/notes.md"}}
  end

  test "discovery hides private folders and bounds a long listing", %{dir: dir} do
    folder = Path.join(dir, "many")
    File.mkdir_p!(folder)
    for i <- 1..85, do: File.write!(Path.join(folder, "file-#{i}"), "data")
    File.write!(Path.join(folder, ".secret"), "private")
    private = Path.join(dir, ".private")
    File.mkdir_p!(private)

    listing = Discovery.listing(folder)
    assert listing =~ "(85 entries)"
    assert listing =~ "5 more"
    refute listing =~ ".secret"
    assert Discovery.listing(private) =~ "hidden and off limits"
    assert Organizer.home_map() == Discovery.home_map()
  end
end
