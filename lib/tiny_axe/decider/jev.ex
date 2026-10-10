defmodule TinyAxe.Decider.Jev do
  @moduledoc """
  TypeSafe Jev backend (`POST /v1/systemone`, see https://docs.typesafe.ai/api).

  Reads the key from `TYPESAFE_API_KEY` (or `JEV_API_KEY` / `JEV_API`). Enable with:

      config :tiny_axe, decider: TinyAxe.Decider.Jev

  429 and 529 responses are retried with exponential backoff.

  Answers are checked as they're decoded: a missing answer, a probability
  outside 0..1, or a choice that wasn't offered becomes unknown (`unknown:
  true`), never a guess. `decide_meta/2` also returns the model that answered
  (e.g. "jev-1.13.0"), its token usage and the request id.
  """

  @behaviour TinyAxe.Decider

  # Documented limit per Choice question.
  @impl true
  def max_options, do: 255

  @impl true
  def decide(state, questions) do
    with {:ok, answers, _meta} <- decide_meta(state, questions), do: {:ok, answers}
  end

  @impl true
  def decide_meta(state, questions) do
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

        [
          base_url: config[:base_url] || "https://api.typesafe.ai",
          url: "/v1/systemone",
          auth: {:bearer, key},
          json: body,
          retry: fn _req, resp_or_err ->
            match?(%Req.Response{status: s} when s in [429, 529], resp_or_err)
          end,
          max_retries: 3,
          receive_timeout: :timer.seconds(30)
        ]
        # Tests stub the API here (`plug: {Req.Test, ...}`).
        |> Keyword.merge(config[:req_options] || [])
        |> Req.post()
        |> case do
          {:ok, %Req.Response{status: 200, body: %{"answers" => answers} = body} = resp}
          when is_map(answers) ->
            {:ok, decode_answers(answers, questions), meta(body, resp)}

          {:ok, %Req.Response{status: 200, body: body}} ->
            {:error, {:malformed, body}}

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

  defp encode_question(%{type: :noul, instructions: i, criteria: %{} = c}) do
    %{type: "noul", instructions: i, criteria: Map.new(c, fn {k, v} -> {to_string(k), v} end)}
  end

  defp encode_question(%{type: :noul, instructions: i}), do: %{type: "noul", instructions: i}

  defp encode_question(%{type: :choice, instructions: i, options: opts}),
    do: %{type: "choice", instructions: i, criteria: opts}

  defp encode_question(%{type: :score, instructions: i, criteria: c}),
    do: %{type: "score", instructions: i, criteria: c}

  defp meta(body, resp) do
    usage = body["usage"]

    %{
      model: if(is_binary(body["model"]), do: body["model"]),
      usage:
        if(is_map(usage),
          do: %{input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"]}
        ),
      request_id: resp |> Req.Response.get_header("x-typesafe-request-id") |> List.first()
    }
  end

  defp decode_answers(answers, questions) do
    Map.new(questions, fn {key, q} ->
      {key, decode_answer(q, Map.get(answers, to_string(key)))}
    end)
  end

  @doc false
  def decode_answer(%{type: :noul}, %{"noul" => p}) when is_number(p) and p >= 0 and p <= 1,
    do: %{noul: p}

  def decode_answer(%{type: :noul}, raw), do: %{noul: nil, unknown: true, invalid: raw}

  def decode_answer(%{type: :choice, options: opts}, %{"choice" => choice} = raw) do
    by_name = Map.new(opts, fn {k, _} -> {to_string(k), k} end)
    probabilities = probabilities(raw["probabilities"], &Map.fetch(by_name, &1))

    case Map.fetch(by_name, choice) do
      {:ok, key} ->
        %{choice: key, probabilities: probabilities, confidence: unit(raw["confidence"])}

      :error ->
        %{choice: nil, probabilities: %{}, confidence: 0.0, unknown: true, invalid: raw}
    end
  end

  def decode_answer(%{type: :choice}, raw),
    do: %{choice: nil, probabilities: %{}, confidence: 0.0, unknown: true, invalid: raw}

  def decode_answer(%{type: :score, criteria: criteria}, %{"score" => score} = raw)
      when is_number(score) and score >= 0 and score <= length(criteria) - 1 do
    levels = length(criteria)

    level = fn k ->
      case Integer.parse(to_string(k)) do
        {i, ""} when i >= 0 and i < levels -> {:ok, i}
        _ -> :error
      end
    end

    %{
      score: score,
      probabilities: probabilities(raw["probabilities"], level),
      confidence: unit(raw["confidence"])
    }
  end

  def decode_answer(%{type: :score}, raw),
    do: %{score: nil, probabilities: %{}, confidence: 0.0, unknown: true, invalid: raw}

  # Only offered options, each with a probability in 0..1.
  defp probabilities(raw, key) when is_map(raw) do
    for {k, p} <- raw,
        is_number(p) and p >= 0 and p <= 1,
        {:ok, k} <- [key.(k)],
        into: %{},
        do: {k, p}
  end

  defp probabilities(_raw, _key), do: %{}

  defp unit(p) when is_number(p) and p >= 0 and p <= 1, do: p
  defp unit(_), do: nil
end
