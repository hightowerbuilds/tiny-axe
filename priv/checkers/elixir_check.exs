# Runs inside the sandbox: compile a file with diagnostics, then run any doctests.
# Prints one machine-readable line prefixed with TINYAXE_RESULT at the end.
[file, out] = System.argv()

report = fn map ->
  IO.puts("TINYAXE_RESULT " <> JSON.encode!(map))
end

format = fn diags ->
  Enum.map(diags, fn d ->
    line =
      case d.position do
        {l, _c} -> l
        l when is_integer(l) -> l
        _ -> nil
      end

    "line #{line}: #{d.message}"
  end)
end

# The compiler also prints every diagnostic; swallow that since we report them ourselves.
{:ok, _} = Application.ensure_all_started(:ex_unit)

{compiled, _printed} =
  ExUnit.CaptureIO.with_io(:stderr, fn ->
    Kernel.ParallelCompiler.compile_to_path([file], out, return_diagnostics: true)
  end)

case compiled do
  {:error, errors, %{compile_warnings: w, runtime_warnings: rw}} ->
    report.(%{compiled: false, errors: format.(errors), warnings: format.(w ++ rw), doctests: 0, failures: 0})

  {:ok, modules, %{compile_warnings: w, runtime_warnings: rw}} ->
    Code.prepend_path(out)
    ExUnit.start(autorun: false, colors: [enabled: false])

    doc_modules = Enum.filter(modules, &(inspect(Code.fetch_docs(&1)) =~ "iex>"))

    doc_modules
    |> Enum.with_index()
    |> Enum.each(fn {mod, i} ->
      Module.create(
        :"Elixir.TinyAxeDoctest#{i}",
        quote do
          use ExUnit.Case
          doctest unquote(mod)
        end,
        Macro.Env.location(__ENV__)
      )
    end)

    %{total: total, failures: failures} =
      if doc_modules == [], do: %{total: 0, failures: 0}, else: ExUnit.run()

    report.(%{compiled: true, errors: [], warnings: format.(w ++ rw), doctests: total, failures: failures})
end
