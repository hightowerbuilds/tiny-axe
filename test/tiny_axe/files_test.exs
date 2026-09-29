defmodule TinyAxe.FilesTest do
  # Sets the global :project_dir, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.Files

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    TinyAxe.Location.reset()
    previous = Application.get_env(:tiny_axe, :project_dir)
    Application.put_env(:tiny_axe, :project_dir, dir)
    on_exit(fn -> Application.put_env(:tiny_axe, :project_dir, previous) end)

    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "mix.exs"), "defmodule Demo.MixProject do\nend\n")
    File.write!(Path.join(dir, "lib/demo.ex"), "defmodule Demo do\n  def hi, do: :hi\nend\n")
    :ok
  end

  test "lists project files as relative paths", %{tmp_dir: dir} do
    assert Files.list(dir) == ["lib/demo.ex", "mix.exs"]
  end

  test "finds @mentions of existing paths, but not emails or missing files", %{tmp_dir: dir} do
    prompt = "look at @lib/demo.ex and @mix.exs. mail me@example.com about @nope.ex"
    assert Files.mentions(prompt) == [Path.join(dir, "lib/demo.ex"), Path.join(dir, "mix.exs")]
  end

  test "keeps edits inside the project and drops unchanged files" do
    text = """
    ```elixir lib/demo.ex
    defmodule Demo do
      def hi, do: :hello
    end
    ```
    ```elixir mix.exs
    defmodule Demo.MixProject do
    end
    ```
    ```elixir ../outside.ex
    defmodule Outside do
    end
    ```
    ```elixir lib/new.ex
    defmodule New do
    end
    ```
    """

    assert [
             %{path: "lib/demo.ex", old: "defmodule Demo do\n  def hi, do: :hi\nend\n"},
             %{path: "lib/new.ex", old: nil, new: "defmodule New do\nend\n"}
           ] = Files.proposed_edits(text)
  end

  test "never proposes edits in hidden folders, .git included", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".git"))
    File.mkdir_p!(Path.join(dir, ".config"))

    text = """
    ```ini .git/config
    [core]
    ```
    ```ini .config/app.ini
    secret=2
    ```
    ```elixir lib/demo.ex
    defmodule Demo do
    end
    ```
    """

    assert [%{path: "lib/demo.ex"}] = Files.proposed_edits(text)
  end

  test "refuses to read binaries", %{tmp_dir: dir} do
    path = Path.join(dir, "image.bin")
    File.write!(path, <<137, 80, 78, 71, 0, 1, 2>>)
    assert Files.read(path, 100) == {:error, :binary}
  end

  test "diffs keep a little context around changes" do
    old = Enum.map_join(1..10, "\n", &"line #{&1}")
    new = String.replace(old, "line 5", "line five")

    assert {lines, 1, 1} = Files.diff(old, new, 1)

    assert lines == [
             :gap,
             {:eq, "line 4"},
             {:del, "line 5"},
             {:ins, "line five"},
             {:eq, "line 6"},
             :gap
           ]
  end

  test "shortlists files whose paths share words with the request" do
    files = ["a/zeta.ex", "lib/tui.ex", "lib/pipeline.ex", "test/tui_test.exs"]
    assert Files.shortlist(files, "fix the tui colours", 2) == ["lib/tui.ex", "test/tui_test.exs"]
  end
end
