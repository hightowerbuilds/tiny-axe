defmodule Mix.Tasks.TinyAxe.Mcp do
  @shortdoc "Add, check, list and remove the MCP servers tiny-axe's agent can use"
  @moduledoc """
  Manages `~/.config/tiny-axe/mcp.json` (`TinyAxe.MCP`): the MCP servers
  tiny-axe's agent can use, always through the tool gate.

      mix tiny_axe.mcp                      # every server, and its tools by class
      mix tiny_axe.mcp templates            # the ready-made policies
      mix tiny_axe.mcp add memory --template memory -- npx -y @modelcontextprotocol/server-memory
      mix tiny_axe.mcp add github --template github --env GITHUB_PERSONAL_ACCESS_TOKEN='${keyring:github}' -- github-mcp-server stdio
      mix tiny_axe.mcp add docs --url https://example.com/mcp --header 'Authorization=Bearer ${keyring:docs}'
      mix tiny_axe.mcp check github         # start it, show its tools and how each is classed
      mix tiny_axe.mcp remove github
      mix tiny_axe.mcp secret github        # how to put a secret in the keyring

  A tool its policy doesn't name is asked about every time it's used.
  Secrets go in the keyring (`${keyring:NAME}`) or `~/.config/tiny-axe/env`
  (`${VAR}`), never in `mcp.json` itself.
  """

  use Mix.Task

  alias TinyAxe.MCP
  alias TinyAxe.MCP.Policies

  @impl true
  def run(["templates"]) do
    for name <- Policies.names() do
      policy = Policies.get(name)
      Mix.shell().info("#{name}")

      for class <- ~w(read local outward deny),
          list = policy[class],
          list != nil,
          do: Mix.shell().info("  #{String.pad_trailing(class, 8)} #{Enum.join(list, ", ")}")
    end
  end

  def run(["secret", name]) do
    Mix.shell().info("""
    Store it in the keyring (you'll be asked for the secret; it isn't shown or saved anywhere else):

        secret-tool store --label="tiny-axe #{name}" service tiny-axe key #{name}

    Then use ${keyring:#{name}} in the server's env or headers.
    """)
  end

  def run(["add", name | rest]) do
    {opts, command, _} =
      OptionParser.parse(rest,
        strict: [template: :string, env: :keep, url: :string, header: :keep]
      )

    config =
      cond do
        opts[:url] ->
          %{"type" => "http", "url" => opts[:url], "headers" => pairs(opts, :header)}

        command != [] ->
          [cmd | args] = command
          %{"type" => "stdio", "command" => cmd, "args" => args, "env" => pairs(opts, :env)}

        true ->
          Mix.raise("give the server's command after --, or --url for one over HTTP")
      end

    config =
      case opts[:template] do
        nil ->
          config

        t ->
          if Policies.get(t),
            do: Map.put(config, "policy", t),
            else: Mix.raise("no template #{t}; see mix tiny_axe.mcp templates")
      end

    case MCP.put_config(name, config) do
      :ok ->
        Mix.shell().info(
          "added #{name} to #{MCP.config_path()}; check it with mix tiny_axe.mcp check #{name}"
        )

      {:error, :bad_name} ->
        Mix.raise("server names use letters, digits and -")

      {:error, :reserved} ->
        Mix.raise("\"browser\" is tiny-axe's own browser; pick another name")

      {:error, reason} ->
        Mix.raise("couldn't write #{MCP.config_path()}: #{reason}")
    end
  end

  def run(["remove", name]) do
    :ok = MCP.delete_config(name)
    Mix.shell().info("removed #{name}")
  end

  def run(["check", name]) do
    Mix.Task.run("app.start")

    case MCP.configured()[name] do
      nil -> Mix.raise("no server called #{name} in #{MCP.config_path()}")
      config -> report(name, config)
    end
  end

  def run([]) do
    Mix.Task.run("app.start")
    configured = MCP.configured()

    if configured == %{},
      do:
        Mix.shell().info("No MCP servers yet (#{MCP.config_path()}). See mix help tiny_axe.mcp."),
      else: for({name, config} <- Enum.sort(configured), do: report(name, config))
  end

  def run(_), do: Mix.Task.run("help", ["tiny_axe.mcp"])

  # Starts the server for a moment and shows its tools by class.
  defp report(name, config) do
    case MCP.start_server(name, config) do
      {:ok, _} ->
        status = Enum.find(MCP.status(), &(&1.name == name))

        Mix.shell().info(
          "✓ #{name}: #{status.tools |> Map.values() |> List.flatten() |> length()} tools"
        )

        if status.policy_error, do: Mix.shell().error("  ⚠ #{status.policy_error}")

        for class <- [:read, :local, :per_action, :outward, :commit, :refused],
            tools = status.tools[class],
            tools do
          Mix.shell().info(
            "  #{String.pad_trailing(describe(class), 22)} #{Enum.join(tools, ", ")}"
          )
        end

        MCP.stop_server(name)

      {:error, reason} ->
        Mix.shell().error("✗ #{name}: #{inspect(reason)}")
    end
  end

  defp describe(:read), do: "runs (reads):"
  defp describe(:local), do: "runs (local changes):"
  defp describe(:per_action), do: "judged per action:"
  defp describe(:outward), do: "asks you each time:"
  defp describe(:commit), do: "refused (spends money):"
  defp describe(:refused), do: "refused:"

  defp pairs(opts, key) do
    for value <- Keyword.get_values(opts, key), into: %{} do
      case String.split(value, "=", parts: 2) do
        [k, v] -> {k, v}
        _ -> Mix.raise("--#{key} takes KEY=VALUE, got #{inspect(value)}")
      end
    end
  end
end
