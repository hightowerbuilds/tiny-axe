defmodule TinyAxe.Model.Script do
  @moduledoc """
  A scripted model for tests. The test sets a function with `script/1`; it
  gets `(messages, opts)` and returns the reply text (or `{:error, reason}`).
  """

  @behaviour TinyAxe.Model

  def script(fun) when is_function(fun, 2) do
    Application.put_env(:tiny_axe, :script_model, fun)
    Application.put_env(:tiny_axe, :model_backend, __MODULE__)
  end

  @impl true
  def chat(messages, opts) do
    with text when is_binary(text) <- reply(messages, opts),
         do: {:ok, %{"message" => %{"content" => text}}}
  end

  @impl true
  def stream_chat(messages, on_delta, opts) do
    with text when is_binary(text) <- reply(messages, opts) do
      on_delta.(text)
      {:ok, text}
    end
  end

  defp reply(messages, opts),
    do: Application.fetch_env!(:tiny_axe, :script_model).(messages, opts)
end

defmodule TinyAxe.Decider.Script do
  @moduledoc """
  A scripted decider for tests. The test's function gets `(key, question,
  state)` for each question and returns a number (yes/no probability), a
  choice key, `:unknown`, or `nil` to take the default: "no" (0.0) for yes/no,
  the first option for a choice. Returning `{:error, reason}` from `script/1`'s
  function for any question fails the whole call, like an outage.
  """

  @behaviour TinyAxe.Decider

  def script(fun) when is_function(fun, 3) do
    Application.put_env(:tiny_axe, :script_decider, fun)
    Application.put_env(:tiny_axe, :decider, __MODULE__)
  end

  @impl true
  def max_options, do: 255

  @impl true
  def decide(state, questions) do
    fun = Application.fetch_env!(:tiny_axe, :script_decider)

    Enum.reduce_while(questions, {:ok, %{}}, fn {key, q}, {:ok, acc} ->
      case fun.(key, q, state) do
        {:error, reason} -> {:halt, {:error, reason}}
        value -> {:cont, {:ok, Map.put(acc, key, answer(q, value))}}
      end
    end)
  end

  defp answer(%{type: :noul}, :unknown), do: %{noul: nil, unknown: true}
  defp answer(%{type: :noul}, nil), do: %{noul: 0.0}
  defp answer(%{type: :noul}, p) when is_number(p), do: %{noul: p}

  defp answer(%{type: :choice}, :unknown),
    do: %{choice: nil, probabilities: %{}, confidence: 0.0, unknown: true}

  defp answer(%{type: :choice, options: opts}, nil) do
    first = opts |> Map.keys() |> Enum.sort_by(&to_string/1) |> hd()
    answer(%{type: :choice, options: opts}, first)
  end

  defp answer(%{type: :choice, options: opts}, choice) do
    probs =
      Map.new(opts, fn {k, _} ->
        {k, if(k == choice, do: 0.9, else: 0.1 / max(map_size(opts) - 1, 1))}
      end)

    %{choice: choice, probabilities: probs, confidence: 0.8}
  end
end
