defmodule TinyAxe.Decider.Jev do
  @moduledoc """
  TypeSafe Jev backend (`POST /v1/systemone`, see https://docs.typesafe.ai/api).

  Reads the key from `TYPESAFE_API_KEY` (or `JEV_API_KEY` / `JEV_API`). Enable with:

      config :tiny_axe, decider: TinyAxe.Decider.Jev

  429 and 529 responses are retried with exponential backoff.
  """

  @behaviour TinyAxe.Decider

  # Documented limit per Choice question.
  @impl true
  def max_options, do: 255

  @impl true
  def decide(state, questions) do
    config = Application.get_env(:tiny_axe, :jev, [])

    case api_key(config) do
      nil ->
        {:error, :jev_not_configured}

      key ->
        body = %{
          model: config[:model] || "jev-latest",
          state: state,
          questions: Map.new(questions, fn {k, q} -> {k, encode_question(q)} end)
        }

        Req.post(
          base_url: config[:base_url] || "https://api.typesafe.ai",
          url: "/v1/systemone",
          auth: {:bearer, key},
          json: body,
          retry: fn _req, resp_or_err ->
            match?(%Req.Response{status: s} when s in [429, 529], resp_or_err)
          end,
          max_retries: 3,
          receive_timeout: :timer.seconds(30)
        )
        |> case do
          {:ok, %Req.Response{status: 200, body: %{"answers" => answers}}} ->
            {:ok, decode_answers(answers, questions)}

          {:ok, %Req.Response{status: 401, body: body}} ->
            {:error, {:unauthorized, body}}

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, {:http, status, body}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp api_key(config) do
    case config[:api_key] do
      key when is_binary(key) -> if (key = String.trim(key)) != "", do: key
      _ -> nil
    end
  end

  defp encode_question(%{type: :noul, instructions: i}), do: %{type: "noul", instructions: i}

  defp encode_question(%{type: :choice, instructions: i, options: opts}),
    do: %{type: "choice", instructions: i, criteria: opts}

  defp encode_question(%{type: :score, instructions: i, criteria: c}),
    do: %{type: "score", instructions: i, criteria: c}

  defp decode_answers(answers, questions) do
    Map.new(questions, fn {key, q} ->
      raw = Map.get(answers, to_string(key), %{})
      {key, decode_answer(q, raw)}
    end)
  end

  defp decode_answer(%{type: :noul}, raw), do: %{noul: raw["noul"]}

  defp decode_answer(%{type: :choice, options: opts}, raw) do
    by_name = Map.new(opts, fn {k, _} -> {to_string(k), k} end)

    %{
      choice: Map.get(by_name, raw["choice"], raw["choice"]),
      probabilities:
        Map.new(raw["probabilities"] || %{}, fn {k, p} -> {Map.get(by_name, k, k), p} end),
      confidence: raw["confidence"]
    }
  end

  defp decode_answer(%{type: :score}, raw) do
    %{
      score: raw["score"],
      probabilities:
        Map.new(raw["probabilities"] || %{}, fn {k, p} -> {String.to_integer(k), p} end),
      confidence: raw["confidence"]
    }
  end
end
