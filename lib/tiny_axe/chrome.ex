defmodule TinyAxe.Chrome do
  @moduledoc """
  Claude in Chrome: the user's own Chrome, with the shops and sites they're
  signed in to, driven by Claude (`claude -p --chrome`) through tiny-axe's
  gate (`docs/plan-chrome-purchases.md`).

  Claude Code holds the browser, so tiny-axe can't read pages or click on its
  own. Instead it hears about every Chrome call before it runs (Claude Code's
  permission question, answered by the gate's `chrome_permission` tool) and
  sees every result after (a `PostToolUse` hook posting to the gate). This
  module is the rules for both, with no state of its own:

    * `classify/3`: a call is `:read` (runs), `:act` (runs on a site the user
      allowed for the task, else asks), `:commit` (a click or key that places
      an order: held) or `:refused`;
    * `observe/4`: what a result shows (each tab's address, each ref's label,
      a page's text), kept on the gate task as `seen`.

  On or off: `/chrome on|off` in the TUI (`set_on/1`, kept in
  `<state_dir>/chrome.json`), or `config :tiny_axe, :chrome, enabled: true`.
  Off by default. Only Claude drives Chrome.
  """

  alias TinyAxe.Tools.{BrowserPolicy, Redact}

  @prefix "mcp__claude-in-chrome__"

  # Looking: nothing on a page changes.
  @reads ~w(tabs_context_mcp read_page get_page_text find read_console_messages
            read_network_requests list_connected_browsers shortcuts_list resize_window
            tabs_create_mcp tabs_close_mcp select_browser switch_browser gif_creator)

  # Doing things the gate can't see into, or with the user's files.
  @refused %{
    "browser_batch" => "batches hide their actions from tiny-axe: make one call at a time",
    "javascript_tool" => "running scripts on the user's pages isn't allowed",
    "shortcuts_execute" => "running the user's saved shortcuts isn't allowed",
    "file_upload" => "uploading the user's files isn't allowed",
    "upload_image" => "uploading images isn't allowed"
  }

  @computer_reads ~w(screenshot scroll scroll_to zoom hover wait)

  # On a checkout, these words on a button may place the order too.
  @checkout_button ~r/\b(submit|continue|confirm|complete|finish|proceed)\b/i

  # A page that's a checkout: what it says, not what it's called.
  @checkout ~r/\b(order total|total due|amount due|place (your )?order|pay now|review your order|complete (your )?(order|purchase))\b/i

  @type class :: :read | :act | :commit | :refused
  @type seen :: %{tabs: %{integer() => String.t()}, labels: map(), pages: map()}

  ## On or off

  @doc "Whether agent runs driven by Claude get the user's Chrome."
  def on?, do: Keyword.get(settings(), :enabled, false) or file_on?()

  defp settings, do: Application.get_env(:tiny_axe, :chrome, [])

  defp file_on? do
    with {:ok, text} <- File.read(path()),
         {:ok, %{"on" => true}} <- JSON.decode(text) do
      true
    else
      _ -> false
    end
  end

  @doc "Remembers `/chrome on` or `off`."
  @spec set_on(boolean()) :: :ok | {:error, term()}
  def set_on(on) when is_boolean(on) do
    with :ok <- File.mkdir_p(Path.dirname(path())),
         do: File.write(path(), JSON.encode!(%{on: on}))
  end

  def path, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "chrome.json")

  @doc "Whether a tool name is one of Claude in Chrome's."
  def tool?(name) when is_binary(name), do: String.starts_with?(name, @prefix)
  def tool?(_name), do: false

  @doc "A Claude in Chrome tool's short name (`navigate`)."
  def short(name), do: String.replace_prefix(name, @prefix, "")

  ## What the gate has seen

  @doc "Nothing seen yet."
  @spec new() :: seen()
  def new, do: %{tabs: %{}, labels: %{}, pages: %{}}

  @doc """
  Takes in a result the hook passed on: `tool_name`, `tool_input` and
  `tool_response` (a list of text parts, or text). Each result's Tab Context
  gives every tab's address; `find` and `read_page` give refs with their
  labels; `get_page_text` gives a page's address and text.
  """
  @spec observe(seen(), String.t(), map(), term()) :: seen()
  def observe(seen, tool, input, response) do
    text = text(response)
    tab = tab_of(input, text)
    seen = %{seen | tabs: Map.merge(seen.tabs, tabs(text))}

    case short(tool) do
      name when name in ["find", "read_page"] and tab != nil ->
        labels = for {ref, label} <- refs(text), into: %{}, do: {{tab, ref}, label}
        %{seen | labels: Map.merge(seen.labels, labels)}

      "get_page_text" when tab != nil ->
        page = %{url: page_url(text), text: String.slice(text, 0, 50_000)}
        %{seen | pages: Map.put(seen.pages, tab, page)}

      # The page changed under these refs: what they named is gone.
      name when name in ["navigate"] and tab != nil ->
        %{seen | labels: drop_tab(seen.labels, tab), pages: Map.delete(seen.pages, tab)}

      _ ->
        seen
    end
  end

  defp text(parts) when is_list(parts),
    do:
      Enum.map_join(parts, "\n", fn p -> if is_map(p), do: p["text"] || "", else: to_string(p) end)

  defp text(text) when is_binary(text), do: text
  defp text(other), do: inspect(other)

  defp tab_of(%{"tabId" => tab}, _text) when is_integer(tab), do: tab

  defp tab_of(_input, text) do
    case Regex.run(~r/Executed on tabId: (\d+)/, text) do
      [_, tab] -> String.to_integer(tab)
      _ -> nil
    end
  end

  # "• tabId 123: "Title" ("https://…")"
  defp tabs(text) do
    for [_, tab, url] <- Regex.scan(~r/tabId (\d+): ".*?" \("([^"]*)"\)/, text),
        into: %{},
        do: {String.to_integer(tab), url}
  end

  # "- ref_16: button ""Place order"" (button) …" and the like: the first quoted
  # words on a ref's line are its label.
  defp refs(text) do
    for line <- String.split(text, "\n"),
        [_, ref] <- [Regex.run(~r/\b(ref_\d+)\b/, line)],
        [_, label] <- [Regex.run(~r/"+([^"]+)"+/, line)],
        do: {ref, String.trim(label)}
  end

  defp page_url(text) do
    case Regex.run(~r/^URL: (\S+)/m, text) do
      [_, url] -> url
      _ -> nil
    end
  end

  defp drop_tab(labels, tab), do: Map.reject(labels, fn {{t, _ref}, _} -> t == tab end)

  ## Sorting a call

  @doc """
  What a Chrome call is, from its input and what's been seen: `{class,
  reason, host}`. The host is the site it acts on, when there is one.
  """
  @spec classify(seen(), String.t(), map()) :: {class(), String.t(), String.t() | nil}
  def classify(seen, tool, input) do
    name = short(tool)
    host = host(seen, input)

    cond do
      Map.has_key?(@refused, name) -> {:refused, @refused[name], host}
      name in @reads -> {:read, "looks", host}
      name == "navigate" -> navigate(input, host)
      name == "computer" -> computer(seen, input, host)
      name == "form_input" -> typed(input["value"], "fills in a field", host)
      true -> {:act, "#{name}: a Chrome action tiny-axe doesn't know", host}
    end
  end

  defp navigate(%{"url" => url}, host) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: to} when is_binary(to) -> {:act, "opens #{to}", to}
      # "back", "forward": the same tab, somewhere it's been.
      _ -> {:act, "goes #{url}", host}
    end
  end

  defp navigate(_input, host), do: {:act, "navigates", host}

  defp computer(seen, %{"action" => action} = input, host) do
    tab = input["tabId"]
    ref = input["ref"]

    cond do
      action in @computer_reads ->
        {:read, "looks (#{action})", host}

      action == "type" ->
        typed(input["text"], "types", host)

      # Enter can submit a form: only on a page tiny-axe has read, and on a
      # checkout it's held like the button.
      action == "key" and enter?(input["text"]) ->
        cond do
          seen.pages[tab] == nil ->
            {:refused, "read the page first (get_page_text), then press Enter", host}

          checkout?(seen, tab) ->
            {:commit, "presses Enter on a checkout", host}

          true ->
            {:act, "presses Enter", host}
        end

      action == "key" ->
        {:act, "presses #{input["text"]}", host}

      # Every click names its element, so tiny-axe knows what it is: a click
      # by position could be "Place order" without anyone knowing.
      click?(action) and ref != nil ->
        label = seen.labels[{tab, ref}]

        cond do
          label == nil ->
            {:refused,
             "tiny-axe doesn't know #{ref} yet: find it (find or read_page), then click it by its ref",
             host}

          BrowserPolicy.commit_label?(label) ->
            {:commit, ~s(clicks "#{label}"), host}

          checkout?(seen, tab) and label =~ @checkout_button ->
            {:commit, ~s(clicks "#{label}" on a checkout), host}

          true ->
            {:act, ~s(clicks "#{label}"), host}
        end

      click?(action) ->
        {:refused,
         "click by ref, not by position: find the element (find or read_page), then click its ref",
         host}

      true ->
        {:act, action, host}
    end
  end

  defp computer(_seen, _input, host), do: {:act, "uses the mouse or keyboard", host}

  defp click?(action), do: is_binary(action) and String.contains?(action, "click")

  defp enter?(key), do: is_binary(key) and key =~ ~r/^(enter|return|kp_enter)$/i

  # Card numbers never go into the user's Chrome from a model.
  defp typed(value, what, host) when is_binary(value) do
    if Redact.text(value) != value,
      do: {:refused, "that looks like a card number: tiny-axe never types one", host},
      else: {:act, what, host}
  end

  defp typed(_value, what, host), do: {:act, what, host}

  defp checkout?(seen, tab) do
    case seen.pages[tab] do
      %{text: text} -> text =~ @checkout
      _ -> false
    end
  end

  # The site a call acts on: its own URL, else the tab's last known address.
  defp host(seen, input), do: host_of(input["url"]) || host_of(seen.tabs[input["tabId"]])

  defp host_of(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp host_of(_url), do: nil

  ## For the agent

  @doc "What the agent is told about the user's Chrome."
  def instructions do
    """
    You can also use the user's own Chrome (the claude-in-chrome tools), where \
    they're signed in to their shops and sites. Use it when the request needs \
    their accounts, or they ask for their Chrome. tiny-axe checks every Chrome \
    call: make one call at a time (never browser_batch); find a button with \
    find or read_page and click it by its ref (a click by position is refused); read a page with get_page_text before pressing Enter on it; never type card numbers (pick a \
    card the page already shows). Acting on a site the user hasn't allowed for \
    this task waits for their yes. A click that places an order is held by \
    tiny-axe: when it is, do what its message says.\
    """
  end

  @doc "The gate's tool that answers Claude Code's permission questions."
  def permission_definition do
    %{
      "name" => "chrome_permission",
      "description" =>
        "tiny-axe answers Claude Code's permission questions with this (not for the agent to call).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "tool_name" => %{"type" => "string"},
          "input" => %{"type" => "object"},
          "tool_use_id" => %{"type" => "string"}
        },
        "required" => ["tool_name", "input"]
      }
    }
  end
end
