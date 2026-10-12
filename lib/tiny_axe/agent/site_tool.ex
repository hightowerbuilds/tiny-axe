defmodule TinyAxe.Agent.SiteTool do
  @moduledoc """
  `site_open`, the gate's own tool for showing the user their chats on
  tiny-axe's website: it opens in the user's own browser, already signed in
  (`TinyAxe.Site.open_in_browser/1`). Offered to agent tasks that have the
  site (`site`) among their servers.

  It's `:local`: it opens a window on this computer for the user, and what it
  fetches is a one-time sign-in link to the user's own page, which goes to
  their browser and nowhere else (never to the model: the result is the plain
  link). So it runs without asking.
  """

  alias TinyAxe.Site

  @name "site_open"

  def name, do: @name

  @doc "Whether a task gets the tool: the site is one of its servers (`:all`: it's connected)."
  def offered?(:all), do: Site.running?()
  def offered?(servers) when is_list(servers), do: Site.name() in servers
  def offered?(_servers), do: false

  @doc "The tool's MCP definition."
  def definition do
    %{
      "name" => @name,
      "description" =>
        "Open the user's chats on tiny-axe's website in their own browser, already signed in " <>
          "as them: all of them, or one (`chat`, its id from site__chat_search). Use it when " <>
          "they want to see or go to the site. You never see or type a password; this needs none.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "chat" => %{"type" => "string", "description" => "A chat's id, to open that chat."}
        },
        "required" => []
      },
      "annotations" => %{"readOnlyHint" => true, "openWorldHint" => false}
    }
  end

  @doc "Opens it; an MCP result."
  def run(args) do
    case Site.open_in_browser(args["chat"]) do
      {:ok, link} ->
        text("Opened #{link} in the user's browser, signed in. They can see it now.")

      {:error, why} ->
        Map.put(
          text("Couldn't open it (#{why}). Give them the link from site__site_link instead."),
          "isError",
          true
        )
    end
  end

  defp text(t), do: %{"content" => [%{"type" => "text", "text" => t}], "isError" => false}
end
