defmodule TinyAxe.VaultTest do
  # The vault writer (G1 of docs/plan-knowledge-graph.md): the fixture
  # journals give the fixture vault, and running again, in pieces, after a
  # crash or after a journal is pruned changes nothing it shouldn't.
  use ExUnit.Case, async: true

  alias TinyAxe.Vault
  alias TinyAxe.Vault.Format

  @fixture Path.expand("../fixtures/vault", __DIR__)
  @journals Path.join(@fixture, "journals")
  @expected Path.join(@fixture, "vault")
  @one "20261001-100000-1"
  @two "20261002-110000-2"

  # Every file under a folder, dot folders included, as %{path => contents}.
  defp files(dir) do
    for path <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true),
        File.regular?(path),
        into: %{},
        do: {Path.relative_to(path, dir), File.read!(path)}
  end

  defp notes(dir), do: dir |> files() |> Map.filter(fn {path, _} -> path =~ ~r/\.md$/ end)

  defp manifest(dir),
    do: dir |> Path.join(".tiny-axe/vault.json") |> File.read!() |> JSON.decode!()

  defp copy_journals(tmp) do
    dir = Path.join(tmp, "journals")
    File.cp_r!(@journals, dir)
    dir
  end

  describe "the fixture" do
    @tag :tmp_dir
    test "journals give the fixture vault, byte for byte", %{tmp_dir: tmp} do
      vault = Path.join(tmp, "vault")
      assert {:ok, %{notes: 28, written: 28}} = Vault.ingest(@journals, vault)

      assert notes(vault) == notes(@expected)

      # The manifest, but for when and which tiny-axe wrote it; and the
      # writer's own record beside it.
      got = manifest(vault)
      want = manifest(@expected)

      assert Map.drop(got, ["generated_at", "writer"]) ==
               Map.drop(want, ["generated_at", "writer"])

      assert got["writer"] =~ ~r/^tiny-axe \S+$/
      assert got["generated_at"] =~ ~r/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/
      assert Map.keys(got) |> Enum.sort() == Map.keys(want) |> Enum.sort()

      assert File.read!(Path.join(vault, ".tiny-axe/vault.json"))
             |> String.starts_with?("{\n  \"schema\"")

      assert Map.keys(files(vault)) -- Map.keys(files(@expected)) == [".tiny-axe/ingested.json"]
    end

    @tag :tmp_dir
    test "running again changes nothing", %{tmp_dir: tmp} do
      vault = Path.join(tmp, "vault")
      {:ok, _} = Vault.ingest(@journals, vault)
      before = files(vault)

      assert {:ok, %{written: 0}} = Vault.ingest(@journals, vault)
      assert files(vault) == before
    end

    @tag :tmp_dir
    test "one task at a time gives the same vault as both at once", %{tmp_dir: tmp} do
      apart = Path.join(tmp, "apart")
      {:ok, _} = Vault.ingest(@journals, apart, only: [@one])
      {:ok, _} = Vault.ingest(@journals, apart, only: [@two])

      together = Path.join(tmp, "together")
      {:ok, _} = Vault.ingest(@journals, together)

      assert Map.delete(files(apart), ".tiny-axe/vault.json") ==
               Map.delete(files(together), ".tiny-axe/vault.json")

      assert notes(apart) == notes(@expected)
    end

    @tag :tmp_dir
    test "a task read while it runs carries on where it left off", %{tmp_dir: tmp} do
      journals = copy_journals(tmp)
      calls = Path.join([journals, "tasks", @one, "calls.jsonl"])
      full = File.read!(calls)
      lines = String.split(full, "\n", trim: true)

      # Three calls in, and the gate halfway through writing the fourth.
      File.write!(
        calls,
        Enum.join(Enum.take(lines, 3), "\n") <> "\n" <> String.slice(Enum.at(lines, 3), 0, 40)
      )

      vault = Path.join(tmp, "vault")
      {:ok, _} = Vault.ingest(journals, vault)
      assert notes(vault) != notes(@expected)

      File.write!(calls, full)
      {:ok, _} = Vault.ingest(journals, vault)
      assert notes(vault) == notes(@expected)
    end

    @tag :tmp_dir
    test "a pruned journal's notes stay, and its task says so", %{tmp_dir: tmp} do
      journals = copy_journals(tmp)
      vault = Path.join(tmp, "vault")
      {:ok, _} = Vault.ingest(journals, vault)

      File.rm_rf!(Path.join([journals, "tasks", @one]))
      {:ok, %{written: 1}} = Vault.ingest(journals, vault)

      task = "Tasks/#{@one}.md"
      got = notes(vault)
      want = notes(@expected)
      assert Map.delete(got, task) == Map.delete(want, task)
      assert got[task] == String.replace(want[task], "pruned: false", "pruned: true")

      # A new task still adds to what the pruned one left.
      File.cp_r!(
        Path.join([@journals, "tasks", @one]),
        Path.join([journals, "tasks", "20261003-090000-3"])
      )

      {:ok, _} = Vault.ingest(journals, vault)
      {:ok, props, _} = Format.parse(notes(vault)["Sites/shop.example.md"])
      assert {"seen", 12} in props
      assert {"looked", 2} in props
    end
  end

  describe "writing" do
    @tag :tmp_dir
    test "a crash part way leaves whole notes, and the next run finishes", %{tmp_dir: tmp} do
      vault = Path.join(tmp, "vault")
      {:ok, _} = Vault.ingest(@journals, vault, only: [@one])
      before = files(vault)

      crash = fn _path ->
        n = Process.get(:writes, 0) + 1
        Process.put(:writes, n)
        if n == 3, do: raise("the power went out")
      end

      assert {:error, "the power went out"} = Vault.ingest(@journals, vault, on_write: crash)

      after_crash = files(vault)
      expected = files(@expected)

      for {path, text} <- after_crash do
        refute path =~ ~r/\.tmp$/, "left #{path}"
        refute path == ".tiny-axe/lock"

        if path =~ ~r/\.md$/,
          do: assert(text in [before[path], expected[path]], "#{path} is neither old nor new")
      end

      # The record of what's in is the old one, so nothing is lost or counted twice.
      assert after_crash[".tiny-axe/ingested.json"] == before[".tiny-axe/ingested.json"]

      {:ok, _} = Vault.ingest(@journals, vault)
      assert notes(vault) == notes(@expected)
    end

    @tag :tmp_dir
    test "temporary files a dead writer left are cleared", %{tmp_dir: tmp} do
      vault = Path.join(tmp, "vault")
      File.mkdir_p!(Path.join(vault, "Pages"))
      stray = Path.join(vault, "Pages/.shop.example d114f7ba.md.123.tmp")
      File.write!(stray, "---\nkind: \"pa")

      {:ok, _} = Vault.ingest(@journals, vault)
      refute File.exists?(stray)
    end

    @tag :tmp_dir
    test "a held lock is waited for; a stale one is broken", %{tmp_dir: tmp} do
      vault = Path.join(tmp, "vault")
      lock = Path.join(vault, ".tiny-axe/lock")
      File.mkdir_p!(Path.dirname(lock))
      File.write!(lock, "other\n")

      assert {:error, :locked} = Vault.ingest(@journals, vault, lock_timeout: 50)
      refute File.exists?(Path.join(vault, "Tasks"))

      File.touch!(lock, System.os_time(:second) - 600)
      assert {:ok, _} = Vault.ingest(@journals, vault, lock_timeout: 50)
      refute File.exists?(lock)
    end

    @tag :tmp_dir
    test "a vault another schema wrote is left alone", %{tmp_dir: tmp} do
      vault = Path.join(tmp, "vault")
      File.mkdir_p!(Path.join(vault, ".tiny-axe"))
      File.write!(Path.join(vault, ".tiny-axe/vault.json"), ~s({"schema": "tiny-axe-vault/9"}\n))

      assert {:error, {:vault_schema, "tiny-axe-vault/9"}} = Vault.ingest(@journals, vault)
    end

    @tag :tmp_dir
    test "a vault that can't be written is an error, not a crash", %{tmp_dir: tmp} do
      blocker = Path.join(tmp, "file")
      File.write!(blocker, "")
      assert {:error, _} = Vault.ingest(@journals, Path.join(blocker, "vault"))
    end
  end

  describe "journals as the gate writes them today" do
    # No `class` on calls and no task.json: class from the decision record
    # when there is one, otherwise unrecorded; the driver unrecorded.
    @tag :tmp_dir
    test "are read without class or task.json", %{tmp_dir: tmp} do
      journals = copy_journals(tmp)

      for id <- [@one, @two] do
        dir = Path.join([journals, "tasks", id])
        File.rm!(Path.join(dir, "task.json"))

        stripped =
          dir
          |> Path.join("calls.jsonl")
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Enum.map_join(
            &((&1 |> JSON.decode!() |> Map.delete("class") |> JSON.encode!()) <> "\n")
          )

        File.write!(Path.join(dir, "calls.jsonl"), stripped)
      end

      vault = Path.join(tmp, "vault")
      {:ok, _} = Vault.ingest(journals, vault)
      got = notes(vault)

      classes =
        for {"Paths/" <> _, text} <- got do
          {:ok, props, _} = Format.parse(text)
          props = Map.new(props)
          {props["title"], props["class"], props["drivers"]}
        end

      assert {~s(type "Add a comment" → denied), "outward", ["unrecorded"]} in classes
      assert {~s(click "Proceed to checkout" → refused), "commit", ["unrecorded"]} in classes
      assert {"navigate shop.example/ → ran", "unrecorded", ["unrecorded"]} in classes

      {:ok, props, body} = Format.parse(got["Tasks/#{@one}.md"])
      assert {"driver", "unrecorded"} in props
      assert body =~ "## Request\n\n(not recorded)\n"
      assert_links_resolve(vault)
    end
  end

  describe "what the vault never holds" do
    @tag :tmp_dir
    test "nothing from the fixture it must not copy", %{tmp_dir: tmp} do
      vault = Path.join(tmp, "vault")
      {:ok, _} = Vault.ingest(@journals, vault)

      # Typed text, a search the agent made, query strings, fragments, page
      # context, page titles and the agent's own description of an element.
      secrets = [
        "Great reporting",
        "elixir books",
        "ref=home",
        "tag=x",
        "#comments",
        "In stock",
        "posted publicly",
        "book link",
        "B0C1234567",
        "B0D7654321",
        "Subtotal",
        "Shopping Cart",
        "spending money"
      ]

      assert leaks(vault, secrets) == []
    end

    @tag :tmp_dir
    test "nothing from a hostile journal or from purchases", %{tmp_dir: tmp} do
      journals = Path.join(tmp, "state")
      task = Path.join([journals, "tasks", "20261003-120000-3"])
      File.mkdir_p!(task)

      purchase = Path.join([journals, "purchases", "p-1"])
      File.mkdir_p!(purchase)

      File.write!(
        Path.join(purchase, "events.jsonl"),
        ~s({"t":"order","merchant":"shop.example","address":"shippingsecret 1 Main St","card":"4242424242424242"}\n)
      )

      calls = [
        %{
          tool: "browser__browser_navigate",
          args: %{url: "https://user:hunter2pw@www.shop.example/search?q=secretquery#fragsecret"},
          decision: "ran",
          error: false,
          result:
            "Page: https://shop.example/search?q=secretquery#fragsecret · Results for titlesecret",
          decisions: []
        },
        %{
          tool: "browser__browser_snapshot",
          args: %{},
          decision: "ran",
          error: false,
          result:
            "Page: https://shop.example/search?q=secretquery · T\n\n- textbox \"bodysecret\" [ref=e1]",
          decisions: []
        },
        %{
          tool: "browser__browser_type",
          args: %{ref: "e1", text: "4111 1111 1111 1111 typedsecret", element: "agentdescsecret"},
          decision: "approved",
          error: false,
          result: "Page: https://shop.example/pay/4111111111111111?cc=4111111111111111 · x",
          decisions: ["dec-c1"]
        },
        %{
          tool: "browser__browser_fill_form",
          args: %{fields: [%{name: "card", value: "5555555555554444"}]},
          decision: "ran",
          error: false,
          result: "Page: https://shop.example/pay/4111111111111111#cvc=123 · fieldsecret",
          decisions: []
        },
        %{
          tool: "memory__create_entities",
          args: %{entities: [%{name: "argsecret"}]},
          decision: "ran",
          error: false,
          result: ~s({"ok":"resultsecret"}),
          decisions: []
        }
      ]

      File.write!(
        Path.join(task, "calls.jsonl"),
        Enum.map_join(
          calls,
          &(JSON.encode!(Map.put(&1, :at, "2026-10-03T12:00:00.000000Z")) <> "\n")
        )
      )

      decision = %{
        id: "dec-c1",
        at: "2026-10-03T12:00:00.000000Z",
        policy_version: "browser-policy/2",
        questions_version: "browser-effects/2",
        evidence_schema: "browser-evidence/1",
        model: "jev-1.13.0",
        evidence: %{
          task: %{objective: "objectivesecret"},
          target: %{
            page: "https://shop.example/search?q=evidencesecret#evfrag",
            text: "Card number",
            role: "textbox",
            context: "contextsecret 4111111111111111"
          },
          proposed_action: %{args: %{text: "proposedsecret"}}
        },
        answers: %{spends: %{p: 0.1}, sends: %{p: 0.6}, saves_on_change: %{p: 0.1}},
        disposition: "outward",
        reason_codes: ["sends_signal"],
        reason: "reasonsecret"
      }

      File.write!(Path.join(task, "decisions.jsonl"), JSON.encode!(decision) <> "\n")

      vault = Path.join(tmp, "vault")
      {:ok, _} = Vault.ingest(journals, vault)

      secrets =
        ~w(hunter2pw secretquery fragsecret titlesecret bodysecret typedsecret agentdescsecret
           fieldsecret argsecret resultsecret objectivesecret evidencesecret evfrag contextsecret
           proposedsecret reasonsecret shippingsecret 4111 5555 4242 cvc user:) ++ ["Main St"]

      assert leaks(vault, secrets) == []
      assert_links_resolve(vault)

      # What it does keep: the shape of what happened.
      got = notes(vault)

      assert Map.has_key?(
               got,
               "Pages/shop.example-search " <>
                 Format.hash8("page", "shop.example/search") <> ".md"
             )

      assert Map.has_key?(
               got,
               "Pages/shop.example-pay-id " <>
                 Format.hash8("page", "shop.example/pay/:id") <> ".md"
             )

      assert Enum.any?(got, fn {path, _} -> path =~ ~r{^Controls/Card-number-textbox } end)
    end
  end

  # Query strings, fragments, long digit runs (card numbers) and the given
  # strings, anywhere in the vault, the writer's own files included.
  defp leaks(vault, secrets) do
    for {path, text} <- files(vault),
        {what, found?} <-
          [
            query: text =~ ~r/\?[^\s"\]\)]*=/,
            fragment: text =~ ~r/[^\s\\#]#[A-Za-z0-9_-]/,
            digits: text =~ ~r/(?<!\d)\d{12,19}(?!\d)/ or text =~ ~r/\d{4}([ -])\d{4}\1\d{4}/
          ] ++ Enum.map(secrets, &{&1, String.contains?(text, &1)}),
        found? do
      {path, what}
    end
  end

  defp assert_links_resolve(vault) do
    names = vault |> notes() |> Map.keys() |> MapSet.new(&Path.basename(&1, ".md"))

    for {path, text} <- notes(vault) do
      {:ok, _, body} = Format.parse(text)

      for target <- Format.links(body),
          do: assert(target in names, "#{path} links to #{target}, which isn't there")
    end
  end
end

defmodule TinyAxe.VaultProcessTest do
  # The running writer: a closed task reaches the vault in the background.
  # Not async: it switches the vault on for the whole app while it runs.
  use ExUnit.Case, async: false

  alias TinyAxe.Vault

  @fixture Path.expand("../fixtures/vault/journals/tasks/20261001-100000-1", __DIR__)

  @tag :tmp_dir
  test "task_closed folds the task in; backfill waits for the rest", %{tmp_dir: tmp} do
    refute Vault.enabled?()
    assert Vault.task_closed("nothing-happens") == :ok

    id = "20261001-100000-#{System.unique_integer([:positive])}"
    journal = Path.join([TinyAxe.Ops.Journal.state_dir(), "tasks", id])
    File.cp_r!(@fixture, journal)

    previous = Application.get_env(:tiny_axe, :vault)
    Application.put_env(:tiny_axe, :vault, enabled: true, dir: Path.join(tmp, "vault"))

    on_exit(fn ->
      File.rm_rf!(journal)

      if previous,
        do: Application.put_env(:tiny_axe, :vault, previous),
        else: Application.delete_env(:tiny_axe, :vault)
    end)

    assert Vault.task_closed(id) == :ok
    # The cast is handled before the call that follows it.
    assert {:ok, _} = Vault.backfill()
    assert File.read!(Path.join([tmp, "vault", "Tasks", id <> ".md"])) =~ "## Steps"
  end
end
