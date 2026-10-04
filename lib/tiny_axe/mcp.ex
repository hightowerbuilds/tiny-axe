defmodule TinyAxe.MCP do
  @moduledoc """
  The MCP servers the user has connected, from `~/.config/tiny-axe/mcp.json`
  (`config :tiny_axe, :mcp_config`), in the same shape as Claude Code's
  `.mcp.json`, plus a `policy` per server for `TinyAxe.Tools.Policy`:

      {"mcpServers": {
        "github": {
          "type": "stdio", "command": "github-mcp-server", "args": ["stdio"],
          "env": {"GITHUB_TOKEN": "${GITHUB_TOKEN}"},
          "policy": {"read": ["get_*", "list_*", "search_*"], "outward": ["create_*"], "deny": ["delete_*"]}
        }
      }}

  `${VAR}` in `env` and `headers` comes from the environment (and so from
  `~/.config/tiny-axe/env`), so secrets stay out of this file and out of every
  prompt. Server names may only use letters, digits and `-`, since they become
  part of tool names.

  Each server runs as a `TinyAxe.MCP.Client` under a supervisor. Its tools are
  offered as `<server>__<tool>`; only `TinyAxe.Tools.Gate` calls them.
  """

  require Logger

  alias TinyAxe.MCP.Client

  @separator "__"

  @doc "Where the user's MCP servers are configured."
  @spec config_path() :: String.t()
  def config_path do
    Application.get_env(:tiny_axe, :mcp_config) ||
      Path.join(
        System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config"),
        "tiny-axe/mcp.json"
      )
  end

  @doc "The configured servers, `%{name => config}`, with `${VAR}` filled in."
  @spec configured() :: %{String.t() => map()}
  def configured do
    with {:ok, raw} <- File.read(config_path()),
         {:ok, %{"mcpServers" => servers}} when is_map(servers) <- JSON.decode(raw) do
      for {name, config} <- servers, valid_name?(name), into: %{} do
        {name, expand(config)}
      end
    else
      {:error, :enoent} ->
        %{}

      other ->
        Logger.warning("couldn't read #{config_path()}: #{inspect(other)}")
        %{}
    end
  end

  @doc "Starts every configured server that isn't running. Returns the ones that failed."
  @spec start_configured() :: [{String.t(), term()}]
  def start_configured do
    for {name, config} <- configured(),
        not running?(name),
        {:error, reason} <- [start_server(name, config)],
        do: {name, reason}
  end

  @spec start_server(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def start_server(name, config) do
    if valid_name?(name) do
      spec = {Client, name: name, config: Map.put_new(config, "type", "stdio")}

      case DynamicSupervisor.start_child(TinyAxe.MCP.Supervisor, spec) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :bad_name}
    end
  end

  @spec stop_server(String.t()) :: :ok
  def stop_server(name) do
    case Registry.lookup(TinyAxe.MCP.Registry, name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(TinyAxe.MCP.Supervisor, pid)
      [] -> :ok
    end

    :ok
  end

  @spec running() :: [String.t()]
  def running, do: Registry.select(TinyAxe.MCP.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  defp running?(name), do: Registry.lookup(TinyAxe.MCP.Registry, name) != []

  @doc """
  Every tool of the given servers (`:all`, or a list of names), as
  `%{name: "server__tool", server:, tool:, definition:, policy:}`.
  """
  @spec tools(:all | [String.t()]) :: [map()]
  def tools(servers \\ :all) do
    names = if servers == :all, do: running(), else: Enum.filter(servers, &running?/1)

    for server <- Enum.sort(names),
        {tools, config} <- [safe_tools(server)],
        definition <- tools,
        name = server <> @separator <> definition["name"],
        # MCP tool names: letters, digits, _ and -, at most 64.
        name =~ ~r/\A[A-Za-z0-9_-]{1,64}\z/ do
      %{
        name: name,
        server: server,
        tool: definition["name"],
        definition: definition,
        policy: config["policy"] || %{}
      }
    end
  end

  defp safe_tools(server) do
    {Client.tools(server), Client.config(server)}
  catch
    :exit, _ -> {[], %{}}
  end

  @spec call(String.t(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  defdelegate call(server, tool, args, timeout \\ 120_000), to: Client

  defp valid_name?(name) do
    ok = is_binary(name) and name =~ ~r/\A[A-Za-z0-9-]{1,30}\z/
    if not ok, do: Logger.warning("MCP server name #{inspect(name)}: use letters, digits and -")
    ok
  end

  # `${VAR}` in env and headers, from the environment.
  defp expand(config) do
    Enum.reduce(["env", "headers"], config, fn key, config ->
      case config[key] do
        %{} = map -> Map.put(config, key, Map.new(map, fn {k, v} -> {k, fill(v)} end))
        _ -> config
      end
    end)
  end

  defp fill(value) when is_binary(value),
    do: Regex.replace(~r/\$\{(\w+)\}/, value, fn _, var -> System.get_env(var, "") end)

  defp fill(value), do: value
end
