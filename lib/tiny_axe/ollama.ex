defmodule TinyAxe.Ollama do
  @moduledoc """
  Minimal client for Ollama's `/api/chat` endpoint.

  `chat/2` returns the full response body. `stream_chat/3` streams content
  deltas to a callback as they arrive and returns the assembled text.
  """

  @behaviour TinyAxe.Model

  @type message :: %{role: String.t(), content: String.t()}

  @doc "Non-streaming chat call. Returns the decoded response body."
  @impl true
  @spec chat([message()], keyword()) :: {:ok, map()} | {:error, term()}
  def chat(messages, opts \\ []) do
    body = build_body(messages, false, opts)

    case Req.post(req(), url: "/api/chat", json: body) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Streaming chat call. `on_delta` is invoked with each content fragment.
  Returns `{:ok, full_text}` once the model finishes.

  With `on_usage: fun`, `fun` gets `%{prompt_tokens:, output_tokens:, prompt_chars:}`
  when the model finishes. Ollama counts the whole prompt, cached or not.
  """
  @impl true
  @spec stream_chat([message()], (String.t() -> any()), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def stream_chat(messages, on_delta, opts \\ []) do
    body = build_body(messages, true, opts)

    into = fn {:data, data}, {req, resp} ->
      buffer = Req.Response.get_private(resp, :ndjson_buffer, "") <> data
      {lines, rest} = split_complete_lines(buffer)

      acc =
        Enum.reduce(lines, Req.Response.get_private(resp, :text, []), fn line, acc ->
          case JSON.decode(line) do
            {:ok, %{"error" => error}} ->
              throw({:ollama_error, error})

            # The last chunk carries token counts, for the context meter.
            {:ok, %{"done" => true} = final} ->
              report_usage(final, messages, opts)
              acc

            {:ok, %{"message" => %{"content" => delta}}} when delta != "" ->
              on_delta.(delta)
              [acc | delta]

            _ ->
              acc
          end
        end)

      resp =
        resp
        |> Req.Response.put_private(:ndjson_buffer, rest)
        |> Req.Response.put_private(:text, acc)

      {:cont, {req, resp}}
    end

    try do
      case Req.post(req(), url: "/api/chat", json: body, into: into) do
        {:ok, %Req.Response{status: 200} = resp} ->
          {:ok, resp |> Req.Response.get_private(:text, []) |> IO.iodata_to_binary()}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:http, status}}

        {:error, reason} ->
          {:error, reason}
      end
    catch
      {:ollama_error, error} -> {:error, {:ollama, error}}
    end
  end

  defp report_usage(final, messages, opts) do
    with fun when is_function(fun, 1) <- Keyword.get(opts, :on_usage),
         tokens when is_integer(tokens) <- final["prompt_eval_count"] do
      chars = messages |> Enum.map(&String.length(&1.content)) |> Enum.sum()
      # Ollama reports its own timings in nanoseconds: loading the model,
      # reading the prompt, and generating.
      ms = fn key -> div(final[key] || 0, 1_000_000) end

      fun.(%{
        prompt_tokens: tokens,
        output_tokens: final["eval_count"] || 0,
        prompt_chars: chars,
        load_ms: ms.("load_duration"),
        prompt_ms: ms.("prompt_eval_duration"),
        generate_ms: ms.("eval_duration")
      })
    end
  end

  defp build_body(messages, stream?, opts) do
    %{
      model: Keyword.get(opts, :model, config(:model)),
      messages: messages,
      stream: stream?,
      think: Keyword.get(opts, :think, config(:think, false)),
      # Same num_ctx on every call, or Ollama reloads the model between requests.
      options:
        Map.merge(%{num_ctx: config(:num_ctx, 8192)}, Map.new(Keyword.get(opts, :options, [])))
    }
    |> maybe_put(:format, Keyword.get(opts, :format))
    |> maybe_put(:logprobs, Keyword.get(opts, :logprobs))
    |> maybe_put(:top_logprobs, Keyword.get(opts, :top_logprobs))
    |> maybe_put(:keep_alive, config(:keep_alive))
  end

  defp split_complete_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {Enum.reject(complete, &(&1 == "")), rest}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp req do
    Req.new(base_url: config(:ollama_url), receive_timeout: :timer.minutes(5), retry: false)
  end

  defp config(key, default \\ nil), do: Application.get_env(:tiny_axe, key, default)
end
