defmodule TinyAxe.PipelineProjectContextTest do
  use ExUnit.Case, async: false

  alias TinyAxe.Pipeline.ProjectContext

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous =
      Map.new([:project_dir, :fs_root, :file_chars], &{&1, Application.fetch_env(:tiny_axe, &1)})

    Application.put_env(:tiny_axe, :project_dir, dir)
    Application.put_env(:tiny_axe, :fs_root, dir)
    Application.put_env(:tiny_axe, :file_chars, 1_000)
    TinyAxe.Location.reset()

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:tiny_axe, key, value)
          :error -> Application.delete_env(:tiny_axe, key)
        end
      end

      TinyAxe.Location.reset()
    end)

    %{path: Path.join(dir, "notes.txt")}
  end

  defp prepare do
    me = self()

    ProjectContext.prepare(
      %{change: %{noul: 0.9}},
      [],
      "Update @notes.txt",
      %{request: "update"},
      &send(me, {:event, &1})
    )
  end

  test "the writer and verifier share evidence, and offering a proposal doesn't write", %{
    path: path
  } do
    File.write!(path, "the original text")
    {[material], request, notify} = prepare()
    assert material.content =~ request.project_files
    assert request.project_files =~ "the original text"

    notify.({:stage, "generating"})
    answer = "```text notes.txt\nthe new text\n```"
    notify.({:done, answer})

    assert_received {:event, {:stage, "generating"}}
    assert_received {:event, {:edits, [%{old: "the original text", new: "the new text\n"}]}}
    assert_received {:event, {:done, ^answer}}
    assert File.read!(path) == "the original text"
  end

  test "a proposal based on an older snapshot is refused after an independent save", %{path: path} do
    File.write!(path, "before")
    {_materials, _request, notify} = prepare()
    File.write!(path, "saved by someone else")

    notify.({:done, "```text notes.txt\nmodel version\n```"})

    assert_received {:event, {:edit_refused, %{reason: reason}}}
    assert reason =~ "changed while the model was writing"
    refute_received {:event, {:edits, _}}
    assert File.read!(path) == "saved by someone else"
  end

  test "a truncated attachment cannot be offered as a whole-file rewrite", %{path: path} do
    content = String.duplicate("data ", 500)
    File.write!(path, content)
    {[material], _request, notify} = prepare()
    assert material.content =~ "cut off here"

    notify.({:done, "```text notes.txt\nshortened\n```"})

    assert_received {:event, {:edit_refused, %{reason: reason}}}
    assert reason =~ "too long to show the model in full"
    refute_received {:event, {:edits, _}}
    assert File.read!(path) == content
  end
end
