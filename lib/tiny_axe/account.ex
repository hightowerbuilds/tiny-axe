defmodule TinyAxe.Account do
  @moduledoc """
  The user's tiny-axe account on its website (tiny-axe's home,
  `docs/plan-lobsterattack.md`): made the first time tiny-axe opens
  (`TinyAxe.TUI.AccountFlow`), and the identity everything sent to the site
  belongs to.

  What's kept where:

    * **The username and site** — `<state_dir>/account.json`. Not secret.
    * **tiny-axe's key** — the keyring (`secret-tool`, `service tiny-axe key
      site`). The site returns it once, when the account is made or signed in
      from a new install; it's what tiny-axe sends to `<site>/api/mcp`.
    * **The password** — nowhere. It's typed into this process a keystroke at
      a time (like a card into `TinyAxe.Cards`), sent to the site over HTTPS
      to make or sign in to the account, and forgotten. The TUI only ever
      holds dots; no model sees it.

  The model helps with the username only (`suggest/2`): it proposes names,
  and the site says which are free.

  `config :tiny_axe, :site`: `url` (`TINY_AXE_SITE_URL` overrides it),
  `required` (whether tiny-axe opens with the account step until there is
  one) and `req_options` (tests).
  """

  use GenServer

  require Logger

  @username ~r/\A[a-z0-9][a-z0-9._-]{1,31}\z/
  @min_password 12
  @max_password 72
  @keyring_key "site"

  # Free-text from the user goes in; a few names come back, in a fixed shape.
  @suggest_schema %{
    type: "object",
    properties: %{usernames: %{type: "array", items: %{type: "string"}}},
    required: ["usernames"]
  }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  ## Where things are

  @doc "The site's address, without a trailing slash."
  @spec site_url() :: String.t()
  def site_url do
    (System.get_env("TINY_AXE_SITE_URL") || settings()[:url] || "https://www.lobsterattack.yachts")
    |> String.trim_trailing("/")
  end

  @doc "Whether tiny-axe opens with the account step until there's an account."
  def required?, do: settings()[:required] == true

  @doc "The account on this computer, or nil: a username with a key for it."
  @spec current() :: %{username: String.t(), site: String.t()} | nil
  def current do
    with {:ok, text} <- File.read(path()),
         {:ok, %{"username" => username, "site" => site}} <- JSON.decode(text),
         {:ok, _key} <- key() do
      %{username: username, site: site}
    else
      _ -> nil
    end
  end

  @doc "tiny-axe's key for the site, from the keyring."
  @spec key() :: {:ok, String.t()} | :error
  def key do
    tool = Application.get_env(:tiny_axe, :secret_tool, "secret-tool")

    with path when path != nil <- System.find_executable(tool),
         {secret, 0} <-
           System.cmd(path, ["lookup", "service", "tiny-axe", "key", @keyring_key],
             stderr_to_stdout: true
           ),
         secret when secret != "" <- String.trim_trailing(secret, "\n") do
      {:ok, secret}
    else
      _ -> :error
    end
  end

  def path, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "account.json")

  ## Usernames

  @doc "A username as the site keeps it: trimmed, lowercase."
  def normalize(name), do: name |> String.trim() |> String.downcase()

  @doc "Whether `name` (normalized) is a username at all."
  def valid?(name), do: Regex.match?(@username, normalize(name))

  @doc "Asks the site whether a username is free."
  @spec check(String.t()) :: :available | :taken | {:invalid, String.t()} | {:error, String.t()}
  def check(name) do
    name = normalize(name)

    if valid?(name) do
      case Req.get(req(), url: "/api/username", params: [name: name]) do
        {:ok, %{status: 200, body: %{"available" => true}}} -> :available
        {:ok, %{status: 200, body: %{"reason" => "taken"}}} -> :taken
        {:ok, %{status: 200, body: %{"reason" => reason}}} -> {:invalid, reason}
        other -> {:error, unreachable(other)}
      end
    else
      {:invalid, rule()}
    end
  end

  def rule, do: ~s(2–32 letters, digits, ".", "_" or "-", starting with a letter or digit)

  @doc """
  Usernames the model suggests from what the user said about themselves (a
  name, a nickname, or a username that was taken), checked with the site:
  only free ones come back, at most three.
  """
  @spec suggest(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def suggest(about, opts \\ []) do
    messages = [
      %{
        role: "system",
        content:
          "You suggest usernames for a website account. A username is 2 to 32 characters: " <>
            "lowercase letters, digits, \".\", \"_\" or \"-\", starting with a letter or digit, " <>
            "no spaces. Suggest 6 short, friendly usernames based on what the person says. " <>
            "Answer with JSON: {\"usernames\": [...]}."
      },
      %{role: "user", content: String.slice(about, 0, 200)}
    ]

    chat = Keyword.get(opts, :chat, &TinyAxe.Ollama.chat/2)

    with {:ok, %{"message" => %{"content" => content}}} <-
           chat.(messages, format: @suggest_schema, options: [temperature: 0.7]),
         {:ok, %{"usernames" => names}} when is_list(names) <- JSON.decode(content) do
      free =
        names
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&normalize/1)
        |> Enum.filter(&valid?/1)
        |> Enum.uniq()
        |> Enum.take(6)
        |> Task.async_stream(&{&1, check(&1)}, timeout: 15_000, on_timeout: :kill_task)
        |> Enum.flat_map(fn
          {:ok, {name, :available}} -> [name]
          _ -> []
        end)
        |> Enum.take(3)

      {:ok, free}
    else
      {:error, reason} -> {:error, "the model couldn't suggest names (#{inspect(reason)})"}
      _ -> {:error, "the model's suggestions didn't make sense"}
    end
  end

  ## The password, typed in here

  @doc "Forgets anything typed, and starts again."
  def start_entry, do: GenServer.call(__MODULE__, :start_entry)
  def discard_entry, do: GenServer.call(__MODULE__, :start_entry)

  @doc "One key of the password (`:password`) or its repeat (`:again`)."
  def entry_key(field, key) when field in [:password, :again],
    do: GenServer.call(__MODULE__, {:entry_key, field, key})

  @doc "A pasted password (or repeat), as if typed."
  def entry_paste(field, text) when field in [:password, :again],
    do: GenServer.call(__MODULE__, {:entry_paste, field, text})

  @doc "How many characters have been typed into a field: all the TUI may know."
  def entry_length(field), do: GenServer.call(__MODULE__, {:entry_length, field})

  @doc "Why the password won't do, or nil. With `:again`, also whether they match."
  def entry_problem(field), do: GenServer.call(__MODULE__, {:entry_problem, field})

  @doc """
  Makes the account with the password typed in, keeps the key and the
  username, and forgets the password. `label` names this install on the site.
  """
  @spec create(String.t(), String.t()) ::
          {:ok, String.t()} | {:taken, String.t()} | {:error, String.t()}
  def create(username, label \\ default_label()),
    do: GenServer.call(__MODULE__, {:send, "/api/signup", normalize(username), label}, 30_000)

  @doc "Signs in to an existing account from this install (a new key for it)."
  @spec sign_in(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def sign_in(username, label \\ default_label()),
    do: GenServer.call(__MODULE__, {:send, "/api/device", normalize(username), label}, 30_000)

  def default_label do
    {:ok, host} = :inet.gethostname()
    "tiny-axe on #{host}"
  end

  ## Server

  @impl true
  def init(:ok), do: {:ok, blank()}

  # Never in a crash report or :sys.get_state.
  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)

  @impl true
  def handle_call(:start_entry, _from, _s), do: {:reply, :ok, blank()}

  def handle_call({:entry_key, field, key}, _from, s) do
    value =
      case key do
        "backspace" -> String.slice(s[field], 0..-2//1)
        <<_::utf8>> = char -> s[field] <> char
        _ -> s[field]
      end

    {:reply, :ok, %{s | field => value}}
  end

  def handle_call({:entry_paste, field, text}, _from, s),
    do: {:reply, :ok, %{s | field => s[field] <> String.replace(text, ~r/[\r\n]/, "")}}

  def handle_call({:entry_length, field}, _from, s), do: {:reply, String.length(s[field]), s}

  def handle_call({:entry_problem, :password}, _from, s),
    do: {:reply, password_problem(s.password), s}

  def handle_call({:entry_problem, :again}, _from, s) do
    problem =
      password_problem(s.password) ||
        if(s.again != s.password, do: "The two passwords don't match.")

    {:reply, problem, s}
  end

  def handle_call({:send, path, username, label}, _from, s) do
    problem = if path == "/api/signup", do: password_problem(s.password), else: nil

    reply =
      cond do
        problem -> {:error, problem}
        not valid?(username) -> {:error, "A username is #{rule()}."}
        true -> send_credentials(path, username, s.password, label)
      end

    # Gone once it's been used, whatever happened; a retry types it again.
    {:reply, reply, blank()}
  end

  defp blank, do: %{password: "", again: ""}

  defp password_problem(password) do
    cond do
      String.length(password) < @min_password ->
        "A password needs at least #{@min_password} characters."

      byte_size(password) > @max_password ->
        "A password can be at most #{@max_password} bytes."

      true ->
        nil
    end
  end

  defp send_credentials(path, username, password, label) do
    body = %{username: username, password: password, label: label}

    case Req.post(req(), url: path, json: body) do
      {:ok, %{status: 201, body: %{"username" => name, "key" => key}}} when is_binary(key) ->
        case keep(name, key) do
          :ok ->
            {:ok, name}

          {:error, reason} ->
            {:error, "the account is made, but its key couldn't be kept: #{reason}"}
        end

      {:ok, %{status: 409, body: %{"error" => message}}} ->
        {:taken, message}

      {:ok, %{status: status, body: %{"error" => message}}} when status in 400..499 ->
        {:error, message}

      other ->
        {:error, unreachable(other)}
    end
  end

  # The key into the keyring first, then the file that says there's an account.
  defp keep(username, key) do
    with :ok <- keyring_store(key) do
      File.mkdir_p!(Path.dirname(path()))
      tmp = path() <> ".tmp"
      File.write!(tmp, JSON.encode!(%{username: username, site: site_url()}))
      File.chmod!(tmp, 0o600)
      File.rename!(tmp, path())
      :ok
    end
  end

  # As TinyAxe.Cards does: the secret through the environment of a process
  # that ends at once, never on a command line or in a file.
  defp keyring_store(secret) do
    tool = Application.get_env(:tiny_axe, :secret_tool, "secret-tool")

    case System.find_executable(tool) do
      nil ->
        {:error, "secret-tool isn't installed"}

      exe ->
        {out, status} =
          System.cmd(
            "sh",
            [
              "-c",
              ~s(printf '%s' "$TINY_AXE_SECRET" | exec "$0" store --label="$1" service tiny-axe key "$2"),
              exe,
              "tiny-axe site key",
              @keyring_key
            ],
            env: [{"TINY_AXE_SECRET", secret}],
            stderr_to_stdout: true
          )

        if status == 0, do: :ok, else: {:error, String.trim(out)}
    end
  end

  defp unreachable({:ok, %{status: 429}}), do: "the site says to slow down; try again in a while"
  defp unreachable({:ok, %{status: status}}), do: "the site answered #{status}"

  defp unreachable({:error, %{reason: reason}}),
    do: "couldn't reach #{site_url()} (#{inspect(reason)})"

  defp unreachable({:error, reason}), do: "couldn't reach #{site_url()} (#{inspect(reason)})"

  defp req do
    Req.new(
      [
        base_url: site_url(),
        retry: false,
        receive_timeout: 20_000,
        connect_options: [timeout: 10_000]
      ] ++
        (settings()[:req_options] || [])
    )
  end

  defp settings, do: Application.get_env(:tiny_axe, :site, [])
end
