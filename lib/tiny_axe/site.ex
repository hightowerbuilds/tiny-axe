defmodule TinyAxe.Site do
  @moduledoc """
  tiny-axe's website (`docs/plan-lobsterattack.md`) as an MCP server: every
  chat, on the user's own page of the site, searchable, for them (and whoever
  they let in) to see after signing in. It's connected under the reserved
  name `site`, over HTTP to `<site>/api/mcp`, with the account's key from the
  keyring (`TinyAxe.Account`); so it's there once there's an account.

  Agents reach it through the gate like any other server. Its read tools
  (`chat_search`, `chat_read`, `site_link`) only read the user's own page,
  so they run without asking. `chat_push` and `signin_link` are hidden from
  agents: only tiny-axe's own code sends chats (`TinyAxe.Sync`) and opens
  the site signed in (`open_in_browser/1`, for `/site` and the agent's
  `site_open`).

  `config :tiny_axe, :site`: `enabled: false` leaves it unconnected;
  `opener` is how a link is opened in the user's browser (`xdg-open` by
  default; `false` never opens one, as in tests; tests may give a function).
  """

  alias TinyAxe.{Account, MCP}

  @name "site"
  @read ["chat_search", "chat_read", "site_link"]
  @hidden ["chat_push", "signin_link"]

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
  The link to the user's chats on the site, or to one chat (its id). Never
  opens a browser.
  """
  @spec open(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def open(chat \\ nil) do
    with {:ok, text} <- call("site_link", args(chat), 30_000), do: url(text)
  end

  @doc """
  Opens the user's chats on the site (or one chat) in their own browser,
  already signed in: the site gives a one-time sign-in link (`signin_link`;
  the token is in its #fragment, used once by the page), which is handed to
  the browser and nothing else. `{:ok, link}` with the plain link (no
  token), or why not.
  """
  @spec open_in_browser(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def open_in_browser(chat \\ nil) do
    args = args(chat)

    with {:ok, opener} <- opener(),
         {:ok, text} <- call("signin_link", args, 30_000),
         {:ok, link} <- url(text),
         :ok <- launch(opener, link) do
      {:ok, link |> String.split("#", parts: 2) |> hd()}
    end
  end

  defp args(chat) when chat in [nil, ""], do: %{}
  defp args(chat), do: %{"chat" => chat}

  # A function (tests), or a command: on a desktop with xdg-open.
  defp opener do
    case settings()[:opener] do
      fun when is_function(fun, 1) ->
        {:ok, fun}

      false ->
        {:error, "opening the browser is switched off"}

      _ ->
        exe = System.find_executable("xdg-open")

        cond do
          System.get_env("DISPLAY") in [nil, ""] and
              System.get_env("WAYLAND_DISPLAY") in [nil, ""] ->
            {:error, "there's no desktop here to open a browser on"}

          exe == nil ->
            {:error, "xdg-open isn't installed, so tiny-axe can't open your browser"}

          true ->
            {:ok, exe}
        end
    end
  end

  defp launch(fun, link) when is_function(fun, 1), do: fun.(link)

  # In the background, its output nowhere, so a browser that stays open
  # doesn't hold anything up.
  defp launch(exe, link) do
    case System.cmd("sh", ["-c", ~s("$0" "$1" >/dev/null 2>&1 &), exe, link],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, status} -> {:error, "couldn't open the browser (#{status}: #{String.trim(out)})"}
    end
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

  defp settings, do: Application.get_env(:tiny_axe, :site, [])
end
