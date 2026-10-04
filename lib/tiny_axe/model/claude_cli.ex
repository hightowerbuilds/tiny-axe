defmodule TinyAxe.Model.ClaudeCLI do
  @moduledoc """
  Claude as a plain model, through Claude Code's headless mode (`claude -p`)
  on the user's subscription. Never an API key: the key variables are
  removed (`TinyAxe.Model.CLI`), and a call that reports any key source other
  than the subscription login is stopped before it answers.

  Claude Code runs with no tools, no MCP servers, no customizations
  (`--safe-mode`; `--bare` would skip the subscription login) and our own
  system prompt, so it's a model, not an agent: tiny-axe keeps the tools.

  `opts`: `:model` (an alias such as `haiku` or `sonnet`, or a full name),
  `:format` (a JSON Schema: the answer is that JSON, as text), `:on_usage`
  (also gets `:quota`, the subscription's usage windows). Temperature isn't
  available here and is ignored. See docs/plan-browser-and-cli-models.md for
  the event format this reads.
  """

  @behaviour TinyAxe.Model

  alias TinyAxe.Model.CLI

  @default_model "haiku"
  # With no system prompt, Claude Code would use its own agent prompt.
  @plain "You are a helpful assistant."
  # Longer system prompts go in the prompt file, away from the argument limit.
  @max_arg 100_000

  @impl true
  def chat(messages, opts \\ []) do
    with {:ok, text} <- call(messages, fn _ -> :ok end, opts),
         do: {:ok, %{"message" => %{"content" => text}}}
  end

  @impl true
  def stream_chat(messages, on_delta, opts \\ []), do: call(messages, on_delta, opts)

  defp call(messages, on_delta, opts) do
    {system, prompt} = CLI.transcript(messages)
    {system, prompt} = fit_system(system || @plain, prompt)
    schema = Keyword.get(opts, :format)
    t0 = System.monotonic_time(:millisecond)

    handle = fn event, acc -> handle(event, acc, on_delta) end
    acc = %{text: [], model: nil, result: nil, quota: nil, error: nil}

    case CLI.run(
           exe(),
           args(opts, system, schema),
           prompt,
           handle,
           acc,
           Keyword.take(opts, [:timeout])
         ) do
      {:stopped, %{error: error}} ->
        {:error, error}

      {:exited, status, acc, noise} ->
        # The subscription's usage windows, for TinyAxe.Escalation's 90% stop.
        if acc.quota,
          do:
            :telemetry.execute([:tiny_axe, :model, :quota], %{}, %{
              backend: :claude,
              quota: acc.quota
            })

        with {:ok, text} <- outcome(acc, status, noise, schema) do
          # Structured answers arrive whole (as a tool call), not as text deltas.
          if schema, do: on_delta.(text)
          report_usage(acc, messages, opts, System.monotonic_time(:millisecond) - t0)
          {:ok, text}
        end

      {:error, :not_installed} ->
        {:error, {:not_installed, :claude}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp args(opts, system, schema) do
    effort = Application.get_env(:tiny_axe, :claude_effort, "low")

    ["-p", "--model", Keyword.get(opts, :model) || @default_model] ++
      ~w(--safe-mode --tools) ++
      [""] ++
      ~w(--strict-mcp-config --no-session-persistence --effort) ++
      [effort, "--system-prompt", system] ++
      ~w(--output-format stream-json --include-partial-messages --verbose) ++
      if(schema, do: ["--json-schema", JSON.encode!(schema)], else: [])
  end

  defp fit_system(system, prompt) when byte_size(system) <= @max_arg, do: {system, prompt}

  defp fit_system(system, prompt),
    do: {@plain, "Instructions for this conversation:\n\n#{system}\n\n---\n\n#{prompt}"}

  @doc false
  # One JSON event from `claude -p --output-format stream-json`.
  def handle(%{"type" => "system", "subtype" => "init"} = e, acc, _on_delta) do
    case e["apiKeySource"] do
      source when source in [nil, "none"] -> {:cont, %{acc | model: e["model"]}}
      source -> {:stop, %{acc | error: {:not_subscription, :claude, source}}}
    end
  end

  def handle(
        %{"type" => "stream_event", "event" => %{"delta" => %{"type" => "text_delta"} = d}},
        acc,
        on_delta
      ) do
    on_delta.(d["text"])
    {:cont, %{acc | text: [acc.text | d["text"]]}}
  end

  def handle(%{"type" => "rate_limit_event", "rate_limit_info" => info}, acc, _on_delta) do
    windows = info["unifiedWindows"] || %{}

    quota = %{
      status: info["status"],
      five_hour: get_in(windows, ["five_hour", "utilization"]),
      seven_day: get_in(windows, ["seven_day", "utilization"]),
      resets_at: info["resetsAt"]
    }

    {:cont, %{acc | quota: quota}}
  end

  def handle(%{"type" => "result"} = e, acc, _on_delta), do: {:cont, %{acc | result: e}}
  def handle(_event, acc, _on_delta), do: {:cont, acc}

  @doc false
  def outcome(%{result: nil}, status, noise, _schema),
    do: {:error, {:claude_exit, status, noise |> Enum.take(-5) |> Enum.join("\n")}}

  def outcome(%{result: %{"is_error" => true} = r} = acc, _status, _noise, _schema) do
    message = to_string(r["result"] || r["subtype"])

    cond do
      message =~ "Not logged in" ->
        {:error, {:not_logged_in, :claude}}

      acc.quota && acc.quota.status not in [nil, "allowed"] ->
        {:error, {:usage_limit, :claude, acc.quota}}

      true ->
        {:error, {:claude, message}}
    end
  end

  def outcome(%{result: r}, _status, _noise, schema) when schema != nil do
    case r["structured_output"] do
      nil -> {:error, {:claude, :no_structured_output}}
      output -> {:ok, JSON.encode!(output)}
    end
  end

  def outcome(%{result: r} = acc, _status, _noise, nil),
    do: {:ok, r["result"] || IO.iodata_to_binary(acc.text)}

  defp report_usage(acc, messages, opts, ms) do
    with fun when is_function(fun, 1) <- Keyword.get(opts, :on_usage) do
      usage = (acc.result && acc.result["usage"]) || %{}

      fun.(%{
        backend: :claude,
        model: acc.model,
        prompt_tokens:
          (usage["input_tokens"] || 0) + (usage["cache_read_input_tokens"] || 0) +
            (usage["cache_creation_input_tokens"] || 0),
        output_tokens: usage["output_tokens"] || 0,
        prompt_chars: messages |> Enum.map(&String.length(&1.content)) |> Enum.sum(),
        load_ms: 0,
        prompt_ms: 0,
        generate_ms: (acc.result && acc.result["duration_api_ms"]) || ms,
        quota: acc.quota
      })
    end
  end

  defp exe, do: Application.get_env(:tiny_axe, :claude_cli, "claude")
end
