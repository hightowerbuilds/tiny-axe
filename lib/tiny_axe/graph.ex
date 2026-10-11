defmodule TinyAxe.Graph do
  @moduledoc """
  The know-how graph viewer (`graph/`, a small Node server): a page showing
  what tiny-axe has learned, served on 127.0.0.1 only. It runs as an MCP
  server (`server.js --mcp`) under the reserved name `graph`, so agents reach
  it through the gate like any other, and `/graph` in the TUI calls it
  directly.

  `graph_open` starts the page's HTTP server (once, then reuses it) and gives
  back a link carrying a token; `graph_close` stops it. Neither opens a
  browser: the user gets the link. Both are `local`: they open or close a port
  on this machine and send nothing anywhere, so they run without asking.

  `server.js` is the installed copy (`~/.local/share/tiny-axe/graph`, from
  `mix tiny_axe.install`) or, failing that, this repo's `graph/dist` (`npm run
  build` in `graph/`).

  `config :tiny_axe, :graph`: `enabled`, `server_js`, `vault` (the viewer's
  default is `~/.local/share/tiny-axe/vault`) and `port`.
  """

  alias TinyAxe.MCP

  @name "graph"

  # The source tree's build, found at compile time (graph/dist is gitignored,
  # so it's only there once built).
  @repo_server Path.expand("../../graph/dist/server.js", __DIR__)

  def name, do: @name

  @doc "Whether the viewer can run here: switched on, with Node and its server.js found."
  @spec available?() :: boolean()
  def available?,
    do: settings()[:enabled] != false and node_exe() != nil and server_js() != nil

  @doc "Whether the graph server is running."
  @spec running?() :: boolean()
  def running?, do: @name in MCP.running()

  @doc "Starts the graph server (its HTTP page opens only when `graph_open` is called)."
  @spec start() :: {:ok, pid()} | {:error, term()}
  def start do
    if available?(),
      do: MCP.start_server(@name, config()),
      else: {:error, :graph_unavailable}
  end

  @doc "The viewer's server: the installed one, else this repo's build, else nil."
  @spec server_js() :: String.t() | nil
  def server_js do
    installed =
      Path.join(
        System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"),
        "tiny-axe/graph/server.js"
      )

    Enum.find([settings()[:server_js], installed, @repo_server], &(&1 && File.regular?(&1)))
  end

  @doc "The MCP server config for the viewer."
  @spec config() :: map()
  def config do
    settings = settings()

    %{
      "type" => "stdio",
      "command" => node_exe(),
      "args" =>
        [server_js(), "--mcp"] ++
          if(settings[:vault], do: ["--vault", settings[:vault]], else: []) ++
          if(settings[:port], do: ["--port", to_string(settings[:port])], else: []),
      "policy" => %{"local" => ["graph_open", "graph_close"]}
    }
  end

  @doc """
  Opens the graph page (starting the server first if it isn't running) and
  returns its link, optionally focused on one note. Never opens a browser.
  """
  @spec open(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def open(focus \\ nil) do
    args = if focus in [nil, ""], do: %{}, else: %{"focus" => focus}

    with :ok <- ensure_started(),
         {:ok, result} <- MCP.call(@name, "graph_open", args, 30_000) do
      if result["isError"] == true, do: {:error, failure(result)}, else: url(text(result))
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "the graph viewer didn't answer (#{inspect(reason)})"}
    end
  end

  @doc "Stops the graph page's HTTP server (the MCP server keeps running)."
  @spec close() :: :ok | {:error, String.t()}
  def close do
    if running?() do
      case MCP.call(@name, "graph_close", %{}, 15_000) do
        {:ok, %{"isError" => true} = result} -> {:error, failure(result)}
        {:ok, _} -> :ok
        {:error, reason} -> {:error, "the graph viewer didn't answer (#{inspect(reason)})"}
      end
    else
      :ok
    end
  end

  defp ensure_started do
    cond do
      running?() ->
        :ok

      not available?() ->
        {:error,
         "the graph viewer isn't here: it needs Node and graph/ built " <>
           "(`mix tiny_axe.install`, or `npm run build` in graph/)"}

      true ->
        case start() do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, "the graph viewer couldn't start (#{inspect(reason)})"}
        end
    end
  end

  # The link is the first line; only one on this computer is taken.
  defp url(text) do
    link = text |> String.split("\n", parts: 2) |> hd() |> String.trim()

    case URI.parse(link) do
      %URI{scheme: "http", host: host} when host in ["127.0.0.1", "localhost"] -> {:ok, link}
      _ -> {:error, "the graph viewer didn't give a link on this computer"}
    end
  end

  defp text(%{"content" => content}),
    do: content |> Enum.map_join("\n", &(&1["text"] || "")) |> String.trim()

  defp text(_result), do: ""

  defp failure(result) do
    case text(result) do
      "" -> "the graph viewer said no, without saying why"
      why -> why
    end
  end

  defp settings, do: Application.get_env(:tiny_axe, :graph, [])

  defp node_exe, do: System.find_executable("node")
end
