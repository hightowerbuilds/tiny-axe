defmodule TinyAxe.Model do
  @moduledoc """
  The generating model, behind a behaviour so it can be swapped, like
  `TinyAxe.Decider`. `TinyAxe.Ollama` is the default (`config :tiny_axe,
  :model_backend`); tests script answers with `TinyAxe.Model.Script`.

  A call can name another model with `use: {backend, model}`:

    * `{:ollama, "gemma4:e4b-it-qat"}` — local
    * `{:claude, "haiku"}` — `TinyAxe.Model.ClaudeCLI`, on the Claude subscription
    * `{:codex, "gpt-6-luna"}` — `TinyAxe.Model.CodexCLI`, on the ChatGPT subscription

  Claude and Codex leave the machine. `role/1` names the model for each role
  (`config :tiny_axe, :models`).

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

  @type choice :: {:ollama | :claude | :codex, String.t()}

  @spec chat([message()], keyword()) :: {:ok, map()} | {:error, term()}
  def chat(messages, opts \\ []) do
    {impl, opts} = impl(opts)
    timed(:chat, opts, fn -> impl.chat(fit(messages, opts), opts) end)
  end

  @spec stream_chat([message()], (String.t() -> any()), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def stream_chat(messages, on_delta, opts \\ []) do
    {impl, opts} = impl(opts)
    timed(:stream_chat, opts, fn -> impl.stream_chat(fit(messages, opts), on_delta, opts) end)
  end

  @doc """
  The model for a role: `:escalate` (a list, tried in order when the local
  model falls short) or `:browser`. `config :tiny_axe, :models`.
  """
  @spec role(:escalate | :browser) :: [choice()] | choice() | nil
  def role(role), do: Application.get_env(:tiny_axe, :models, []) |> Keyword.get(role)

  @doc "Whether a model runs somewhere other than this machine."
  @spec remote?(choice() | nil) :: boolean()
  def remote?({backend, _}), do: backend in [:claude, :codex]
  def remote?(_), do: false

  @doc "A model's name for the user: \"Claude haiku\", \"Codex gpt-6-luna\"."
  @spec label(choice()) :: String.t()
  def label({:ollama, model}), do: model
  def label({:claude, model}), do: "Claude #{model}"
  def label({:codex, model}), do: "Codex #{model}"

  # Every model call reports its duration and backend as a telemetry event
  # ([:tiny_axe, :model, :call]), which `mix tiny_axe.eval` counts and times.
  defp timed(kind, opts, fun) do
    t0 = System.monotonic_time()
    result = fun.()
    ms = System.convert_time_unit(System.monotonic_time() - t0, :native, :millisecond)
    backend = opts |> Keyword.get(:use) |> backend()

    :telemetry.execute([:tiny_axe, :model, :call], %{ms: ms}, %{
      kind: kind,
      ok: match?({:ok, _}, result),
      backend: backend,
      remote: backend in [:claude, :codex]
    })

    result
  end

  defp backend({backend, _model}), do: backend
  defp backend(nil), do: :default

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

  # The backend a call uses, with its model put in `:model`.
  defp impl(opts) do
    case Keyword.get(opts, :use) do
      nil -> {Application.get_env(:tiny_axe, :model_backend, TinyAxe.Ollama), opts}
      {:ollama, model} -> {TinyAxe.Ollama, Keyword.put(opts, :model, model)}
      {:claude, model} -> {TinyAxe.Model.ClaudeCLI, Keyword.put(opts, :model, model)}
      {:codex, model} -> {TinyAxe.Model.CodexCLI, Keyword.put(opts, :model, model)}
    end
  end
end
