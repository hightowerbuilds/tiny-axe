defmodule TinyAxe.CodeCheckTest do
  use ExUnit.Case, async: true

  alias TinyAxe.CodeCheck

  describe "extract/1" do
    test "keeps source blocks of the first supported language only" do
      text = """
      ```python
      def a(): pass
      ```
      ```elixir
      defmodule A, do: nil
      ```
      ```py
      def b(): pass
      ```
      """

      assert [{:python, "def a(): pass\n"}, {:python, "def b(): pass\n"}] =
               CodeCheck.extract(text)
    end

    test "skips shell sessions and IEx transcripts" do
      text = "```elixir\niex> 1 + 1\n2\n```\n```bash\nmix test\n```"
      assert CodeCheck.extract(text) == []
    end

    test "ignores prose-only answers" do
      assert {:skipped, "no Elixir or Python code"} = CodeCheck.run("Just words.")
    end
  end

  describe "run/1 in the sandbox" do
    @describetag :sandbox
    @describetag timeout: 60_000

    setup do
      if TinyAxe.Sandbox.available?(), do: :ok, else: {:skip, "bwrap not installed"}
    end

    test "passes compiling Elixir with correct doctests" do
      code = ~S'''
      ```elixir
      defmodule Doubler do
        @doc """
            iex> Doubler.double(21)
            42
        """
        def double(x), do: x * 2
      end
      ```
      '''

      assert {:ran, %{status: :passed, summary: "compiled cleanly, 1/1 doctests passed"}} =
               CodeCheck.run(code)
    end

    test "fails Elixir with a wrong doctest and reports it" do
      code = ~S'''
      ```elixir
      defmodule Doubler do
        @doc """
            iex> Doubler.double(21)
            43
        """
        def double(x), do: x * 2
      end
      ```
      '''

      assert {:ran, %{status: :failed, summary: "1/1 doctests failed", output: out}} =
               CodeCheck.run(code)

      assert out =~ "43"
    end

    test "fails public Elixir functions without doctests and says how to add them" do
      code = "```elixir\ndefmodule F do\n  @doc \"One.\"\n  def f, do: 1\nend\n```"

      assert {:ran, %{status: :failed, summary: "no doctests", output: out}} =
               CodeCheck.run(code)

      assert out =~ "iex>"
    end

    test "passes Elixir without doctests when there is no public function to test" do
      code =
        "```elixir\ndefmodule P do\n  @moduledoc false\n  defstruct [:name]\nend\n```"

      assert {:ran, %{status: :passed, summary: "compiled cleanly (no doctests)"}} =
               CodeCheck.run(code)
    end

    test "skips code that needs a package the sandbox doesn't have" do
      code = "```elixir\ndefmodule Demo do\n  use ExRatatui.App\nend\n```"

      assert {:skipped, "uses ExRatatui, which the checker doesn't have"} =
               CodeCheck.run(code)
    end

    test "skips structs and calls from a missing package" do
      code = """
      ```elixir
      defmodule Demo do
        alias ExRatatui.Widgets.Paragraph
        def p, do: %Paragraph{text: "hi"}
        def encode(x), do: Jason.encode!(x)
      end
      ```
      """

      assert {:skipped, "uses ExRatatui, which the checker doesn't have"} = CodeCheck.run(code)

      calls_only = "```elixir\ndefmodule Demo do\n  def encode(x), do: Jason.encode!(x)\nend\n```"
      assert {:skipped, "uses Jason, which the checker doesn't have"} = CodeCheck.run(calls_only)
    end

    test "still fails a misspelled standard library module" do
      code = "```elixir\ndefmodule Demo do\n  use GenSrver\nend\n```"
      assert {:ran, %{status: :failed, summary: "does not compile"}} = CodeCheck.run(code)
    end

    test "treats compiler warnings as failures" do
      code = "```elixir\ndefmodule W do\n  @nonsense\n  def f, do: 1\nend\n```"
      assert {:ran, %{status: :failed, summary: summary}} = CodeCheck.run(code)
      assert summary =~ "compiler warning"
    end

    test "checks Python doctests" do
      good =
        "```python\ndef add(a, b):\n    \"\"\"\n    >>> add(2, 2)\n    4\n    \"\"\"\n    return a + b\n```"

      bad = String.replace(good, "    4\n", "    5\n")

      assert {:ran, %{status: :passed}} = CodeCheck.run(good)
      assert {:ran, %{status: :failed, summary: "doctests failed"}} = CodeCheck.run(bad)

      untested = "```python\ndef add(a, b):\n    return a + b\n```"
      assert {:ran, %{status: :failed, summary: "no doctests"}} = CodeCheck.run(untested)

      private = "```python\ndef _add(a, b):\n    return a + b\n```"

      assert {:ran, %{status: :passed, summary: "compiled (no doctests)"}} =
               CodeCheck.run(private)
    end

    test "code cannot reach the network or write to the real home directory" do
      marker = Path.expand("~/tiny_axe_sandbox_escape_#{System.unique_integer([:positive])}")

      code = """
      ```elixir
      defmodule Escape do
        File.write(#{inspect(marker)}, "x")
        {:error, _} = :gen_tcp.connect(~c"example.com", 80, [], 2000)
      end
      ```
      """

      assert {:ran, %{status: :passed}} = CodeCheck.run(code)
      refute File.exists?(marker)
    end
  end
end
