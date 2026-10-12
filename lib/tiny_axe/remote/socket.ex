defmodule TinyAxe.Remote.Socket do
  @moduledoc """
  A websocket client on Mint, for `TinyAxe.Remote`. It belongs to the process
  that opened it: that process passes every message it gets to `stream/2`,
  which turns the ones for this socket into events:

    * `:open` — the upgrade went through; frames can be sent;
    * `{:text, text}` — a text frame;
    * `{:closed, reason}` — the other end closed it.

  Pings are answered here.
  """

  defstruct [:conn, :ref, :websocket, :status, headers: []]

  @type t :: %__MODULE__{}
  @type event :: :open | {:text, String.t()} | {:closed, term()}

  @doc "Starts connecting to a `ws://` or `wss://` URL; `:open` follows."
  @spec connect(String.t(), timeout()) :: {:ok, t()} | {:error, term()}
  def connect(url, timeout \\ 10_000) do
    uri = URI.parse(url)
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    {http, ws} =
      case uri.scheme do
        "wss" -> {:https, :wss}
        _ -> {:http, :ws}
      end

    with {:ok, conn} <-
           Mint.HTTP.connect(http, uri.host, uri.port,
             protocols: [:http1],
             transport_opts: [timeout: timeout]
           ),
         {:ok, conn, ref} <- upgrade(ws, conn, path) do
      {:ok, %__MODULE__{conn: conn, ref: ref}}
    end
  end

  defp upgrade(ws, conn, path) do
    case Mint.WebSocket.upgrade(ws, conn, path, []) do
      {:ok, conn, ref} ->
        {:ok, conn, ref}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason}
    end
  end

  @doc "Turns a process message into events, or `:unknown` if it isn't this socket's."
  @spec stream(t(), term()) :: {:ok, t(), [event()]} | {:error, t(), term()} | :unknown
  def stream(%__MODULE__{conn: conn} = s, message) do
    case Mint.WebSocket.stream(conn, message) do
      :unknown -> :unknown
      {:ok, conn, responses} -> responses(%{s | conn: conn}, responses, [])
      {:error, conn, reason, _responses} -> {:error, %{s | conn: conn}, reason}
    end
  end

  defp responses(s, [], events), do: {:ok, s, Enum.reverse(events)}

  defp responses(%{ref: ref} = s, [{:status, ref, status} | rest], events),
    do: responses(%{s | status: status}, rest, events)

  defp responses(%{ref: ref} = s, [{:headers, ref, headers} | rest], events),
    do: responses(%{s | headers: headers}, rest, events)

  defp responses(%{ref: ref, websocket: nil} = s, [{:done, ref} | rest], events) do
    case Mint.WebSocket.new(s.conn, ref, s.status, s.headers) do
      {:ok, conn, websocket} ->
        responses(%{s | conn: conn, websocket: websocket}, rest, [:open | events])

      {:error, conn, reason} ->
        {:error, %{s | conn: conn}, reason}
    end
  end

  defp responses(%{ref: ref, websocket: ws} = s, [{:data, ref, data} | rest], events)
       when ws != nil do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} -> frames(%{s | websocket: ws}, frames, rest, events)
      {:error, ws, reason} -> {:error, %{s | websocket: ws}, reason}
    end
  end

  defp responses(%{ref: ref} = s, [{:error, ref, reason} | _], _events), do: {:error, s, reason}
  defp responses(s, [_ | rest], events), do: responses(s, rest, events)

  defp frames(s, [], rest, events), do: responses(s, rest, events)

  defp frames(s, [{:text, text} | more], rest, events),
    do: frames(s, more, rest, [{:text, text} | events])

  defp frames(s, [{:ping, data} | more], rest, events) do
    case send_frame(s, {:pong, data}) do
      {:ok, s} -> frames(s, more, rest, events)
      {:error, s, reason} -> {:error, s, reason}
    end
  end

  defp frames(s, [{:close, code, reason} | _], _rest, events),
    do: {:ok, s, Enum.reverse([{:closed, {code, reason}} | events])}

  defp frames(s, [{:error, reason} | _], _rest, _events), do: {:error, s, reason}
  defp frames(s, [_ | more], rest, events), do: frames(s, more, rest, events)

  @doc "Sends a text frame."
  @spec send_text(t(), String.t()) :: {:ok, t()} | {:error, t(), term()}
  def send_text(s, text), do: send_frame(s, {:text, text})

  defp send_frame(%{websocket: nil} = s, _frame), do: {:error, s, :not_open}

  defp send_frame(%{conn: conn, ref: ref, websocket: ws} = s, frame) do
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      {:ok, %{s | conn: conn, websocket: ws}}
    else
      {:error, %Mint.WebSocket{} = ws, reason} -> {:error, %{s | websocket: ws}, reason}
      {:error, conn, reason} -> {:error, %{s | conn: conn}, reason}
    end
  end

  @doc "Closes it (politely if it's open); never fails."
  @spec close(t() | nil) :: :ok
  def close(nil), do: :ok

  def close(s) do
    _ = if s.websocket, do: send_frame(s, {:close, 1000, ""})
    _ = Mint.HTTP.close(s.conn)
    :ok
  end
end
