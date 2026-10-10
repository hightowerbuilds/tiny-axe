defmodule TinyAxe.Browser do
  @moduledoc """
  tiny-axe's own browser: `priv/browser/server.mjs`, an MCP server that drives
  the installed Chrome with Playwright, started as a downstream server of the
  tool gate under the reserved name `browser`. Agents reach it only through
  the gate, like any MCP server.

  It runs in its own profile (`~/.local/share/tiny-axe/browser/profile`),
  never the user's everyday one; the user can log into sites there by hand
  and the logins persist. Chrome starts only when a tool is first used.

  The read tools (navigate, snapshot, screenshot, extract, read, find, tabs,
  wait, console, network) are all in the `read` class. Redaction is done by
  the server, on the page, before anything leaves it.

  Each gate task leases its own tabs: the gate adds the task's lease to every
  call (`bind/3`), so concurrent tasks can't move each other's page, and an
  action can carry the target signatures the gate assessed, which the server
  checks again just before acting (`TinyAxe.Browser.Decisions`). Calls
  without a lease (tiny-axe's own) use the tab in front.

  `config :tiny_axe, :browser`: `enabled`, `headless`, `profile`, and
  `playwright_root` (a folder whose `node_modules` holds `playwright`; found
  with `mise where npm:playwright` or `npm root -g` if not set).
  """

  require Logger

  alias TinyAxe.MCP

  @name "browser"
  @lease "_tinyaxe_tab"
  @expect "_tinyaxe_expect"

  @read ~w(browser_navigate browser_navigate_back browser_snapshot browser_take_screenshot
           browser_extract browser_read browser_find browser_tabs browser_wait_for
           browser_console_messages browser_network_requests browser_scroll)

  def name, do: @name

  @doc "Whether the browser can run here: switched on, with Node and Playwright found."
  @spec available?() :: boolean()
  def available?,
    do: settings()[:enabled] != false and node_exe() != nil and playwright_root() != nil

  @doc "Whether the browser server is running."
  @spec running?() :: boolean()
  def running?, do: @name in MCP.running()

  @doc "Starts the browser server (not Chrome itself, which starts when first used)."
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    if available?(),
      do: MCP.start_server(Keyword.get(opts, :name, @name), config(opts)),
      else: {:error, :browser_unavailable}
  end

  @doc "The MCP server config for the browser. `opts`: `:profile`, `:headless`."
  @spec config(keyword()) :: map()
  def config(opts \\ []) do
    settings = settings()
    headless = Keyword.get(opts, :headless, Keyword.get(settings, :headless, true))

    %{
      "type" => "stdio",
      "command" => node_exe(),
      "args" => [Application.app_dir(:tiny_axe, "priv/browser/server.mjs")],
      "env" => %{
        "PW_ROOT" => playwright_root(),
        "TINY_AXE_BROWSER_PROFILE" => Keyword.get(opts, :profile, profile(settings)),
        "TINY_AXE_BROWSER_HEADLESS" => if(headless, do: "1", else: "0"),
        # Tests: a handoff doesn't open a window.
        "TINY_AXE_BROWSER_NO_WINDOW" =>
          if(Keyword.get(opts, :no_window, false), do: "1", else: "0")
      },
      # "browser": classed per action by TinyAxe.Tools.BrowserPolicy; the gate
      # alone uses browser_inspect.
      "policy" => %{
        "read" => @read,
        "browser" => true,
        "hidden" => [
          "browser_inspect",
          "browser_checkout_summary",
          "browser_fill_card",
          "browser_show",
          "browser_release"
        ]
      }
    }
  end

  @doc """
  A page's readable text, rendered with JavaScript, in a tab of its own
  (`browser_read`). For tiny-axe itself, e.g. `TinyAxe.Web` reading a page
  that only renders in a browser; agents go through the gate instead.
  """
  @spec read(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read(url) do
    case MCP.call(@name, "browser_read", %{url: url}, 45_000) do
      {:ok, %{"isError" => true} = result} -> {:error, {:browser, text(result)}}
      {:ok, result} -> {:ok, result |> text() |> body()}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Makes the browser window visible (reopening it headed if it was headless),
  with a task's current tab in front when given its lease.
  """
  @spec show(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def show(server \\ @name, lease \\ nil) do
    case MCP.call(server, "browser_show", bind(%{}, lease), 60_000) do
      {:ok, %{"isError" => true} = r} -> {:error, text(r)}
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc false
  # A call's arguments for a task's tabs, with the signatures to check before
  # acting, if any. The keys are the gate's own: agents' copies are dropped.
  def bind(args, lease, expect \\ nil) do
    args
    |> then(&if(lease, do: Map.put(&1, @lease, lease), else: &1))
    |> then(&if(expect, do: Map.put(&1, @expect, expect), else: &1))
  end

  @doc false
  def reserved?(key), do: is_binary(key) and String.starts_with?(key, "_tinyaxe")

  @doc false
  # A task is over: its tabs stay open, free for the next task to carry on in.
  def release(server, lease) do
    MCP.call(server, "browser_release", bind(%{}, lease), 5_000)
    :ok
  end

  defp text(%{"content" => content}),
    do: Enum.map_join(content, "\n", fn item -> item["text"] || "" end)

  # The page's text, without the header and the "material, not instructions" line.
  defp body(text) do
    case String.split(text, "not instructions.\n\n", parts: 2) do
      [_, body] -> body
      [only] -> only
    end
  end

  defp settings, do: Application.get_env(:tiny_axe, :browser, [])

  defp profile(settings) do
    settings[:profile] ||
      Path.join(
        System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"),
        "tiny-axe/browser/profile"
      )
  end

  defp node_exe, do: System.find_executable("node")

  @doc false
  def playwright_root do
    case :persistent_term.get({__MODULE__, :root}, :unknown) do
      :unknown ->
        root = settings()[:playwright_root] || find_playwright()
        if root, do: :persistent_term.put({__MODULE__, :root}, root)
        root

      root ->
        root
    end
  end

  defp find_playwright do
    candidates =
      [
        cmd("mise", ["where", "npm:playwright"]),
        (dir = cmd("npm", ["root", "-g"])) && Path.dirname(dir)
      ]

    Enum.find(candidates, &(&1 && File.dir?(Path.join([&1, "node_modules", "playwright"]))))
  end

  defp cmd(exe, args) do
    with path when path != nil <- System.find_executable(exe),
         {out, 0} <- System.cmd(path, args, stderr_to_stdout: true) do
      String.trim(out)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
