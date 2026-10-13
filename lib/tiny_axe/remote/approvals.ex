defmodule TinyAxe.Remote.Approvals do
  @moduledoc """
  The approval PIN for saying yes from the site's Chat tab
  (`docs/plan-chrome-purchases.md`, P3): someone with the site password can
  read the 🌐 chat, but only someone who knows the PIN can approve.

  - **Setting it** (`/remote pin`, at the machine): typed a keystroke at a
    time into this process, twice, never into the TUI's state or a model.
    6 to 64 printable characters. tiny-axe keeps only
    `H = PBKDF2-SHA256(pin, salt, iterations)`, in the keyring (`service
    tiny-axe key remote-approval`); the salt, the iteration count, whether
    approvals are on and the wrong tries are in
    `<state_dir>/remote-approvals.json`.
  - **Checking an answer:** each approval has its own nonce. The page turns
    the typed PIN into `HMAC-SHA256(H, "id|nonce|approve|total")` and sends
    only that; `verify/1` computes the same and compares in constant time.
    A proof is good for one approval, one decision and one total.
  - **Three wrong PINs** switch approvals off (`:locked`) until they're
    switched on again at the machine (`set_enabled(true)` or a new PIN).

  `status/0`: `:ready`, `:no_pin`, `:off` or `:locked`.
  """

  use GenServer

  @keyring_key "remote-approval"
  @max_failures 3
  @min 6
  @max 64

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Where approvals stand: `:ready`, `:no_pin`, `:off` or `:locked`."
  @spec status() :: :ready | :no_pin | :off | :locked
  def status do
    case read() do
      %{"salt" => salt} = s when is_binary(salt) ->
        cond do
          s["failures"] >= @max_failures -> :locked
          s["enabled"] != true -> :off
          true -> :ready
        end

      _ ->
        :no_pin
    end
  end

  @doc "In words, for `/remote` and the 🌐 chat's refusals."
  def describe(:ready), do: "on (the Chat tab can approve, with your approval PIN)"
  def describe(:no_pin), do: "off: no approval PIN yet (/remote pin sets one)"
  def describe(:off), do: "off (/remote approvals on)"

  def describe(:locked),
    do: "off after #{@max_failures} wrong PINs (/remote approvals on switches them back on)"

  @doc "Switches approvals on (clearing the wrong tries) or off."
  @spec set_enabled(boolean()) :: :ok | {:error, String.t()}
  def set_enabled(on), do: GenServer.call(__MODULE__, {:enabled, on})

  ## Setting the PIN

  @doc "Starts typing a new PIN (anything half typed is dropped)."
  def start_entry, do: GenServer.call(__MODULE__, :start_entry)

  @doc "Drops what's been typed."
  def discard_entry, do: GenServer.call(__MODULE__, :discard_entry)

  @doc "A key for the step being typed (`:first` or `:again`); returns how many characters it has."
  @spec entry_key(String.t()) :: non_neg_integer()
  def entry_key(key), do: GenServer.call(__MODULE__, {:entry_key, key})

  @doc "Ends the first typing: `:ok`, or `{:error, why}` (too short, …)."
  @spec entry_next() :: :ok | {:error, String.t()}
  def entry_next, do: GenServer.call(__MODULE__, :entry_next)

  @doc """
  Ends the second typing: if both match, the PIN is saved (as `H`, in the
  keyring) and approvals are switched on. Either way, what was typed goes.
  """
  @spec entry_finish() :: :ok | {:error, String.t()}
  def entry_finish, do: GenServer.call(__MODULE__, :entry_finish, 30_000)

  ## Approvals

  @doc "What a new approval carries for the page: `nonce`, `salt`, `iterations`."
  @spec challenge() :: {:ok, map()} | {:error, atom()}
  def challenge do
    case {status(), read()} do
      {:ready, s} ->
        {:ok, %{nonce: token(), salt: s["salt"], iterations: s["iterations"]}}

      {other, _} ->
        {:error, other}
    end
  end

  @doc """
  Checks an approval's proof (`%{id, nonce, total, proof}`): `:ok`,
  `{:error, :wrong_pin, tries_left}` (counted; the last wrong one locks
  approvals), or `{:error, status}` when approvals aren't ready.
  """
  @spec verify(map()) :: :ok | {:error, :wrong_pin, non_neg_integer()} | {:error, atom()}
  def verify(answer), do: GenServer.call(__MODULE__, {:verify, answer}, 30_000)

  @doc "The proof for a PIN, as the page makes it (also for tests)."
  def proof_for(pin, salt, iterations, id, nonce, total),
    do: proof(derive(pin, salt, iterations), id, nonce, total)

  ## Server

  @impl true
  def init(:ok), do: {:ok, %{first: "", again: "", step: nil}}

  @impl true
  def handle_call(:start_entry, _from, _s),
    do: {:reply, :ok, %{first: "", again: "", step: :first}}

  def handle_call(:discard_entry, _from, _s),
    do: {:reply, :ok, %{first: "", again: "", step: nil}}

  def handle_call({:entry_key, _key}, _from, %{step: nil} = s), do: {:reply, 0, s}

  def handle_call({:entry_key, key}, _from, %{step: step} = s) do
    typed = Map.fetch!(s, step)

    typed =
      cond do
        key == "backspace" -> String.slice(typed, 0..-2//1)
        printable?(key) and String.length(typed) < @max -> typed <> key
        true -> typed
      end

    {:reply, String.length(typed), Map.put(s, step, typed)}
  end

  def handle_call(:entry_next, _from, %{step: :first, first: first} = s) do
    if String.length(first) >= @min,
      do: {:reply, :ok, %{s | step: :again}},
      else: {:reply, {:error, "at least #{@min} characters"}, %{s | first: ""}}
  end

  def handle_call(:entry_next, _from, s), do: {:reply, {:error, "nothing being typed"}, s}

  def handle_call(:entry_finish, _from, %{step: :again, first: first, again: again}) do
    cleared = %{first: "", again: "", step: nil}

    if Plug.Crypto.secure_compare(first, again) do
      salt = token()
      iterations = iterations()
      h = derive(first, salt, iterations)

      reply =
        with :ok <- keyring_store(Base.encode16(h, case: :lower)) do
          write(%{"enabled" => true, "salt" => salt, "iterations" => iterations, "failures" => 0})
        end

      {:reply, reply, cleared}
    else
      {:reply, {:error, "the two didn't match"}, cleared}
    end
  end

  def handle_call(:entry_finish, _from, s), do: {:reply, {:error, "nothing being typed"}, s}

  def handle_call({:enabled, on}, _from, s) do
    reply =
      case read() do
        %{"salt" => _} = saved ->
          write(
            %{saved | "enabled" => on}
            |> then(&if(on, do: %{&1 | "failures" => 0}, else: &1))
          )

        _ ->
          if on, do: {:error, "set an approval PIN first (/remote pin)"}, else: :ok
      end

    {:reply, reply, s}
  end

  def handle_call({:verify, answer}, _from, s) do
    with :ready <- status(),
         saved = read(),
         {:ok, hex} <- keyring_lookup(),
         {:ok, h} <- Base.decode16(hex, case: :lower) do
      expected = proof(h, answer.id, answer.nonce, answer.total || "")

      if is_binary(answer.proof) and Plug.Crypto.secure_compare(expected, answer.proof) do
        write(%{saved | "failures" => 0})
        {:reply, :ok, s}
      else
        failures = saved["failures"] + 1
        write(%{saved | "failures" => failures})
        {:reply, {:error, :wrong_pin, max(@max_failures - failures, 0)}, s}
      end
    else
      status when is_atom(status) -> {:reply, {:error, status}, s}
      _ -> {:reply, {:error, :no_pin}, s}
    end
  end

  ## Crypto

  defp derive(pin, salt, iterations), do: :crypto.pbkdf2_hmac(:sha256, pin, salt, iterations, 32)

  defp proof(h, id, nonce, total),
    do:
      :crypto.mac(:hmac, :sha256, h, "#{id}|#{nonce}|approve|#{total}")
      |> Base.encode16(case: :lower)

  defp token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

  defp iterations,
    do: Application.get_env(:tiny_axe, :remote_approvals, [])[:iterations] || 600_000

  defp printable?(key), do: String.length(key) == 1 and key =~ ~r/\A[\x20-\x7E]\z/

  ## Files

  def path, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "remote-approvals.json")

  defp read do
    with {:ok, text} <- File.read(path()),
         {:ok, %{} = saved} <- JSON.decode(text),
         do: saved,
         else: (_ -> nil)
  end

  defp write(saved) do
    File.mkdir_p!(Path.dirname(path()))
    tmp = path() <> ".tmp"
    File.write!(tmp, JSON.encode!(saved))
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path())
    :ok
  end

  ## The keyring

  # In through an environment variable of a process that ends at once, never
  # on a command line (as TinyAxe.Cards does).
  defp keyring_store(secret) do
    tool = Application.get_env(:tiny_axe, :secret_tool, "secret-tool")

    case System.find_executable(tool) do
      nil ->
        {:error, "secret-tool isn't installed"}

      path ->
        {out, status} =
          System.cmd(
            "sh",
            [
              "-c",
              ~s(printf '%s' "$TINY_AXE_SECRET" | exec "$0" store --label="$1" service tiny-axe key "$2"),
              path,
              "tiny-axe remote approval PIN",
              @keyring_key
            ],
            env: [{"TINY_AXE_SECRET", secret}],
            stderr_to_stdout: true
          )

        if status == 0,
          do: :ok,
          else: {:error, "couldn't save it in the keyring: #{String.trim(out)}"}
    end
  end

  defp keyring_lookup do
    tool = Application.get_env(:tiny_axe, :secret_tool, "secret-tool")

    with path when path != nil <- System.find_executable(tool),
         {secret, 0} <-
           System.cmd(path, ["lookup", "service", "tiny-axe", "key", @keyring_key],
             stderr_to_stdout: true
           ),
         secret when secret != "" <- String.trim(secret) do
      {:ok, secret}
    else
      _ -> :error
    end
  end
end
