defmodule Mix.Tasks.TinyAxe.JevCheck do
  @shortdoc "Check that the TypeSafe API key works"
  @moduledoc """
  Sends the quickstart request to TypeSafe and explains the result, without
  printing the key.

      TYPESAFE_API_KEY=... mix tiny_axe.jev_check
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    raw =
      System.get_env("TYPESAFE_API_KEY") || System.get_env("JEV_API_KEY") ||
        System.get_env("JEV_API")

    case raw do
      nil ->
        Mix.shell().error("No key found. Put TYPESAFE_API_KEY (or JEV_API) in .env.")

      raw ->
        describe_key(raw)
        call()
    end
  end

  defp describe_key(raw) do
    key = String.trim(raw)

    Mix.shell().info("key: #{String.length(key)} chars")

    if key != raw,
      do: Mix.shell().info("  note: stripped surrounding whitespace/newline from the key")

    if String.match?(key, ~r/^["']|["']$/),
      do: Mix.shell().error("  key is wrapped in quotes — remove them")

    if String.match?(key, ~r/\s/),
      do: Mix.shell().error("  key contains whitespace — it was likely pasted wrong")

    if String.starts_with?(key, "Bearer "),
      do: Mix.shell().error("  drop the \"Bearer \" prefix; it's added for you")
  end

  defp call do
    t0 = System.monotonic_time(:millisecond)

    result =
      TinyAxe.Decider.Jev.decide(
        "Hi, I've been trying to connect my Stripe account for 3 days and it keeps failing. Please help ASAP.",
        %{urgency: %{type: :noul, instructions: "Does this message express urgency?"}}
      )

    ms = System.monotonic_time(:millisecond) - t0

    case result do
      {:ok, answers} ->
        Mix.shell().info("OK in #{ms}ms: #{inspect(answers)}")

      {:error, {:unauthorized, body}} ->
        Mix.shell().error("""
        401 Unauthorized: #{inspect(body)}
          The server rejected the key itself. Check that it was copied from
          https://console.typesafe.ai/keys in full, is not revoked, and that the
          account has finished activation (new signups may still be queued).
        """)

      {:error, {:http, status, body}} ->
        Mix.shell().error("HTTP #{status}: #{inspect(body)}")

      {:error, reason} ->
        Mix.shell().error("Request failed: #{inspect(reason)}")
    end
  end
end
