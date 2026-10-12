# Run with: mix run --no-start scripts/memory-review-eval.exs
# Synthetic sources only. No app startup, accounts, remote adapters, or real chat history.
alias TinyAxe.{History, Memory}
for app <- [:req, :exqlite], do: Application.ensure_all_started(app)

root = Path.join(System.tmp_dir!(), "tiny-axe-review-eval-#{System.unique_integer([:positive])}")
history = Path.join(root, "history")
File.mkdir_p!(history)

# Fixed cases: three vocabulary mismatches, an existing lexical hit, and a
# negative control. This is a small retrieval check, not an accuracy benchmark.
fixtures = [
  {"photo backup",
   "Snapshots of the family JPEG collection stay on the NAS. We chose restic for the nightly offsite copy; installation is still pending."},
  {"authentication",
   "The laptop needs FIDO2 with a YubiKey. Disable SMS codes once both hardware keys are enrolled."},
  {"migration",
   "For the PostgreSQL switchover, stop the writer, take pg_dump, restore on the new host, and compare row counts before changing DNS."},
  {"violet", "The violet GPU has 24 GB of VRAM. We chose it, but have not bought it."},
  {nil, "Saturday's picnic will be by the river. Bring pears and blankets."}
]

cases =
  for {query, passage} <- fixtures do
    id = History.new_id()

    File.write!(
      Path.join(history, id <> ".json"),
      JSON.encode!(%{
        id: id,
        title: query || "Picnic",
        updated: "2026-10-12",
        entries: [%{kind: "user", text: passage}]
      })
    )

    {query, id}
  end

{:ok, server} =
  Memory.start_link(
    name: :memory_review_eval,
    path: Path.join(root, "memory.sqlite3"),
    history: history
  )

opts = [server: server, history: history, sync: false]
{:ok, model} = Memory.Model.available()
IO.puts("Verified local model: #{model}")
Memory.review(true, opts)

elapsed =
  for _ <- fixtures do
    {:ok, job} = Memory.next_review(opts)
    {micros, result} = :timer.tc(fn -> Memory.Review.annotate(job) end)

    case result do
      {:ok, note} ->
        :ok = Memory.save_review(job, result, opts)

        IO.puts(
          JSON.encode!(%{
            generated_note: note.note,
            verified_quote: note.quote,
            seconds: Float.round(micros / 1_000_000, 2)
          })
        )

      error ->
        raise "Local review failed: #{inspect(error)}"
    end

    micros
  end

results =
  for {query, id} <- cases, query != nil do
    {:ok, raw} = Memory.search(query, opts)
    {:ok, notes} = Memory.related(query, opts)

    %{
      query: query,
      raw_found: Enum.any?(raw.hits, &(&1.chat_id == id)),
      enriched_found: Enum.any?(raw.hits ++ notes.hits, &(&1.chat_id == id)),
      unrelated_hits: Enum.count(raw.hits ++ notes.hits, &(&1.chat_id != id))
    }
  end

{:ok, negative} = Memory.related("encryption", opts)
{:ok, coverage} = Memory.status(opts)

report = %{
  cases: results,
  negative_control_hits: length(negative.hits),
  review_seconds: Float.round(Enum.sum(elapsed) / 1_000_000, 2),
  coverage: coverage,
  improved_cases: Enum.count(results, &(not &1.raw_found and &1.enriched_found))
}

File.write!(Path.join(root, "report.json"), JSON.encode!(report))
IO.puts(JSON.encode!(report))
IO.puts("Synthetic fixtures and report: #{root}")
{:ok, answer} = Memory.Recall.ask("What is the laptop authentication plan?", opts)

unless String.contains?(answer.answer, "[1]"),
  do: raise("Local Gemma did not return a source-checked answer for the authentication fixture")

IO.puts("Local recall answer:\n" <> answer.answer)
GenServer.stop(server)

if report.improved_cases == 0,
  do: raise("Generated notes did not improve this fixed retrieval set")
