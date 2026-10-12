defmodule TinyAxe.Memory.Model do
  @moduledoc "Local Gemma only. Deliberately independent of Model, Decider and escalation."

  def settings, do: Application.get_env(:tiny_axe, :memory, [])
  def name, do: Keyword.get(settings(), :model, "gemma4:e4b-it-qat")

  def client do
    url = Keyword.get(settings(), :ollama_url, "http://127.0.0.1:11434")
    uri = URI.parse(url)

    if uri.scheme == "http" and uri.host in ["127.0.0.1", "::1", "localhost"] and
         uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
         uri.path in [nil, "", "/"] do
      # Only the transport plug is injectable in tests; endpoint and redirect policy
      # cannot be overridden by generic/global Ollama request options.
      test = Keyword.take(Keyword.get(settings(), :req_options, []), [:plug])

      {:ok,
       Req.new(
         [
           base_url: url,
           redirect: false,
           retry: false,
           receive_timeout: 120_000,
           connect_options: [timeout: 3000]
         ] ++ test
       )}
    else
      {:error, "memory requires Ollama on this machine's loopback address"}
    end
  end

  def available do
    with {:ok, req} <- client(),
         {:ok, %{status: 200, body: body}} <-
           Req.post(req, url: "/api/show", json: %{model: name()}),
         true <- local_weights?(body) do
      {:ok, name()}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      _ ->
        {:error,
         "local Gemma is unavailable or its local weights could not be verified; search still works"}
    end
  end

  defp local_weights?(%{"model_info" => info, "details" => details} = body)
       when is_map(info) and is_map(details) do
    family = details["family"] || ""

    is_binary(family) and String.starts_with?(family, "gemma") and
      is_number(info["general.parameter_count"]) and info["general.parameter_count"] > 0 and
      body["remote_host"] in [nil, ""] and body["remote_model"] in [nil, ""] and
      not String.contains?(name(), "cloud")
  end

  defp local_weights?(_), do: false

  def chat(messages, schema) do
    with {:ok, _} <- available(),
         {:ok, req} <- client() do
      ctx = Keyword.get(settings(), :num_ctx, 8192)

      body = %{
        model: name(),
        messages: messages,
        stream: false,
        think: false,
        format: schema,
        keep_alive: "30m",
        options: %{num_ctx: ctx, temperature: 0, num_predict: 900}
      }

      # Conservative byte budget includes JSON/schema overhead. Do not let Ollama
      # silently truncate evidence and keep citations to text the model never read.
      if byte_size(JSON.encode!(body)) > ctx - 1200 do
        {:error, "memory question or evidence exceeds the local context budget"}
      else
        started = System.monotonic_time(:millisecond)

        case Req.post(req, url: "/api/chat", json: body) do
          {:ok, %{status: 200, body: %{"message" => %{"content" => text}} = result}} ->
            TinyAxe.Usage.emit(
              :ollama,
              :local,
              name(),
              %{input: result["prompt_eval_count"], output: result["eval_count"]},
              true,
              System.monotonic_time(:millisecond) - started
            )

            case JSON.decode(text) do
              {:ok, %{} = data} -> {:ok, data}
              _ -> {:error, "local Gemma returned an unreadable response; try direct search"}
            end

          _ ->
            {:error, "local Gemma did not answer; no remote model was called"}
        end
      end
    end
  end
end
