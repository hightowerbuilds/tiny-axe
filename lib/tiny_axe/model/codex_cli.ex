defmodule TinyAxe.Model.CodexCLI do
  @moduledoc """
  OpenAI's models (e.g. `gpt-6-luna`) as a plain model, through `codex exec`
  on the user's ChatGPT subscription. Never an API key: the key variables are
  removed (`TinyAxe.Model.CLI`), and Codex must report "Logged in using
  ChatGPT" (checked once per run of tiny-axe) before it's used.

  Codex is an agent, so everything that lets it act is switched off: its
  shell, browser, computer use, apps, plugins and image tools. It runs
  read-only in an empty folder. Its own agent prompt can't be removed, so
  every call carries about 11.5k tokens of it.

  `codex exec --json` reports whole messages, not tokens, so `stream_chat/3`
  delivers the answer in one piece. `opts`: `:model`, `:format` (a JSON
  Schema, made strict), `:on_usage`. Temperature isn't available here.
  """

  @behaviour TinyAxe.Model

  alias TinyAxe.Model.CLI

  @default_model "gpt-6-luna"

  # Everything that would let Codex act on its own, around tiny-axe's gates.
  @disabled ~w(shell_tool browser_use browser_use_external computer_use apps plugins
               image_generation view_image skill_search)

  @impl true
  def chat(messages, opts \\ []) do
    with {:ok, text} <- call(messages, fn _ -> :ok end, opts),
         do: {:ok, %{"message" => %{"content" => text}}}
  end

  @impl true
  def stream_chat(messages, on_delta, opts \\ []) do
    with {:ok, text} <- call(messages, on_delta, opts) do
      on_delta.(text)
      {:ok, text}
    end
  end

  defp call(messages, _on_delta, opts) do
    with :ok <- ensure_subscription() do
      {system, prompt} = CLI.transcript(messages)

      prompt =
        if system,
          do: "Instructions for this conversation:\n\n#{system}\n\n---\n\n#{prompt}",
          else: prompt

      schema_file = write_schema(Keyword.get(opts, :format))
      t0 = System.monotonic_time(:millisecond)
      acc = %{text: nil, usage: nil, error: nil}

      try do
        case CLI.run(
               exe(),
               args(opts, schema_file),
               prompt,
               &handle/2,
               acc,
               Keyword.take(opts, [:timeout])
             ) do
          {:exited, status, acc, noise} ->
            with {:ok, text} <- outcome(acc, status, noise) do
              report_usage(acc, messages, opts, System.monotonic_time(:millisecond) - t0)
              {:ok, text}
            end

          {:error, :not_installed} ->
            {:error, {:not_installed, :codex}}

          {:error, reason} ->
            {:error, reason}
        end
      after
        if schema_file, do: File.rm(schema_file)
      end
    end
  end

  defp args(opts, schema_file) do
    effort = Application.get_env(:tiny_axe, :codex_effort, "low")

    ["exec", "-m", Keyword.get(opts, :model) || @default_model] ++
      ["-c", ~s(model_reasoning_effort="#{effort}")] ++
      off_flags() ++
      ~w(--ephemeral --skip-git-repo-check -s read-only --ignore-rules --json) ++
      if(schema_file, do: ["--output-schema", schema_file], else: []) ++ ["-"]
  end

  @doc "The flags that switch off everything that would let Codex act on its own."
  @spec off_flags() :: [String.t()]
  def off_flags, do: Enum.flat_map(@disabled, &["--disable", &1])

  defp write_schema(nil), do: nil

  defp write_schema(schema) do
    path =
      Path.join(System.tmp_dir!(), "tiny_axe_schema_#{System.unique_integer([:positive])}.json")

    File.write!(path, JSON.encode!(CLI.strict_schema(schema)))
    path
  end

  @doc false
  # One JSON event from `codex exec --json`; the last agent message is the answer.
  def handle(%{"type" => "item.completed", "item" => %{"type" => "agent_message"} = i}, acc),
    do: {:cont, %{acc | text: i["text"]}}

  def handle(%{"type" => "turn.completed", "usage" => usage}, acc),
    do: {:cont, %{acc | usage: usage}}

  def handle(%{"type" => "error", "message" => message}, acc),
    do: {:cont, %{acc | error: message}}

  def handle(%{"type" => "turn.failed", "error" => %{"message" => message}}, acc),
    do: {:cont, %{acc | error: message}}

  def handle(_event, acc), do: {:cont, acc}

  @doc false
  def outcome(%{error: error}, _status, _noise) when is_binary(error) do
    if error =~ ~r/usage limit|rate limit/i,
      do: {:error, {:usage_limit, :codex, error}},
      else: {:error, {:codex, error}}
  end

  def outcome(%{text: text}, 0, _noise) when is_binary(text), do: {:ok, text}

  def outcome(_acc, status, noise),
    do: {:error, {:codex_exit, status, noise |> Enum.take(-5) |> Enum.join("\n")}}

  defp report_usage(acc, messages, opts, ms) do
    with fun when is_function(fun, 1) <- Keyword.get(opts, :on_usage) do
      usage = acc.usage || %{}

      fun.(%{
        backend: :codex,
        prompt_tokens: usage["input_tokens"] || 0,
        output_tokens: usage["output_tokens"] || 0,
        prompt_chars: messages |> Enum.map(&String.length(&1.content)) |> Enum.sum(),
        load_ms: 0,
        prompt_ms: 0,
        generate_ms: ms
      })
    end
  end

  @doc """
  `:ok` once Codex reports a ChatGPT login (checked once per run of tiny-axe;
  only a ChatGPT login is remembered), or why it can't be used.
  """
  @spec ensure_subscription() :: :ok | {:error, term()}
  def ensure_subscription do
    key = {__MODULE__, :subscription, exe()}

    if :persistent_term.get(key, false) do
      :ok
    else
      with path when path != nil <- System.find_executable(exe()),
           {out, 0} <- System.cmd(path, ["login", "status"], stderr_to_stdout: true),
           true <- subscription_login?(out) do
        :persistent_term.put(key, true)
        :ok
      else
        nil -> {:error, {:not_installed, :codex}}
        {_out, _status} -> {:error, {:not_logged_in, :codex}}
        false -> {:error, {:not_subscription, :codex, "not a ChatGPT login"}}
      end
    end
  end

  @doc false
  def subscription_login?(status_output), do: status_output =~ ~r/Logged in using ChatGPT/i

  defp exe, do: Application.get_env(:tiny_axe, :codex_cli, "codex")
end
