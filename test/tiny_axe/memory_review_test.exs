defmodule TinyAxe.MemoryReviewTest do
  use ExUnit.Case, async: false
  alias TinyAxe.{History, Memory}
  alias TinyAxe.Memory.{Inference, Notes, Review}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    history = Path.join(dir, "history")
    File.mkdir_p!(history)
    path = Path.join(dir, "memory.sqlite3")
    server = start_supervised!({Memory, name: :memory_review_test, history: history, path: path})
    inference = start_supervised!({Inference, name: :memory_review_inference})

    %{
      opts: [server: server, history: history, sync: false],
      history: history,
      path: path,
      inference: inference
    }
  end

  defp save(ctx, texts, id \\ History.new_id()) do
    File.write!(
      Path.join(ctx.history, id <> ".json"),
      JSON.encode!(%{
        id: id,
        title: "Original source",
        updated: "2026-01-01",
        entries: Enum.map(texts, &%{kind: "user", text: &1})
      })
    )

    id
  end

  defp result(job, note \\ "photo backup"),
    do: {:ok, %{note: note, quote: String.slice(job.text, 0, 40)}}

  defp next(ctx) do
    assert {:ok, job} = Memory.next_review(ctx.opts)
    assert job != nil
    job
  end

  test "opt-in persists; generated matches preserve exact search and source provenance", ctx do
    id = save(ctx, ["Use restic for the family JPEG collection."])
    assert {:ok, nil} = Memory.next_review(ctx.opts)
    assert {:ok, _} = Memory.review(true, ctx.opts)
    job = next(ctx)
    assert job.model == Memory.Model.name()
    assert job.version == Notes.version()
    assert :ok = Memory.save_review(job, result(job), ctx.opts)
    assert {:ok, %{total: 0}} = Memory.search("photo backup", ctx.opts)
    assert {:ok, %{hits: [hit]}} = Memory.related("photo backup", ctx.opts)
    assert hit.chat_id == id
    assert hit.generated_note == "photo backup"
    assert {:ok, %{entry: %{"text" => text}}} = Memory.read(hit, ctx.opts)
    assert String.contains?(text, hit.excerpt)
    assert {:ok, %{review: %{ready: 1, pending: 0}}} = Memory.status(ctx.opts)
    assert {:ok, _} = Memory.review(false, ctx.opts)
    stop_supervised!(Memory)

    server =
      start_supervised!({Memory, name: :memory_review_test, history: ctx.history, path: ctx.path})

    opts = Keyword.put(ctx.opts, :server, server)
    assert {:ok, %{review: %{enabled: false, ready: 1}}} = Memory.status(opts)
    assert {:ok, %{hits: [_]}} = Memory.related("photo backup", opts)
  end

  test "append preserves notes, edit/delete invalidates them, and late results cannot revive them",
       ctx do
    id = save(ctx, ["original passage"])
    Memory.review(true, ctx.opts)
    job = next(ctx)
    assert :ok = Memory.save_review(job, result(job), ctx.opts)
    save(ctx, ["original passage", "appended passage"], id)
    assert {:ok, %{review: %{ready: 1, unprepared_entries: 1}}} = Memory.status(ctx.opts)
    assert next(ctx).position == 1
    save(ctx, ["changed passage"], id)
    assert {:error, :stale_source} = Memory.save_review(job, result(job), ctx.opts)
    assert {:ok, %{hits: []}} = Memory.related("photo backup", ctx.opts)
    changed = next(ctx)
    assert :ok = Memory.save_review(changed, result(changed), ctx.opts)
    File.rm!(Path.join(ctx.history, id <> ".json"))
    assert {:ok, %{hits: []}} = Memory.related("photo backup", ctx.opts)
    assert {:error, :stale_source} = Memory.save_review(changed, result(changed), ctx.opts)
  end

  test "every part of a long Unicode entry is reviewed and rebuild clears only derived data",
       ctx do
    text = String.duplicate("🦞 café é ", 450) <> "the final decision"
    id = save(ctx, [text])
    Memory.review(true, ctx.opts)
    chunks = Notes.chunks(text)
    assert Enum.map_join(chunks, &elem(&1, 1)) == text
    assert length(chunks) > 3

    for {start, part} <- chunks do
      assert String.valid?(part)
      assert byte_size(part) <= 1100
      job = next(ctx)
      assert job.start == start
      assert job.text == part
      assert :ok = Memory.save_review(job, result(job), ctx.opts)
    end

    assert {:ok, nil} = Memory.next_review(ctx.opts)
    assert {:ok, %{review: %{ready: 0, enabled: true}}} = Memory.rebuild(ctx.opts)
    assert File.exists?(Path.join(ctx.history, id <> ".json"))
    assert {:ok, %{total: 1}} = Memory.search("\"final decision\"", ctx.opts)
  end

  test "invalid quotes and inference failures back off, retry explicitly, and never count as coverage",
       ctx do
    save(ctx, ["original passage"])
    Memory.review(true, ctx.opts)
    job = next(ctx)

    assert {:error, :review_failed} =
             Memory.save_review(job, {:ok, %{note: "photo backup", quote: "invented"}}, ctx.opts)

    assert {:ok, nil} = Memory.next_review(ctx.opts)
    assert {:ok, %{review: %{failed: 1, ready: 0}}} = Memory.status(ctx.opts)
    Memory.retry_reviews(ctx.opts)
    assert next(ctx).hash == job.hash
    assert {:error, :review_failed} = Memory.save_review(job, {:error, :offline}, ctx.opts)
    assert {:ok, nil} = Memory.next_review(ctx.opts)
    assert {:ok, %{total: 1}} = Memory.search("original", ctx.opts)
  end

  test "model changes retire old notes from retrieval and queue new reviews", ctx do
    config = Memory.Model.settings()
    on_exit(fn -> Application.put_env(:tiny_axe, :memory, config) end)
    save(ctx, ["original passage"])
    Memory.review(true, ctx.opts)
    job = next(ctx)
    assert :ok = Memory.save_review(job, result(job), ctx.opts)

    Application.put_env(
      :tiny_axe,
      :memory,
      Keyword.put(config, :model, "gemma-another-local-model")
    )

    assert {:ok, %{hits: []}} = Memory.related("photo backup", ctx.opts)
    assert {:ok, %{review: %{ready: 0, pending: 1}}} = Memory.status(ctx.opts)
    assert next(ctx).model == "gemma-another-local-model"
    assert {:error, :stale_source} = Memory.save_review(job, result(job), ctx.opts)
  end

  test "foreground cancels background, one background owns the slot, and caller death releases it",
       ctx do
    parent = self()

    background =
      spawn(fn ->
        assert :ok = Inference.background(ctx.inference)
        send(parent, :background_started)

        receive do
          :finish -> :ok
        end
      end)

    bg_ref = Process.monitor(background)
    assert_receive :background_started
    assert :busy = Inference.background(ctx.inference)

    foreground =
      spawn(fn ->
        Inference.foreground(
          fn ->
            send(parent, :foreground_started)

            receive do
              :finish -> :ok
            end
          end,
          ctx.inference
        )
      end)

    assert_receive :foreground_started
    assert_receive {:DOWN, ^bg_ref, :process, ^background, :killed}
    assert :busy = Inference.background(ctx.inference)
    Process.exit(foreground, :kill)
    eventually(fn -> :sys.get_state(ctx.inference).foreground == %{} end)
    restarted = spawn(fn -> send(parent, {:slot, Inference.background(ctx.inference)}) end)
    assert_receive {:slot, :ok}
    refute Process.alive?(restarted)
  end

  test "worker resumes an interrupted passage without counting cancellation as failure", ctx do
    save(ctx, ["original passage"])
    Memory.review(true, ctx.opts)
    parent = self()

    worker =
      start_supervised!(
        {Review,
         name: :memory_review_worker,
         active: true,
         interval: 20,
         memory: ctx.opts,
         inference: ctx.inference,
         annotate: fn job ->
           send(parent, {:annotating, self(), job.hash})

           receive do
             :finish -> result(job)
           end
         end}
      )

    assert_receive {:annotating, first, hash}, 2000

    Inference.foreground(
      fn ->
        eventually(fn -> not Process.alive?(first) end)
        assert {:ok, %{review: %{failed: 0, ready: 0}}} = Memory.status(ctx.opts)
        refute_receive {:annotating, _, _}, 60
      end,
      ctx.inference
    )

    assert_receive {:annotating, second, ^hash}, 2000
    send(second, :finish)
    eventually(fn -> match?({:ok, %{review: %{ready: 1}}}, Memory.status(ctx.opts)) end)
    GenServer.call(worker, :pause)
    assert Process.alive?(worker)
  end

  test "a crashing review backs off and stopping the worker kills active inference", ctx do
    save(ctx, ["original passage"])
    Memory.review(true, ctx.opts)
    parent = self()

    start_supervised!(
      {Review,
       name: :memory_crash_worker,
       active: true,
       interval: 20,
       memory: ctx.opts,
       inference: ctx.inference,
       annotate: fn _ ->
         send(parent, :attempted)
         raise "synthetic inference failure"
       end}
    )

    assert_receive :attempted, 2000

    eventually(fn ->
      match?({:ok, %{review: %{failed: 1, ready: 0}}}, Memory.status(ctx.opts))
    end)

    refute_receive :attempted, 100
    stop_supervised!(Review)
    Memory.retry_reviews(ctx.opts)

    start_supervised!(
      {Review,
       name: :memory_crash_worker,
       active: true,
       interval: 20,
       memory: ctx.opts,
       inference: ctx.inference,
       annotate: fn _ ->
         send(parent, {:working, self()})

         receive do
           :finish -> {:error, :unused}
         end
       end}
    )

    assert_receive {:working, pid}, 2000
    ref = Process.monitor(pid)
    stop_supervised!(Review)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert {:ok, %{review: %{failed: 0, ready: 0}}} = Memory.status(ctx.opts)
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, remaining - 1)
        )
  end
end
