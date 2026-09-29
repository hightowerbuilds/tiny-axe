defmodule TinyAxe.CodeCheck do
  @moduledoc """
  Compiles and tests code blocks from a model response inside `TinyAxe.Sandbox`.

    * Elixir — compiled with warnings treated as failures, then doctests run
    * Python — byte-compiled, then doctests run if the code has any

  Code that defines public functions but has no doctests fails: small models
  otherwise "fix" a broken doctest by deleting it, which leaves nothing tested.

  Code that uses a package the sandbox doesn't have (say, `use ExRatatui.App`)
  is skipped rather than failed, since no fix to the code could make it compile.

  All blocks of the first supported language are concatenated into one file,
  skipping blocks that are shell sessions or IEx transcripts rather than source.
  """

  alias TinyAxe.Sandbox

  @type result :: %{
          language: :elixir | :python,
          status: :passed | :failed,
          summary: String.t(),
          output: String.t()
        }

  @languages %{
    "elixir" => :elixir,
    "ex" => :elixir,
    "exs" => :elixir,
    "python" => :python,
    "py" => :python,
    "python3" => :python
  }

  @max_output 2_000

  @how_to_doctest %{
    elixir: """
    Your code defines public functions but has no doctests, so nothing was tested.
    Add `iex>` examples inside each public function's @doc, indented four spaces, \
    with the expected result on the next line:

      @doc \"\"\"
      Doubles a number.

          iex> MyMod.double(21)
          42
      \"\"\"

    They are run automatically. Do not call `doctest`, `use ExUnit.Case` or \
    `ExUnit.start` in the answer.
    """,
    python: """
    Your code defines public functions but has no doctests, so nothing was tested.
    Add `>>>` examples to each public function's docstring, with the expected \
    result on the next line. They are run automatically. Do not call \
    `doctest.testmod()` or add an `if __name__ == "__main__":` test runner.
    """
  }

  @spec run(String.t()) :: {:ran, result()} | {:skipped, String.t()}
  def run(text) do
    with {:enabled, true} <- {:enabled, Application.get_env(:tiny_axe, :code_check, true)},
         [_ | _] = blocks <- extract(text),
         {:sandbox, true} <- {:sandbox, Sandbox.available?()} do
      check(blocks)
    else
      {:enabled, _} ->
        {:skipped, "disabled"}

      [] ->
        {:skipped, "no Elixir or Python code"}

      {:sandbox, false} ->
        {:skipped, "bubblewrap (bwrap) not installed; refusing to run unsandboxed"}
    end
  end

  @doc "Returns the source blocks of the first supported language as `[{lang, code}]`."
  @spec extract(String.t()) :: [{atom(), String.t()}]
  def extract(text) do
    blocks =
      ~r/```([\w+-]*)[^\n]*\n(.*?)```/s
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.flat_map(fn [tag, code] ->
        case Map.fetch(@languages, String.downcase(tag)) do
          {:ok, lang} -> if source?(code), do: [{lang, code}], else: []
          :error -> []
        end
      end)

    case blocks do
      [] -> []
      [{lang, _} | _] -> Enum.filter(blocks, &(elem(&1, 0) == lang))
    end
  end

  defp source?(code) do
    not String.match?(String.trim_leading(code), ~r/^(iex(\(\d+\))?>|\$ |>>> |mix |pip )/)
  end

  defp check([{lang, _} | _] = blocks) do
    source = Enum.map_join(blocks, "\n\n", &elem(&1, 1))
    workdir = Path.join(System.tmp_dir!(), "tiny_axe_check_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workdir)

    try do
      case check(lang, source, workdir) do
        {:skipped, _reason} = skipped -> skipped
        # The sandbox itself failed; that says nothing about the code.
        %{output: "bwrap:" <> _ = output} -> {:skipped, "sandbox error: " <> String.trim(output)}
        result -> {:ran, result}
      end
    after
      File.rm_rf(workdir)
    end
  end

  defp check(:elixir, source, workdir) do
    File.write!(Path.join(workdir, "answer.ex"), source)

    File.cp!(
      Application.app_dir(:tiny_axe, "priv/checkers/elixir_check.exs"),
      Path.join(workdir, "check.exs")
    )

    File.mkdir_p!(Path.join(workdir, "ebin"))

    {output, status} = Sandbox.cmd(~w(elixir check.exs answer.ex ebin), workdir)

    case Regex.run(~r/^TINYAXE_RESULT (.*)$/m, output) do
      [line, json] ->
        r = JSON.decode!(json)
        details = String.replace(output, line, "") |> String.trim()

        case missing_packages(r, source) do
          [] ->
            elixir_result(r, details, public_functions?(:elixir, source))

          packages ->
            {:skipped, "uses #{Enum.join(packages, ", ")}, which the checker doesn't have"}
        end

      nil ->
        failed(:elixir, timeout_or("checker crashed", status), output)
    end
  end

  defp check(:python, source, workdir) do
    File.write!(Path.join(workdir, "answer.py"), source)
    doctests? = String.contains?(source, ">>>")

    script =
      "python3 -m py_compile answer.py || exit 10\n" <>
        if(doctests?, do: "python3 -m doctest answer.py || exit 11\n", else: "")

    case Sandbox.cmd(["sh", "-c", script], workdir) do
      {_out, 0} ->
        cond do
          doctests? -> passed(:python, "compiled, doctests passed")
          public_functions?(:python, source) -> no_doctests(:python)
          true -> passed(:python, "compiled (no doctests)")
        end

      {out, 10} ->
        failed(:python, "does not compile", out)

      {out, 11} ->
        failed(:python, "doctests failed", out)

      {out, status} ->
        failed(:python, timeout_or("check failed (exit #{status})", status), out)
    end
  end

  defp elixir_result(%{"compiled" => false} = r, _details, _public?) do
    failed(:elixir, "does not compile", Enum.join(r["errors"] ++ r["warnings"], "\n"))
  end

  # `details` is ExUnit's output, which only matters when doctests fail.
  defp elixir_result(
         %{"warnings" => warnings, "failures" => f, "doctests" => t},
         details,
         public?
       ) do
    problems =
      [
        warnings != [] && "#{length(warnings)} compiler warning(s)",
        f > 0 && "#{f}/#{t} doctests failed"
      ]
      |> Enum.filter(& &1)

    cond do
      problems != [] ->
        output = Enum.join(warnings, "\n") <> if(f > 0, do: "\n\n" <> details, else: "")
        failed(:elixir, Enum.join(problems, ", "), output)

      t == 0 and public? ->
        no_doctests(:elixir)

      t == 0 ->
        passed(:elixir, "compiled cleanly (no doctests)")

      true ->
        passed(:elixir, "compiled cleanly, #{t}/#{t} doctests passed")
    end
  end

  @missing_module ~r/(?:module ([A-Z][\w.]*) is not (?:loaded|available)|cannot expand struct ([A-Z][\w.]*))/

  # Modules that couldn't be found, when every compile error (or, if it compiled,
  # every warning) is of that kind: they come from a package or from the rest of
  # the user's project, which the sandbox doesn't have. Reported by namespace
  # (`ExRatatui`), or in full when the answer defines others in that namespace
  # (`TinyAxe.Pipeline`). A missing Elixir module, or a near-miss of one
  # (`GenSrver`), is a mistake rather than a missing package.
  defp missing_packages(result, source) do
    messages = if result["compiled"], do: result["warnings"], else: result["errors"]
    elixir = elixir_namespaces()

    missing =
      List.wrap(messages)
      # Follow-on error that every failed module also reports.
      |> Enum.reject(&(&1 =~ "errors have been logged"))
      |> Enum.map(fn e ->
        case Regex.run(@missing_module, e, capture: :all_but_first) do
          nil -> nil
          mods -> Enum.find(mods, &(&1 != ""))
        end
      end)

    namespaces = Enum.map(missing, &(&1 && namespace(&1)))

    if missing == [] or nil in missing or
         Enum.any?(namespaces, &(&1 in elixir or near_miss?(&1, elixir))) do
      []
    else
      missing
      |> Enum.reject(&String.match?(source, ~r/defmodule #{Regex.escape(&1)}\b/))
      |> Enum.map(fn mod ->
        ns = namespace(mod)
        if String.match?(source, ~r/defmodule #{Regex.escape(ns)}\b/), do: mod, else: ns
      end)
      |> Enum.uniq()
    end
  end

  defp namespace(mod), do: mod |> String.split(".") |> hd()

  defp near_miss?(namespace, elixir) do
    namespace not in elixir and Enum.any?(elixir, &(String.jaro_distance(&1, namespace) >= 0.9))
  end

  # Top-level namespaces of Elixir's own apps. They also contain Erlang modules
  # (`:elixir_compiler`), which have no namespace.
  defp elixir_namespaces do
    for app <- [:elixir, :eex, :ex_unit, :logger, :mix, :iex],
        Application.load(app) in [:ok, {:error, {:already_loaded, app}}],
        mod <- List.wrap(Application.spec(app, :modules)),
        "Elixir." <> name <- [Atom.to_string(mod)],
        uniq: true,
        do: name |> String.split(".") |> hd()
  end

  # `def f` but not `defp`/`defmodule`; Python functions not starting with `_`.
  defp public_functions?(:elixir, source), do: String.match?(source, ~r/^\s*def[\s(]/m)
  defp public_functions?(:python, source), do: String.match?(source, ~r/^def (?!_)\w/m)

  defp no_doctests(lang), do: failed(lang, "no doctests", @how_to_doctest[lang])

  defp timeout_or(_msg, 124), do: "timed out"
  defp timeout_or(msg, _status), do: msg

  defp passed(lang, summary), do: %{language: lang, status: :passed, summary: summary, output: ""}

  defp failed(lang, summary, output) do
    %{language: lang, status: :failed, summary: summary, output: truncate(String.trim(output))}
  end

  defp truncate(s) when byte_size(s) <= @max_output, do: s
  defp truncate(s), do: binary_part(s, 0, @max_output) <> "\n…(truncated)"
end
