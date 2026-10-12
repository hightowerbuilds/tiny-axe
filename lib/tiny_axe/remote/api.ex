defmodule TinyAxe.Remote.Api do
  @moduledoc """
  The remote chat's edge functions on Supabase (lobsterattack's
  `supabase/functions/ta-remote-*`), each a JSON POST with
  `Authorization: Bearer …`: tiny-axe's site key for `token/3`, the session
  it gives for the rest. Errors never carry the key or the session.
  """

  @type result :: {:ok, map()} | {:error, String.t()}

  @doc "The site key → a session of its owner: `access_token`, `expires_at`, `topic`, `apikey`."
  @spec token(String.t(), String.t(), String.t() | nil) :: result()
  def token(base, key, previous \\ nil),
    do: post(base, "ta-remote-token", key, if(previous, do: %{previous: previous}, else: %{}))

  @doc "The messages tiny-axe hasn't finished, oldest first."
  @spec pending(String.t(), String.t()) :: result()
  def pending(base, session), do: post(base, "ta-remote-pending", session, %{})

  @doc "Where a message stands (`working`, `answered`, `failed`), with the reply if there is one."
  @spec reply(String.t(), String.t(), String.t(), String.t(), String.t() | nil) :: result()
  def reply(base, session, id, status, body \\ nil),
    do: post(base, "ta-remote-reply", session, %{id: id, status: status, body: body})

  defp post(base, function, bearer, body) do
    case Req.post("#{base}/functions/v1/#{function}",
           json: body,
           headers: [{"authorization", "Bearer " <> bearer}],
           retry: false,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %{status: status, body: %{"error" => error}}} ->
        {:error, "#{function}: #{status} #{error}"}

      {:ok, %{status: status}} ->
        {:error, "#{function}: #{status}"}

      {:error, exception} ->
        {:error, "#{function}: #{Exception.message(exception)}"}
    end
  end
end
