defmodule TinyAxe.Model do
  @moduledoc """
  The generating model, behind a behaviour so it can be swapped, like
  `TinyAxe.Decider`. `TinyAxe.Ollama` is the real one (`config :tiny_axe,
  :model_backend`); tests script answers with `TinyAxe.Model.Script`.

  The local decider talks to Ollama directly: it needs token logprobs, which
  only the real model has; tests use a scripted decider instead.
  """

  require Logger

  @type message :: %{role: String.t(), content: String.t()}

  @doc "One reply, as Ollama's response body (`%{\"message\" => %{\"content\" => text}}`)."
  @callback chat([message()], keyword()) :: {:ok, map()} | {:error, term()}

  @doc "A streamed reply: `on_delta` gets each piece; returns the whole text."
  @callback stream_chat([message()], (String.t() -> any()), keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @spec chat([message()], keyword()) :: {:ok, map()} | {:error, term()}
  def chat(messages, opts \\ []),
    do: timed(:chat, fn -> impl().chat(fit(messages, opts), opts) end)

  @spec stream_chat([message()], (String.t() -> any()), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def stream_chat(messages, on_delta, opts \\ []),
    do: timed(:stream_chat, fn -> impl().stream_chat(fit(messages, opts), on_delta, opts) end)

  # Every model call reports its duration as a telemetry event
  # ([:tiny_axe, :model, :call]), which `mix tiny_axe.eval` counts and times.
  defp timed(kind, fun) do
    t0 = System.monotonic_time()
    result = fun.()
    ms = System.convert_time_unit(System.monotonic_time() - t0, :native, :millisecond)

    :telemetry.execute([:tiny_axe, :model, :call], %{ms: ms}, %{
      kind: kind,
      ok: match?({:ok, _}, result)
    })

    result
  end

  # Every request is fitted into the context window before it's sent (Ollama
  # would otherwise drop the start of the prompt: the system prompt). With
  # `on_trim: fun`, the caller hears what was cut.
  defp fit(messages, opts) do
    case TinyAxe.Context.fit(messages) do
      {messages, nil} ->
        messages

      {messages, cut} ->
        Logger.info("fitted a request into the context window: #{inspect(cut)}")
        if fun = Keyword.get(opts, :on_trim), do: fun.(cut)
        messages
    end
  end

  defp impl, do: Application.get_env(:tiny_axe, :model_backend, TinyAxe.Ollama)
end
