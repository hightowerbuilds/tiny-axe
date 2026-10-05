defmodule TinyAxe.MCP.Policies do
  @moduledoc """
  Ready-made policies for well-known MCP servers, so a server can be added
  with `"policy": "github"` rather than a list of its tools. A template can be
  adjusted: `"policy": {"template": "github", "deny": ["merge_*"]}` adds to
  its lists.

  Tools a template doesn't name are outward (asked about every time), so a
  template that's out of date with its server errs on the side of asking.
  Each template only names tools by what they do on that server; the gate
  still applies everything else (limits, approvals, redaction, the journal).
  """

  @templates %{
    # github/github-mcp-server and @modelcontextprotocol/server-github
    "github" => %{
      "read" => ["get_*", "list_*", "search_*"],
      "outward" => [
        "create_*",
        "update_*",
        "add_*",
        "push_*",
        "fork_*",
        "merge_*",
        "request_*",
        "assign_*",
        "submit_*",
        "dismiss_*",
        "mark_*"
      ],
      "deny" => ["delete_*"]
    },
    # @modelcontextprotocol/server-memory: a knowledge graph on this machine.
    "memory" => %{
      "read" => ["read_graph", "search_nodes", "open_nodes"],
      "local" => ["create_*", "add_*", "delete_*"]
    },
    # mcp-server-fetch: reading pages (tiny-axe's browser does this too).
    "fetch" => %{"read" => ["fetch"]},
    # @modelcontextprotocol/server-filesystem: reading only; tiny-axe's own
    # file plans (with undo) do the writing.
    "filesystem" => %{
      "read" => [
        "read_*",
        "list_*",
        "search_*",
        "get_*",
        "directory_tree"
      ],
      "deny" => ["write_file", "edit_file", "move_file", "create_directory"]
    },
    # Thinking aids with no effects.
    "sequential-thinking" => %{"read" => ["sequentialthinking"]},
    "time" => %{"read" => ["*"]},
    # Web search APIs.
    "brave-search" => %{"read" => ["brave_*"]},
    # Read-only access to a database.
    "postgres" => %{"read" => ["query"]},
    "sqlite" => %{
      "read" => ["read_query", "list_tables", "describe_table"],
      "outward" => ["write_query", "create_table", "append_insight"]
    }
  }

  @spec names() :: [String.t()]
  def names, do: @templates |> Map.keys() |> Enum.sort()

  @spec get(String.t()) :: map() | nil
  def get(name), do: @templates[name]

  @doc """
  The policy a server's config asks for: a template's name, a map with a
  `"template"` and lists to add, or a plain map. Unknown templates give `{:error, name}`.
  """
  @spec resolve(term()) :: {:ok, map()} | {:error, String.t()}
  def resolve(nil), do: {:ok, %{}}

  def resolve(name) when is_binary(name) do
    case get(name) do
      nil -> {:error, name}
      template -> {:ok, template}
    end
  end

  def resolve(%{"template" => name} = policy) do
    with {:ok, template} <- resolve(name) do
      extra = Map.delete(policy, "template")

      {:ok,
       Map.merge(template, extra, fn _class, a, b -> Enum.uniq(List.wrap(a) ++ List.wrap(b)) end)}
    end
  end

  def resolve(%{} = policy), do: {:ok, policy}
  def resolve(other), do: {:error, inspect(other)}
end
