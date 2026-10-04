defmodule TinyAxe.ModelCLITest do
  # The fake CLIs in test/support/fake_cli stand in for `claude` and `codex`
  # (config/test.exs), so nothing here uses a real subscription.
  use ExUnit.Case, async: true

  alias TinyAxe.{Context, Model}
  alias TinyAxe.Model.{ClaudeCLI, CLI, CodexCLI}

  @conversation [
    %{role: "system", content: "You are tiny-axe."},
    %{role: "user", content: "What is OTP?"},
    %{role: "assistant", content: "The Open Telecom Platform."},
    %{role: "system", content: "Web search results: [1] erlang.org"},
    %{role: "user", content: "And what's a GenServer?"}
  ]

  # The fakes answer with what they were given, as JSON.
  defp echoed(text), do: JSON.decode!(text)

  defp after_flag(args, flag), do: args |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)

  describe "transcript/1" do
    test "the first system message is the system prompt; the rest is labelled, oldest first" do
      {system, prompt} = CLI.transcript(@conversation)

      assert system == "You are tiny-axe."
      assert prompt =~ ~r/\[user\]\nWhat is OTP\?.*\[assistant\]\nThe Open Telecom Platform\./s
      assert prompt =~ "[material]\nWeb search results"
      assert prompt =~ ~r/The user's new message:\n\nAnd what's a GenServer\?\z/
    end

    test "a lone request is sent as it is" do
      assert CLI.transcript([%{role: "user", content: "hi"}]) == {nil, "hi"}
    end
  end

  test "strict_schema/1 closes every object, whichever way its keys are written" do
    schema = %{
      type: "object",
      properties: %{steps: %{type: "array", items: %{type: "object", properties: %{}}}}
    }

    strict = CLI.strict_schema(schema)
    assert strict.additionalProperties == false
    assert strict.properties.steps.items.additionalProperties == false
    assert CLI.strict_schema(%{"type" => "object"})["additionalProperties"] == false
  end

  describe "Claude" do
    test "runs as a plain model on the subscription, and streams the answer" do
      me = self()

      {:ok, text} =
        Model.stream_chat(@conversation, &send(me, {:delta, &1}),
          use: {:claude, "sonnet"},
          on_usage: &send(me, {:usage, &1})
        )

      # Thinking is left out; the text deltas add up to the answer.
      deltas = collect_deltas()
      assert length(deltas) == 2
      assert Enum.join(deltas) == text

      reply = echoed(text)
      args = reply["args"]
      assert "-p" in args
      assert after_flag(args, "--model") == "sonnet"
      assert after_flag(args, "--tools") == ""
      assert "--safe-mode" in args and "--strict-mcp-config" in args
      assert "--no-session-persistence" in args
      assert after_flag(args, "--system-prompt") == "You are tiny-axe."
      assert after_flag(args, "--output-format") == "stream-json"

      # The prompt went in on stdin; it ran in an empty folder of its own.
      assert reply["stdin"] =~ "And what's a GenServer?"
      assert reply["files"] == []
      refute reply["cwd"] == File.cwd!()

      assert_received {:usage, usage}
      assert usage.backend == :claude
      assert usage.prompt_tokens == 428
      assert usage.quota.five_hour == 0.09
    end

    test "without a system prompt, gets a plain one rather than Claude Code's agent prompt" do
      {:ok, %{"message" => %{"content" => text}}} =
        Model.chat([%{role: "user", content: "hi"}], use: {:claude, "haiku"})

      assert after_flag(echoed(text)["args"], "--system-prompt") == "You are a helpful assistant."
    end

    test "a JSON Schema comes back as that JSON" do
      schema = %{type: "object", properties: %{reply: %{type: "string"}}, required: ["reply"]}

      {:ok, %{"message" => %{"content" => json}}} =
        Model.chat([%{role: "user", content: "plan it"}], use: {:claude, "haiku"}, format: schema)

      %{"reply" => reply} = JSON.decode!(json)
      assert after_flag(echoed(reply)["args"], "--json-schema") == JSON.encode!(schema)

      # Streamed, it arrives in one piece.
      me = self()

      {:ok, streamed} =
        Model.stream_chat([%{role: "user", content: "plan it"}], &send(me, {:delta, &1}),
          use: {:claude, "haiku"},
          format: schema
        )

      assert %{"reply" => _} = JSON.decode!(streamed)
      assert collect_deltas() == [streamed]
    end

    test "a key source other than the subscription is stopped, not answered" do
      assert {:error, {:not_subscription, :claude, "ANTHROPIC_API_KEY"}} =
               Model.chat([%{role: "user", content: "SCENARIO:api_key"}], use: {:claude, "haiku"})
    end

    test "not logged in, the usage limit, and a crash are told apart" do
      ask = &Model.chat([%{role: "user", content: &1}], use: {:claude, "haiku"})

      assert ask.("SCENARIO:not_logged_in") == {:error, {:not_logged_in, :claude}}

      assert {:error, {:usage_limit, :claude, %{status: "rejected"}}} =
               ask.("SCENARIO:usage_limit")

      assert {:error, {:claude_exit, 2, noise}} = ask.("SCENARIO:garbage")
      assert noise =~ "something went badly wrong"
    end

    test "is killed on a timeout" do
      file = pid_file()

      assert {:error, :timeout} =
               Model.chat([%{role: "user", content: "SCENARIO:sleep:#{file}"}],
                 use: {:claude, "haiku"},
                 timeout: 3_000
               )

      assert_dead(file)
    end

    test "is killed when the request is cancelled (its task dies)" do
      file = pid_file()

      # Unlinked, like the TUI's request tasks, so killing it doesn't kill the test.
      {:ok, task} =
        Task.start(fn ->
          Model.chat([%{role: "user", content: "SCENARIO:sleep:#{file}"}],
            use: {:claude, "haiku"}
          )
        end)

      wait_for(file)
      Process.exit(task, :kill)
      assert_dead(file)
    end
  end

  describe "Codex" do
    test "runs with everything that lets it act switched off, and answers in one piece" do
      me = self()

      {:ok, text} =
        Model.stream_chat(@conversation, &send(me, {:delta, &1}),
          use: {:codex, "gpt-6-luna"},
          on_usage: &send(me, {:usage, &1})
        )

      assert collect_deltas() == [text]

      reply = echoed(text)
      args = reply["args"]
      assert Enum.take(args, 3) == ["exec", "-m", "gpt-6-luna"]
      assert after_flag(args, "-s") == "read-only"
      assert "--ephemeral" in args and "--json" in args and "--ignore-rules" in args

      disabled = for {"--disable", f} <- Enum.zip(args, tl(args)), do: f

      for feature <- ~w(shell_tool browser_use browser_use_external computer_use apps plugins) do
        assert feature in disabled
      end

      # Codex has no system prompt flag, so the instructions lead the prompt.
      assert reply["stdin"] =~ ~r/\AInstructions for this conversation:\n\nYou are tiny-axe\./
      assert reply["stdin"] =~ "And what's a GenServer?"
      assert reply["files"] == []

      assert_received {:usage, %{backend: :codex, prompt_tokens: 11_472}}
    end

    test "a JSON Schema is sent strict" do
      schema = %{type: "object", properties: %{reply: %{type: "string"}}, required: ["reply"]}

      {:ok, %{"message" => %{"content" => text}}} =
        Model.chat([%{role: "user", content: "plan it"}],
          use: {:codex, "gpt-6-luna"},
          format: schema
        )

      assert JSON.decode!(echoed(text)["schema"])["additionalProperties"] == false
    end

    test "errors and the usage limit are told apart" do
      ask = &Model.chat([%{role: "user", content: &1}], use: {:codex, "gpt-6-luna"})

      assert ask.("SCENARIO:error") == {:error, {:codex, "something broke"}}
      assert {:error, {:usage_limit, :codex, _}} = ask.("SCENARIO:usage_limit")
    end

    test "only a ChatGPT login counts as the subscription" do
      assert CodexCLI.subscription_login?("Logged in using ChatGPT\n")
      refute CodexCLI.subscription_login?("Logged in using an API key - sk-...")
      refute CodexCLI.subscription_login?("Not logged in")
    end
  end

  test "only the local model's token counts calibrate the context meter" do
    usage = %{prompt_tokens: 11_472, prompt_chars: 1_000}
    assert Context.calibrate(0.28, Map.put(usage, :backend, :codex)) == 0.28
    assert Context.calibrate(0.28, Map.put(usage, :backend, :claude)) == 0.28
    refute Context.calibrate(0.28, usage) == 0.28
  end

  test "roles, labels, and which models leave the machine" do
    assert [{:claude, "haiku"} | _] = Model.role(:escalate)
    assert Model.label({:claude, "haiku"}) == "Claude haiku"
    assert Model.label({:codex, "gpt-6-luna"}) == "Codex gpt-6-luna"
    assert Model.remote?({:claude, "haiku"}) and Model.remote?({:codex, "gpt-6-luna"})
    refute Model.remote?({:ollama, "gemma4:e4b-it-qat"}) or Model.remote?(nil)
  end

  test "the backends read the recorded event shapes" do
    assert {:cont, %{model: "m"}} =
             ClaudeCLI.handle(
               %{"type" => "system", "subtype" => "init", "model" => "m"},
               %{model: nil},
               & &1
             )

    assert {:cont, %{text: "done"}} =
             CodexCLI.handle(
               %{
                 "type" => "item.completed",
                 "item" => %{"type" => "agent_message", "text" => "done"}
               },
               %{text: nil}
             )
  end

  ## Helpers

  defp collect_deltas(acc \\ []) do
    receive do
      {:delta, d} -> collect_deltas([d | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp pid_file,
    do: Path.join(System.tmp_dir!(), "tiny_axe_fake_cli_#{System.unique_integer([:positive])}")

  defp wait_for(file, tries \\ 100) do
    cond do
      File.exists?(file) and File.read!(file) != "" -> :ok
      tries == 0 -> flunk("the fake CLI never started")
      true -> Process.sleep(50) && wait_for(file, tries - 1)
    end
  end

  defp assert_dead(file, tries \\ 60) do
    wait_for(file)
    pid = File.read!(file)

    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} when tries > 0 ->
        Process.sleep(50)
        assert_dead(file, tries - 1)

      {_, status} ->
        File.rm(file)
        assert status != 0, "the CLI (OS pid #{pid}) is still running"
    end
  end
end

defmodule TinyAxe.ModelCLIEnvTest do
  # Changes the VM's environment, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.Model

  test "API keys never reach the CLIs, so they can only use the subscription" do
    keys = ~w(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN OPENAI_API_KEY CODEX_API_KEY)
    for k <- keys, do: System.put_env(k, "sk-test")

    try do
      for use <- [{:claude, "haiku"}, {:codex, "gpt-6-luna"}] do
        {:ok, %{"message" => %{"content" => text}}} =
          Model.chat([%{role: "user", content: "hi"}], use: use)

        assert JSON.decode!(text)["api_keys"] == [], "#{inspect(use)} saw an API key"
      end
    after
      for k <- keys, do: System.delete_env(k)
    end
  end
end
