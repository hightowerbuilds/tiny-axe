defmodule TinyAxe.MemoryRecallTest do
  use ExUnit.Case, async: false
  alias TinyAxe.{History, Memory}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:tiny_axe, :memory)
    decider = Application.get_env(:tiny_axe, :decider)
    jev = Application.get_env(:tiny_axe, :jev)

    Application.put_env(:tiny_axe, :jev,
      api_key: "synthetic-test-key",
      req_options: [plug: {Req.Test, :forbidden_memory_jev}]
    )

    Req.Test.stub(:forbidden_memory_jev, fn _ -> flunk("local memory attempted hosted Jev") end)
    Application.put_env(:tiny_axe, :decider, TinyAxe.Decider.Jev)

    Application.put_env(:tiny_axe, :memory,
      model: "gemma4:e4b-it-qat",
      ollama_url: "http://127.0.0.1:11434",
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn ->
      Application.put_env(:tiny_axe, :memory, previous)
      Application.put_env(:tiny_axe, :decider, decider)
      Application.put_env(:tiny_axe, :jev, jev)
    end)

    history = Path.join(dir, "history")
    File.mkdir_p!(history)
    id = History.new_id()

    File.write!(
      Path.join(history, id <> ".json"),
      JSON.encode!(%{
        id: id,
        title: "GPU choice",
        updated: "2026-01-01",
        entries: [%{kind: "user", text: "We chose the violet GPU, but have not bought it."}]
      })
    )

    server =
      start_supervised!(
        {Memory,
         name: :memory_recall_test, history: history, path: Path.join(dir, "memory.sqlite3")}
      )

    %{opts: [server: server, history: history, sync: false]}
  end

  defp stub(answer) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = JSON.decode!(body)

      case conn.request_path do
        "/api/show" ->
          Req.Test.json(conn, %{
            details: %{family: "gemma4"},
            model_info: %{"general.parameter_count" => 4_000_000_000}
          })

        "/api/chat" ->
          assert request["model"] == "gemma4:e4b-it-qat"

          data =
            if get_in(request, ["format", "properties", "queries"]),
              do: %{queries: ["violet"]},
              else: answer

          Req.Test.json(conn, %{message: %{content: JSON.encode!(data)}})
      end
    end)
  end

  test "Gemma retrieves original evidence and validates quotes without using hosted Jev", ctx do
    stub(%{
      answer: "You chose the violet GPU, but had not bought it. [1]",
      evidence: [%{source: 1, quote: "We chose the violet GPU, but have not bought it."}]
    })

    assert {:ok, result} = Memory.Recall.ask("What GPU did we choose?", ctx.opts)
    assert result.answer =~ "had not bought it"
    assert result.answer =~ "GPU choice"
    assert length(result.hits) == 1
  end

  test "fabricated quotes are not displayed as a grounded answer", ctx do
    stub(%{
      answer: "You bought it. [1]",
      evidence: [%{source: 1, quote: "I bought the violet GPU"}]
    })

    assert {:ok, result} = Memory.Recall.ask("What GPU?", ctx.opts)
    refute result.answer =~ "You bought it"
    assert result.answer =~ "could not produce"
    assert length(result.hits) == 1
  end

  test "review uses verified local Gemma with hosted Jev configured, and rejects invented quotes" do
    note = %{
      description: "GPU choice still pending purchase",
      topics: ["hardware"],
      question: "What GPU did we choose?",
      quote: "We chose the violet GPU"
    }

    stub(note)
    job = %{kind: "user", text: "We chose the violet GPU, but have not bought it."}
    assert {:ok, %{note: text}} = Memory.Review.annotate(job)
    assert text =~ "GPU choice"
    stub(%{note | quote: "We bought it"})
    assert {:error, _} = Memory.Review.annotate(job)
  end

  test "remote endpoints, cloud-backed models and redirects are rejected" do
    config = Application.get_env(:tiny_axe, :memory)

    Application.put_env(
      :tiny_axe,
      :memory,
      Keyword.put(config, :ollama_url, "https://api.example.test")
    )

    assert {:error, _} = Memory.Model.client()
    Application.put_env(:tiny_axe, :memory, config)

    Req.Test.stub(
      __MODULE__,
      &Req.Test.json(&1, %{
        remote_host: "cloud",
        details: %{family: "gemma4"},
        model_info: %{"general.parameter_count" => 1}
      })
    )

    assert {:error, _} = Memory.Model.available()

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://api.example.test")
      |> Plug.Conn.send_resp(307, "")
    end)

    assert {:error, _} = Memory.Model.available()
  end

  test "missing local inference leaves direct search usable", ctx do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
    assert {:error, _} = Memory.Recall.ask("What GPU?", ctx.opts)
    assert {:ok, %{total: 1}} = Memory.search("violet", ctx.opts)
  end

  test "a generated match in a long entry leads to original text, never generated evidence",
       ctx do
    history = ctx.opts[:history]
    [name] = File.ls!(history)
    path = Path.join(history, name)
    doc = JSON.decode!(File.read!(path))
    quote = "We chose the violet GPU, but have not bought it."
    text = String.duplicate("filler ", 500) <> quote
    File.write!(path, JSON.encode!(%{doc | "entries" => [%{kind: "user", text: text}]}))
    Memory.review(true, ctx.opts)

    for _ <- Memory.Notes.chunks(text) do
      {:ok, job} = Memory.next_review(ctx.opts)

      if String.contains?(job.text, quote) do
        assert :ok =
                 Memory.save_review(
                   job,
                   {:ok, %{note: "thermal fabricated-description", quote: quote}},
                   ctx.opts
                 )
      else
        assert :ok = Memory.save_review(job, {:ok, %{note: "filler", quote: "filler"}}, ctx.opts)
      end
    end

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = JSON.decode!(body)

      case conn.request_path do
        "/api/show" ->
          Req.Test.json(conn, %{
            details: %{family: "gemma4"},
            model_info: %{"general.parameter_count" => 4_000_000_000}
          })

        "/api/chat" ->
          data =
            if get_in(request, ["format", "properties", "queries"]) do
              %{queries: ["thermal"]}
            else
              messages = JSON.encode!(request["messages"])
              assert messages =~ quote
              refute messages =~ "fabricated-description"

              %{
                answer: "You chose the violet GPU; buying it was still pending. [1]",
                evidence: [%{source: 1, quote: quote}]
              }
            end

          Req.Test.json(conn, %{message: %{content: JSON.encode!(data)}})
      end
    end)

    assert {:ok, %{total: 0}} = Memory.search("thermal", ctx.opts)
    assert {:ok, result} = Memory.Recall.ask("What was the thermal choice?", ctx.opts)
    assert result.answer =~ "buying it was still pending"
    assert [%{source_start: start}] = result.hits
    assert start > 3000
  end
end
