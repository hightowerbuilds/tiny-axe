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
  `~/.config/tiny-axe/env`), and `${keyring:NAME}` from the system keyring
  (`secret-tool lookup service tiny-axe key NAME`), so secrets stay out of
  this file and out of every prompt. `policy` can name a ready-made template
  (`"policy": "github"`, see `TinyAxe.MCP.Policies`). Server names may only use letters, digits and `-`, since they become
  part of tool names.

  Each server runs as a `TinyAxe.MCP.Client` under a supervisor. Its tools are
  offered as `<server>__<tool>`; only `TinyAxe.Tools.Gate` calls them.
  """

  require Logger

  alias TinyAxe.MCP.{Client, Policies}

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
      for {name, config} <- servers, valid_name?(name), not reserved?(name), into: %{} do
        {name, config |> expand() |> with_policy()}
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
    failed =
      for {name, config} <- configured(),
          not running?(name),
          {:error, reason} <- [start_server(name, config)],
          do: {name, reason}

    :persistent_term.put({__MODULE__, :failed}, Map.new(failed))
    failed
  end

  @doc """
  Every configured server (and tiny-axe's browser): whether it's running, its
  tools by class, and why it isn't running, if it failed.
  """
  @spec status() :: [map()]
  def status do
    failed = :persistent_term.get({__MODULE__, :failed}, %{})
    configured = configured()
    names = Enum.uniq(Map.keys(configured) ++ running()) |> Enum.sort()

    for name <- names do
      tools = tools([name])

      %{
        name: name,
        running: running?(name),
        error: failed[name] && describe_error(failed[name]),
        policy_error: get_in(configured, [name, "policy_error"]),
        tools:
          tools
          |> Enum.reject(&(&1.tool in List.wrap(&1.policy["hidden"])))
          |> Enum.group_by(&class_of/1, & &1.tool)
          |> Map.new(fn {class, names} -> {class, Enum.sort(names)} end)
      }
    end
  end

  # The browser's actions are classed one by one, by what they'd do on the page.
  defp class_of(%{policy: %{"browser" => true} = policy, tool: tool}),
    do: if(tool in List.wrap(policy["read"]), do: :read, else: :per_action)

  defp class_of(t), do: TinyAxe.Tools.Policy.classify(t.definition, t.policy)

  defp describe_error({:connect_failed, {:not_found, cmd}}), do: "#{cmd} isn't installed"
  defp describe_error({:connect_failed, :timeout}), do: "it didn't answer when tiny-axe connected"
  defp describe_error({:connect_failed, :exited_at_start}), do: "it exited as soon as it started"

  defp describe_error({:connect_failed, {:exited, status}}),
    do: "it exited (#{status}) when tiny-axe connected"

  defp describe_error(other), do: inspect(other)

  # A template name or adjusted template becomes the policy itself. An unknown
  # template gives no policy, so every tool asks, and says so.
  defp with_policy(config) do
    case Policies.resolve(config["policy"]) do
      {:ok, policy} ->
        Map.put(config, "policy", policy)

      {:error, name} ->
        config
        |> Map.put("policy", %{})
        |> Map.put("policy_error", "no policy template called #{name}; every tool asks")
    end
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

  # tiny-axe's own browser (TinyAxe.Browser) runs under this name.
  defp reserved?("browser") do
    Logger.warning(
      "MCP server name \"browser\" is tiny-axe's own; rename yours in #{config_path()}"
    )

    true
  end

  defp reserved?(_name), do: false

  defp valid_name?(name) do
    ok = is_binary(name) and name =~ ~r/\A[A-Za-z0-9-]{1,30}\z/
    if not ok, do: Logger.warning("MCP server name #{inspect(name)}: use letters, digits and -")
    ok
  end

  # `${VAR}` in env and headers, from the environment; `${keyring:NAME}`, from
  # the system keyring.
  defp expand(config) do
    Enum.reduce(["env", "headers"], config, fn key, config ->
      case config[key] do
        %{} = map -> Map.put(config, key, Map.new(map, fn {k, v} -> {k, fill(v)} end))
        _ -> config
      end
    end)
  end

  defp fill(value) when is_binary(value) do
    value
    |> then(&Regex.replace(~r/\$\{keyring:([\w.-]+)\}/, &1, fn _, key -> keyring(key) end))
    |> then(&Regex.replace(~r/\$\{(\w+)\}/, &1, fn _, var -> System.get_env(var, "") end))
  end

  defp fill(value), do: value

  @doc "A secret from the system keyring (`service tiny-axe key NAME`), or \"\"."
  @spec keyring(String.t()) :: String.t()
  def keyring(key) do
    tool = Application.get_env(:tiny_axe, :secret_tool, "secret-tool")

    with path when path != nil <- System.find_executable(tool),
         {secret, 0} <-
           System.cmd(path, ["lookup", "service", "tiny-axe", "key", key], stderr_to_stdout: true) do
      String.trim_trailing(secret, "\n")
    else
      _ ->
        Logger.warning("no secret #{key} in the keyring (service tiny-axe)")
        ""
    end
  end

  ## Editing mcp.json (mix tiny_axe.mcp)

  @doc "Adds or replaces a server in `mcp.json`, keeping the rest of the file."
  @spec put_config(String.t(), map()) :: :ok | {:error, term()}
  def put_config(name, config) do
    cond do
      not valid_name?(name) -> {:error, :bad_name}
      name == "browser" -> {:error, :reserved}
      true -> update_file(&Map.put(&1, name, config))
    end
  end

  @spec delete_config(String.t()) :: :ok | {:error, term()}
  def delete_config(name), do: update_file(&Map.delete(&1, name))

  defp update_file(fun) do
    path = config_path()

    current =
      case File.read(path) do
        {:ok, raw} -> JSON.decode!(raw)
        {:error, :enoent} -> %{}
      end

    updated = Map.update(current, "mcpServers", fun.(%{}), fun)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, updated |> :json.format() |> IO.iodata_to_binary())
    File.chmod!(path, 0o600)
  rescue
    e -> {:error, Exception.message(e)}
  end
end
