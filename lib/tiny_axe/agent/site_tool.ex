defmodule TinyAxe.Agent.SiteTool do
  @moduledoc """
  `site_open`, the gate's own tool for showing the user their page of
  tiny-axe's website: it opens in the user's own browser, already signed in
  (`TinyAxe.Graph.open_in_browser/2`). Offered to agent tasks that have the
  site (`graph`) among their servers.

  It's `:local`: it opens a window on this computer for the user, and what it
  fetches is a one-time sign-in link to the user's own page, which goes to
  their browser and nowhere else (never to the model: the result is the plain
  link). So it runs without asking.
  """

  alias TinyAxe.Graph

  @name "site_open"

  def name, do: @name

  @doc "Whether a task gets the tool: the site is one of its servers (`:all`: it's connected)."
  def offered?(:all), do: Graph.running?()
  def offered?(servers) when is_list(servers), do: Graph.name() in servers
  def offered?(_servers), do: false

  @doc "The tool's MCP definition."
  def definition do
    %{
      "name" => @name,
      "description" =>
        "Open the user's page of tiny-axe's website in their own browser, already signed in " <>
          "as them: the know-how graph, one note (`focus`, a note id), or their chats " <>
          "(`page: \"chats\"`). Use it when they want to see or go to the site. You never see " <>
          "or type a password; this needs none.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "focus" => %{"type" => "string", "description" => "A note's id, to open that note."},
          "page" => %{"type" => "string", "enum" => ["graph", "chats"]}
        },
        "required" => []
      },
      "annotations" => %{"readOnlyHint" => true, "openWorldHint" => false}
    }
  end

  @doc "Opens it; an MCP result."
  def run(args) do
    page = if args["page"] == "chats", do: "chats"

    case Graph.open_in_browser(args["focus"], page: page) do
      {:ok, link} ->
        text("Opened #{link} in the user's browser, signed in. They can see it now.")

      {:error, why} ->
        Map.put(
          text("Couldn't open it (#{why}). Give them the link from graph__graph_link instead."),
          "isError",
          true
        )
    end
  end

  defp text(t), do: %{"content" => [%{"type" => "text", "text" => t}], "isError" => false}
end
