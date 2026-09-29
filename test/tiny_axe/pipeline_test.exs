defmodule TinyAxe.PipelineTest do
  @moduledoc """
  The core request flow, with a scripted model and decider: each test says
  what the model writes and how each decision comes out, then checks what
  tiny-axe does with it.
  """

  # Swaps the app-wide model, decider and folders, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Decider, Model, Pipeline}

  @moduletag :tmp_dir

  @keys ~w(model_backend decider script_model script_decider fs_root project_dir code_check web_search)a

  setup %{tmp_dir: dir} do
    previous = Map.new(@keys, &{&1, Application.get_env(:tiny_axe, &1)})

    on_exit(fn ->
      for {k, v} <- previous,
          do:
            if(v == nil,
              do: Application.delete_env(:tiny_axe, k),
              else: Application.put_env(:tiny_axe, k, v)
            )

      TinyAxe.Location.reset()
    end)

    Application.put_env(:tiny_axe, :fs_root, dir)
    Application.put_env(:tiny_axe, :project_dir, dir)
    Application.put_env(:tiny_axe, :code_check, false)
    Application.put_env(:tiny_axe, :web_search, false)
    TinyAxe.Location.reset()
    %{dir: dir}
  end

  # Runs a request, returning every event in order.
  defp run(prompt, history \\ []) do
    me = self()
    Pipeline.run(history, prompt, &send(me, {:event, &1}))
    collect([])
  end

  defp collect(acc) do
    receive do
      {:event, e} -> collect([e | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp done(events),
    do:
      Enum.find_value(events, fn
        {:done, t} -> t
        _ -> nil
      end)

  defp tags(events), do: Enum.map(events, &elem(&1, 0))

  # The model's answer, from its last user message.
  defp last_user(messages),
    do: messages |> Enum.filter(&(&1.role == "user")) |> List.last() |> Map.get(:content)

  # Routing as a question with nothing else switched on, unless overridden.
  defp route(overrides) do
    fn
      :kind, _q, _s -> Map.get(overrides, :kind, :question)
      key, _q, _s -> Map.get(overrides, key)
    end
  end

  describe "answering" do
    test "a verified answer is delivered on the first attempt" do
      Model.Script.script(fn _messages, _opts -> "Paris." end)
      routing = route(%{})

      Decider.Script.script(fn
        :addresses, _, _ -> 0.95
        key, q, s -> routing.(key, q, s)
      end)

      events = run("What is the capital of France?")
      assert done(events) == "Paris."
      assert Enum.count(events, &match?({:attempt, _}, &1)) == 1
    end

    test "an answer claiming to have run something is sent back and rewritten" do
      Model.Script.script(fn messages, _opts ->
        if last_user(messages) =~ "You can't run commands",
          do: "Run this yourself:\n\n```bash\nnpm install\n```",
          else: "I ran `npm install` for you."
      end)

      routing = route(%{})

      Decider.Script.script(fn
        :addresses, _, _ -> 0.9
        :false_claim, _, %{response: r} -> if r =~ "I ran", do: 0.95, else: 0.02
        key, q, s -> routing.(key, q, s)
      end)

      events = run("Install the dependencies")
      assert done(events) =~ "Run this yourself"
      assert Enum.count(events, &match?({:attempt, _}, &1)) == 2
    end

    test "a missing verdict gives an unverified answer, not a retry" do
      Model.Script.script(fn _, _ -> "An answer." end)
      routing = route(%{})

      Decider.Script.script(fn
        :addresses, _, _ -> :unknown
        key, q, s -> routing.(key, q, s)
      end)

      events = run("Explain supervisors")
      assert done(events) == "An answer."
      assert {:decider_unavailable, "verifying the answer"} in events
      assert Enum.count(events, &match?({:attempt, _}, &1)) == 1
    end

    test "when every attempt falls short, the highest-rated one is returned" do
      counter = :counters.new(1, [])

      Model.Script.script(fn _, _ ->
        :counters.add(counter, 1, 1)
        "attempt #{:counters.get(counter, 1)}"
      end)

      routing = route(%{})
      scores = %{"attempt 1" => 0.3, "attempt 2" => 0.6, "attempt 3" => 0.4}

      Decider.Script.script(fn
        :addresses, _, %{response: r} -> scores[r]
        key, q, s -> routing.(key, q, s)
      end)

      events = run("Something hard")
      assert done(events) == "attempt 2"
      assert {:chose, %{attempt: 2, score: 0.6, attempts: 3}} in events
    end
  end

  describe "routing" do
    test "unknown routing scores switch nothing on (nil >= 0.5 is true in Elixir)" do
      Model.Script.script(fn _, _ -> "A plain answer." end)

      Decider.Script.script(fn
        :kind, _, _ -> :unknown
        :addresses, _, _ -> 0.9
        _key, %{type: :noul}, _ -> :unknown
        _, _, _ -> nil
      end)

      events = run("Go into my repo, search the web, and move my files")
      assert done(events) == "A plain answer."

      for tag <- [:moved, :search, :files, :plan, :command_plan],
          do: refute(tag in tags(events), "#{tag} ran on an unknown score")
    end

    test "a file task reaches the organizer and comes back as a plan to approve", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "Downloads"))
      File.write!(Path.join(dir, "Downloads/a.pdf"), "a")

      Model.Script.script(fn _, _ ->
        JSON.encode!(%{
          look: [],
          mkdir: [],
          copy: [],
          trash: [],
          move: [%{from: "~/Downloads/a.pdf", to: "~/Papers/"}],
          write: [],
          reply: "This will move a.pdf into Papers."
        })
      end)

      Decider.Script.script(fn
        :organize, _, _ -> 0.95
        key, _q, _s when key in [:complete] -> 0.9
        key, _q, _s -> if String.starts_with?(to_string(key), "step_"), do: 0.9, else: nil
      end)

      events = run("Move the PDF in Downloads into Papers")

      assert {:plan, %{ops: [%{op: :move, to: to}], review: review}} =
               List.keyfind(events, :plan, 0)

      assert to == Path.join(dir, "Papers/a.pdf")
      assert review == 0.9
      # Planning never touches the disk.
      assert File.exists?(Path.join(dir, "Downloads/a.pdf"))
    end

    test "a command request reaches the commander, run in the current folder", %{dir: dir} do
      # A project inside the home folder: commands never run in home itself.
      app = Path.join(dir, "app")
      File.mkdir_p!(app)
      {:ok, _} = TinyAxe.Location.cd(app)

      Model.Script.script(fn _, _ ->
        JSON.encode!(%{commands: ["npm install"], reply: "This will install the dependencies."})
      end)

      Decider.Script.script(fn
        :command, _, _ ->
          0.95

        key, _q, _s ->
          if key in [:complete, :right_folder] or String.starts_with?(to_string(key), "cmd_"),
            do: 0.9,
            else: nil
      end)

      events = run("Run npm install")

      assert {:command_plan, %{dir: ^app, commands: [%{command: "npm install"}]}} =
               List.keyfind(events, :command_plan, 0)
    end
  end

  describe "conversation context (harness F4)" do
    @history [
      %{role: "user", content: "How do I install the dependencies for my Vite app?"},
      %{role: "assistant", content: "Run `npm install` in the project folder."}
    ]

    test "routing and the verifier see the recent conversation, so \"now run it\" makes sense" do
      me = self()
      Model.Script.script(fn _, _ -> "Here it is." end)

      Decider.Script.script(fn
        :kind, _, state ->
          send(me, {:route_state, state})
          :question

        :addresses, _, state ->
          send(me, {:verify_state, state})
          0.9

        _, _, _ ->
          nil
      end)

      run("now run it", @history)
      assert_received {:route_state, %{request: "now run it", recent_conversation: conv}}
      assert conv =~ "npm install"
      assert_received {:verify_state, %{recent_conversation: ^conv}}
    end

    test "a plan's review sees the conversation too", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "Downloads"))
      File.write!(Path.join(dir, "Downloads/a.pdf"), "a")
      me = self()

      Model.Script.script(fn _, _ ->
        JSON.encode!(%{
          look: [],
          mkdir: [],
          copy: [],
          trash: [],
          write: [],
          reply: "Moving it.",
          move: [%{from: "~/Downloads/a.pdf", to: "~/Papers/"}]
        })
      end)

      Decider.Script.script(fn
        :organize, _, _ ->
          0.95

        :complete, _, state ->
          send(me, {:review_state, state})
          0.9

        key, _, _ ->
          if String.starts_with?(to_string(key), "step_"), do: 0.9, else: nil
      end)

      run("put those in Papers", [
        %{role: "user", content: "which PDFs are in Downloads?"},
        %{role: "assistant", content: "a.pdf"}
      ])

      assert_received {:review_state,
                       %{request: "put those in Papers", recent_conversation: conv}}

      assert conv =~ "which PDFs are in Downloads?"
    end
  end

  describe "editing project files" do
    setup %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "lib/demo.ex"), "defmodule Demo do\n  def hi, do: :hi\nend\n")
      :ok
    end

    defp edit_routing do
      fn
        :kind, _, _ -> :code
        :files, _, _ -> 0.9
        :change, _, _ -> 0.9
        :file, _, _ -> "lib/demo.ex"
        :addresses, _, _ -> 0.9
        _, _, _ -> nil
      end
    end

    @new "```elixir lib/demo.ex\ndefmodule Demo do\n  def hi, do: :hello\nend\n```"

    test "many @mentions stay within the file budget, and the files left out are named", %{
      dir: dir
    } do
      for i <- 1..20, do: File.write!(Path.join(dir, "f#{i}.txt"), String.duplicate("z", 3_000))
      me = self()

      Model.Script.script(fn messages, _ ->
        send(me, {:files_prompt, Enum.find(messages, &(&1.content =~ "Files you were given"))})
        "Read them."
      end)

      Decider.Script.script(fn
        :addresses, _, _ -> 0.9
        _, _, _ -> nil
      end)

      mentions = Enum.map_join(1..20, " ", &"@f#{&1}.txt")
      run("Summarise #{mentions}")

      assert_received {:files_prompt, %{content: content}}
      assert content =~ "Not included, to stay within the budget for files"
      shown = Regex.scan(~r/===== f\d+\.txt =====/, content) |> length()
      assert shown < 20
      # Each shown file is within its share, so the total stays near the budget.
      assert String.length(content) < 12_000 + 3_000
    end

    test "an edit of the file as the model saw it is proposed" do
      Model.Script.script(fn _, _ -> @new end)
      Decider.Script.script(edit_routing())

      events = run("Make hi return :hello")
      assert {:edits, [%{path: "lib/demo.ex"}]} = List.keyfind(events, :edits, 0)
    end

    test "a file saved while the model was writing makes its edit refused (harness F7)", %{
      dir: dir
    } do
      Model.Script.script(fn _, _ ->
        # The user saves the file in their editor mid-answer.
        File.write!(
          Path.join(dir, "lib/demo.ex"),
          "defmodule Demo do\n  def hi, do: :theirs\nend\n"
        )

        @new
      end)

      Decider.Script.script(edit_routing())

      events = run("Make hi return :hello")
      refute List.keyfind(events, :edits, 0)

      assert {:edit_refused, %{path: "lib/demo.ex", reason: reason}} =
               List.keyfind(events, :edit_refused, 0)

      assert reason =~ "changed while the model was writing"
    end
  end
end
