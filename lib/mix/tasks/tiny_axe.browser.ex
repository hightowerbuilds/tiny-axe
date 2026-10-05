defmodule Mix.Tasks.TinyAxe.Browser do
  @shortdoc "Open tiny-axe's browser to log into a site or save a card there"
  @moduledoc """
  Opens tiny-axe's own browser (its own profile, not your everyday one) in a
  window, so you can log into a shop, save a card or an address there, and
  have the agent find you logged in later. Nothing is automated: it's you,
  in the window. Close tiny-axe first, since only one copy can use the profile.

      mix tiny_axe.browser https://www.example-shop.com
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    url = List.first(args)

    case TinyAxe.Browser.start(headless: false) do
      {:ok, _} ->
        if url,
          do: TinyAxe.MCP.call(TinyAxe.Browser.name(), "browser_navigate", %{url: url}, 60_000)

        TinyAxe.Browser.show()

        IO.gets(
          "The browser is open. Log in, save what you need, then press enter here to close it. "
        )

        TinyAxe.MCP.stop_server(TinyAxe.Browser.name())

      {:error, reason} ->
        Mix.raise("couldn't open the browser: #{inspect(reason)}")
    end
  end
end
