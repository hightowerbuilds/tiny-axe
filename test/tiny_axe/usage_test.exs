defmodule TinyAxe.UsageTest do
  @moduledoc """
  Token use for /token (`TinyAxe.Usage`): the record and its totals with a
  copy of the process on a file of its own, and each place that reports a
  call (Jev, Ollama, Claude answers, the agent) through the app's own copy.
  """

  use ExUnit.Case, async: false

  alias TinyAxe.Usage

  @moduletag :tmp_dir

  defp start(dir, opts \\ []) do
    path = Path.join(dir, "usage.jsonl")
    name = :"usage_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: name, path: path, session: "this-session", listen: false], opts)
    pid = start_supervised!({Usage, opts}, id: name)
    %{pid: pid, path: path}
  end

  # As the telemetry handler does.
  defp record(pid, backend, kind, tokens, ok \\ true) do
    m = Map.merge(%{input: 0, output: 0, cache_read: 0, cache_write: 0}, tokens)
    GenServer.cast(pid, {:record, m, %{backend: backend, kind: kind, model: "m", ok: ok, ms: 5}})
  end

  defp line(at, fields) do
    JSON.encode!(
      Map.merge(
        %{
          at: DateTime.to_iso8601(at),
          session: "older",
          backend: "claude",
          kind: "answer",
          ok: true,
          input: 0,
          output: 0
        },
        fields
      )
    ) <> "\n"
  end

  describe "the record and its totals" do
    test "each call is a line; totals by backend and kind, for session, today and the week", %{
      tmp_dir: dir
    } do
      %{pid: pid, path: path} = start(dir)

      record(pid, :claude, :answer, %{input: 400, output: 42, cache_read: 28})
      record(pid, :claude, :agent, %{input: 1000, output: 100, cache_write: 7})
      record(pid, :claude, :subagent, %{input: 10, output: 1})
      record(pid, :jev, :decision, %{input: 300, output: 12})
      record(pid, :jev, :decision, %{}, false)
      record(pid, :ollama, :local, %{input: 900, output: 80})

      s = Usage.summary(pid)
      assert s.session.claude.calls == 3
      assert s.session.claude.input == 1410
      assert s.session.claude.output == 143
      assert s.session.claude.cache_read == 28
      assert s.session.claude.cache_write == 7
      assert s.session.claude.by_kind == %{answer: 1, agent: 1, subagent: 1}

      assert s.session.jev == %{
               calls: 2,
               errors: 1,
               input: 300,
               output: 12,
               cache_read: 0,
               cache_write: 0,
               by_kind: %{decision: 2}
             }

      assert s.session.ollama.input == 900
      assert s.today == s.session
      assert s.week == s.session

      # Today's hours: everything in the current local hour.
      {_, {hour, _, _}} = :calendar.local_time()
      assert Enum.at(s.hours.claude, hour) == 1410 + 143 + 28 + 7
      assert Enum.sum(s.hours.jev) == 312

      # What's on disk: one line each, never any text.
      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 6

      assert %{
               "backend" => "claude",
               "kind" => "answer",
               "session" => "this-session",
               "input" => 400
             } =
               JSON.decode!(hd(lines))
    end

    test "other sessions count for today and the week, not this session; old ones only for the week",
         %{tmp_dir: dir} do
      path = Path.join(dir, "usage.jsonl")
      now = DateTime.utc_now()

      File.write!(path, [
        line(DateTime.add(now, -3 * 86_400), %{input: 50}),
        line(DateTime.add(now, -10 * 86_400), %{input: 70}),
        line(now, %{backend: "jev", kind: "decision", input: 5})
      ])

      %{pid: pid} = start(dir)
      record(pid, :claude, :answer, %{input: 1})

      s = Usage.summary(pid)
      assert s.session.claude.input == 1
      assert s.session.jev.calls == 0
      assert s.today.jev.input == 5
      assert s.week.claude.input == 51
    end

    test "lines another tiny-axe writes meanwhile are read too; half a line waits", %{
      tmp_dir: dir
    } do
      %{pid: pid, path: path} = start(dir)
      assert Usage.summary(pid).today.claude.calls == 0

      File.write!(path, line(DateTime.utc_now(), %{input: 9}), [:append])

      File.write!(path, ~s({"at":"#{DateTime.to_iso8601(DateTime.utc_now())}","backend":"jev"), [
        :append
      ])

      s = Usage.summary(pid)
      assert s.today.claude.input == 9
      assert s.today.jev.calls == 0

      File.write!(path, ~s(,"kind":"decision","input":3}\n), [:append])
      assert Usage.summary(pid).today.jev.input == 3
    end

    test "at start, lines older than 90 days are dropped from the file", %{tmp_dir: dir} do
      path = Path.join(dir, "usage.jsonl")
      now = DateTime.utc_now()

      File.write!(path, [
        line(DateTime.add(now, -91 * 86_400), %{}),
        line(DateTime.add(now, -89 * 86_400), %{}),
        "not json\n"
      ])

      start(dir)
      assert path |> File.read!() |> String.split("\n", trim: true) |> length() == 1
    end

    test "nothing yet: zeros, and Claude's windows when known", %{tmp_dir: dir} do
      %{pid: pid} = start(dir)
      s = Usage.summary(pid)
      assert s.week.claude.calls == 0 and s.week.ollama.calls == 0
      assert length(s.hours.jev) == 24
    end
  end

  describe "each place that reports a call" do
    # The app's own copy writes to the shared test state folder; each test
    # finds its call there by a model name of its own.
    defp lines_for(model) do
      Usage.summary()

      Usage.file()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.filter(&(&1["model"] == model))
    end

    defp eventually(fun, tries \\ 50) do
      case fun.() do
        [] when tries > 0 ->
          Process.sleep(20)
          eventually(fun, tries - 1)

        found ->
          found
      end
    end

    test "a Claude answer: its tokens, as the CLI reports them" do
      # The fake CLI reports the model it was given as claude-<model>-test.
      asked = "usage-#{System.unique_integer([:positive])}"
      {:ok, _} = TinyAxe.Model.ClaudeCLI.chat([%{role: "user", content: "hello"}], model: asked)

      found = eventually(fn -> lines_for("claude-#{asked}-test") end)

      assert [
               %{
                 "backend" => "claude",
                 "kind" => "answer",
                 "input" => 400,
                 "cache_read" => 28,
                 "output" => 42,
                 "ok" => true
               }
               | _
             ] = found
    end

    test "Jev: each decision's tokens" do
      previous = {Application.get_env(:tiny_axe, :jev), Application.get_env(:tiny_axe, :decider)}

      on_exit(fn ->
        {jev, decider} = previous
        Application.put_env(:tiny_axe, :jev, jev)
        Application.put_env(:tiny_axe, :decider, decider)
      end)

      Application.put_env(:tiny_axe, :jev,
        api_key: "k",
        model: "jev-latest",
        req_options: [plug: {Req.Test, __MODULE__}, retry: false]
      )

      Application.put_env(:tiny_axe, :decider, TinyAxe.Decider.Jev)
      model = "jev-usage-#{System.unique_integer([:positive])}"

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          model: model,
          answers: %{"ok" => %{"noul" => 0.9}},
          usage: %{input_tokens: 321, output_tokens: 7}
        })
      end)

      {:ok, _} = TinyAxe.Decider.decide("state", %{ok: %{type: :noul, instructions: "ok?"}})

      assert [%{"backend" => "jev", "kind" => "decision", "input" => 321, "output" => 7}] =
               eventually(fn -> lines_for(model) end)
    end

    test "Ollama: a chat's and a stream's tokens, and a failure's" do
      previous = Application.get_env(:tiny_axe, :ollama_req_options)
      on_exit(fn -> Application.put_env(:tiny_axe, :ollama_req_options, previous || []) end)
      Application.put_env(:tiny_axe, :ollama_req_options, plug: {Req.Test, __MODULE__})
      model = "gemma-usage-#{System.unique_integer([:positive])}"

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        if JSON.decode!(raw)["stream"] do
          Plug.Conn.send_resp(conn, 200, [
            JSON.encode!(%{model: model, message: %{content: "hi"}, done: false}) <> "\n",
            JSON.encode!(%{model: model, done: true, prompt_eval_count: 50, eval_count: 5}) <>
              "\n"
          ])
        else
          Req.Test.json(conn, %{
            model: model,
            message: %{content: "hi"},
            prompt_eval_count: 60,
            eval_count: 6
          })
        end
      end)

      msgs = [%{role: "user", content: "hi"}]
      {:ok, _} = TinyAxe.Ollama.chat(msgs, model: model)
      {:ok, "hi"} = TinyAxe.Ollama.stream_chat(msgs, fn _ -> :ok end, model: model)

      found =
        eventually(fn -> lines_for(model) |> then(&if(length(&1) < 2, do: [], else: &1)) end)

      assert Enum.map(found, &{&1["backend"], &1["kind"], &1["input"], &1["output"]}) ==
               [{"ollama", "local", 60, 6}, {"ollama", "local", 50, 5}]

      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 500, "down"))
      {:error, _} = TinyAxe.Ollama.chat(msgs, model: model)
      assert eventually(fn -> lines_for(model) |> Enum.filter(&(&1["ok"] == false)) end) != []
    end
  end
end
