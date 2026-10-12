defmodule TinyAxe.FakeSite do
  @moduledoc """
  tiny-axe's website as tests need it: `/api/mcp` on 127.0.0.1 (MCP over
  HTTP, plain JSON, as the real one answers), with one key. Every tool call
  is sent to the test process that started it as `{:site_call, tool, args}`.
  `vault_push` takes every note except any whose id starts with "bad"; a
  `fail: true` start answers every call with a 500, and `link: base` answers
  graph_link with links on another site.

  `start/1` returns `%{url: base_url, key: key, stop: fun}`.
  """

  @behaviour Plug

  @key String.duplicate("k", 43)

  def start(opts \\ []) do
    test = self()
    plug = {__MODULE__, %{test: test, fail: Keyword.get(opts, :fail, false), link: opts[:link]}}
    {:ok, pid} = Bandit.start_link(plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    base = "http://127.0.0.1:#{port}"
    %{url: base, key: @key, pid: pid, stop: fn -> Supervisor.stop(pid) end}
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/api/mcp", method: "POST"} = conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    cond do
      Plug.Conn.get_req_header(conn, "authorization") != ["Bearer " <> @key] ->
        reply(conn, 401, %{error: "A valid tiny-axe key is needed"})

      opts.fail ->
        reply(conn, 500, %{error: "Internal server error"})

      true ->
        message = JSON.decode!(body)

        case answer(message, opts.test, opts.link || base(conn)) do
          nil -> Plug.Conn.send_resp(conn, 202, "")
          result -> reply(conn, 200, %{jsonrpc: "2.0", id: message["id"], result: result})
        end
    end
  end

  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "")

  defp answer(%{"method" => "initialize"}, _test, _base),
    do: %{
      protocolVersion: "2025-06-18",
      capabilities: %{tools: %{}},
      serverInfo: %{name: "fake site"}
    }

  defp answer(%{"method" => "tools/list"}, _test, _base) do
    tools =
      for name <-
            ~w(graph_overview graph_search graph_note graph_link graph_add_note signin_link vault_push chat_push),
          do: %{name: name, description: name, inputSchema: %{type: "object"}}

    %{tools: tools}
  end

  defp answer(%{"method" => "tools/call", "params" => %{"name" => tool} = params}, test, base) do
    args = params["arguments"] || %{}
    send(test, {:site_call, tool, args})

    case tool do
      "vault_push" ->
        {bad, good} = Enum.split_with(args["notes"], &String.starts_with?(&1["id"], "bad"))

        text(%{
          written: length(good),
          unchanged: 0,
          refused: Enum.map(bad, &%{id: &1["id"], reason: "bad note"})
        })

      "chat_push" ->
        text(%{id: args["chat"]["id"], written: true})

      "signin_link" ->
        path =
          cond do
            args["page"] == "chats" -> "/chats"
            args["focus"] -> "/note/" <> URI.encode(args["focus"], &URI.char_unreserved?/1)
            true -> "/"
          end

        text(base <> path <> "#signin=one-time-token")

      "graph_link" ->
        cond do
          args["page"] == "chats" ->
            text(base <> "/chats")

          args["focus"] ->
            text(base <> "/note/" <> URI.encode(args["focus"], &URI.char_unreserved?/1))

          true ->
            text(base <> "/")
        end

      _ ->
        text("{}")
    end
  end

  defp answer(%{"id" => _}, _test, _base), do: %{}
  defp answer(_notification, _test, _base), do: nil

  defp text(value) when is_binary(value), do: %{content: [%{type: "text", text: value}]}
  defp text(value), do: text(JSON.encode!(value))

  defp base(conn), do: "http://#{conn.host}:#{conn.port}"

  defp reply(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end
end
