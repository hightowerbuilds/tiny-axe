defmodule TinyAxe.Graph do
  @moduledoc """
  tiny-axe's website (`docs/plan-lobsterattack.md`) as an MCP server: what
  tiny-axe has learned, and every chat, on the user's own page of the site,
  for them (and whoever they let in) to see after signing in. It's connected
  under the reserved name `graph`, over HTTP to `<site>/api/mcp`, with the
  account's key from the keyring (`TinyAxe.Account`); so it's there once
  there's an account.

  Agents reach it through the gate like any other server. Its read tools
  (`graph_overview`, `graph_search`, `graph_note`, `graph_link`) only read
  the user's own page, so they run without asking. `vault_push` and
  `chat_push` are hidden from agents: only tiny-axe's own code sends notes and
  chats (`TinyAxe.Sync`), and `/graph` in the TUI calls `graph_link` directly.

  `config :tiny_axe, :graph, enabled: false` leaves it unconnected.
  """

  alias TinyAxe.{Account, MCP}

  @name "graph"
  @read ["graph_overview", "graph_search", "graph_note", "graph_link"]
  @hidden ["vault_push", "chat_push"]

  def name, do: @name

  @doc "Whether the site can be connected: switched on, with an account and its key."
  @spec available?() :: boolean()
  def available?, do: settings()[:enabled] != false and Account.current() != nil

  @doc "Whether the site's MCP connection is up."
  @spec running?() :: boolean()
  def running?, do: @name in MCP.running()

  @doc "Connects to the site."
  @spec start() :: {:ok, pid()} | {:error, term()}
  def start do
    case config() do
      nil -> {:error, :no_account}
      config -> MCP.start_server(@name, config)
    end
  end

  @doc "The MCP server config for the site, with the account's key; nil without one."
  @spec config() :: map() | nil
  def config do
    with true <- settings()[:enabled] != false,
         {:ok, key} <- Account.key() do
      %{
        "type" => "http",
        "url" => Account.site_url() <> "/api/mcp",
        "headers" => %{"authorization" => "Bearer " <> key},
        "policy" => %{"read" => @read, "hidden" => @hidden}
      }
    else
      _ -> nil
    end
  end

  @doc """
  Calls one of the site's tools from tiny-axe's own code (connecting first if
  need be). `{:ok, text}` with what it said, or `{:error, why}`.
  """
  @spec call(String.t(), map(), timeout()) :: {:ok, String.t()} | {:error, String.t()}
  def call(tool, args, timeout \\ 60_000) do
    with :ok <- ensure_started(),
         {:ok, result} <- MCP.call(@name, tool, args, timeout) do
      if result["isError"] == true, do: {:error, failure(result)}, else: {:ok, text(result)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "the site didn't answer (#{inspect(reason)})"}
    end
  end

  @doc """
  The link to the user's page of the site, optionally one note (`focus`) or
  the chats (`page: "chats"`). Never opens a browser.
  """
  @spec open(String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def open(focus \\ nil, opts \\ []) do
    args =
      %{}
      |> then(&if(focus in [nil, ""], do: &1, else: Map.put(&1, "focus", focus)))
      |> then(&if(opts[:page], do: Map.put(&1, "page", opts[:page]), else: &1))

    with {:ok, text} <- call("graph_link", args, 30_000), do: url(text)
  end

  defp ensure_started do
    cond do
      running?() ->
        :ok

      not available?() ->
        {:error, "there's no tiny-axe account on this computer yet; /account sets one up"}

      true ->
        case start() do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            {:error, "couldn't connect to #{Account.site_url()} (#{inspect(reason)})"}
        end
    end
  end

  # Only a link to the site itself is taken.
  defp url(text) do
    link = text |> String.split("\n", parts: 2) |> hd() |> String.trim()

    if link == Account.site_url() or String.starts_with?(link, Account.site_url() <> "/"),
      do: {:ok, link},
      else: {:error, "the site didn't give a link to itself"}
  end

  defp text(%{"content" => content}),
    do: content |> Enum.map_join("\n", &(&1["text"] || "")) |> String.trim()

  defp text(_result), do: ""

  defp failure(result) do
    case text(result) do
      "" -> "the site said no, without saying why"
      why -> why
    end
  end

  defp settings, do: Application.get_env(:tiny_axe, :graph, [])
end
