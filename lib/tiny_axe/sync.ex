defmodule TinyAxe.Sync do
  @moduledoc """
  Sends the chat history (`TinyAxe.History`) to the user's page of
  tiny-axe's website (`TinyAxe.Site`, `docs/plan-lobsterattack.md`), as it
  changes.

  What has gone up is recorded in `<state_dir>/site-sync.json`: each chat's
  SHA-256 as last sent. A run sends whatever on disk differs from
  that, and records each batch once the site has it. So the difference *is*
  the outbox: a run cut short by a crash, a closed laptop or no network loses
  nothing, and the next sends it. Sending again is harmless (the site skips
  what it already has). A different account or site starts the record afresh.

  Runs come from `soon/0` (the history after it saves, an account just
  made), a couple of seconds later so a burst
  of writes goes as one; at start; and every few minutes after a failure.
  What's sent is redacted already (the history's `Tools.Redact.secrets/1`);
  a chat's `context` (what reopening it gives the
  model) is never sent.

  `config :tiny_axe, :sync, enabled:` (by default only when the TUI runs, so
  tests and `mix run` send nothing).
  """

  use GenServer

  require Logger

  alias TinyAxe.{Account, History, Site}

  @delay 2_000
  @retry 5 * 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether runs happen."
  def enabled?,
    do:
      Keyword.get(
        Application.get_env(:tiny_axe, :sync, []),
        :enabled,
        Application.get_env(:tiny_axe, :start_tui, false)
      )

  @doc "Sends what changed, in a moment."
  @spec soon() :: :ok
  def soon, do: if(enabled?(), do: GenServer.cast(__MODULE__, :soon), else: :ok)

  @doc """
  Sends what changed now, and waits. Options: `:call` (how a site tool is
  called, for tests) and `:history` (the folder).
  """
  @spec run(keyword()) :: {:ok, %{chats: integer()}} | {:error, String.t()}
  def run(opts \\ []) do
    call = Keyword.get(opts, :call, &Site.call/2)
    history = Keyword.get(opts, :history, History.dir())

    case Account.current() do
      nil ->
        {:error, "no account yet"}

      account ->
        with {:ok, _sent, chats} <- push_chats(history, read_sent(account), call),
             do: {:ok, %{chats: chats}}
    end
  end

  def path, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "site-sync.json")

  ## Server

  @impl true
  def init(_opts) do
    if enabled?(), do: send(self(), :run)
    {:ok, %{timer: nil}}
  end

  @impl true
  def handle_cast(:soon, %{timer: nil} = s),
    do: {:noreply, %{s | timer: Process.send_after(self(), :run, @delay)}}

  def handle_cast(:soon, s), do: {:noreply, s}

  @impl true
  def handle_info(:run, s) do
    if s.timer, do: Process.cancel_timer(s.timer)

    case safely(&run/0) do
      {:ok, %{chats: 0}} ->
        {:noreply, %{s | timer: nil}}

      {:ok, %{chats: chats}} ->
        Logger.info("tiny-axe site: sent #{chats} chats")

        {:noreply, %{s | timer: nil}}

      {:error, "no account yet"} ->
        {:noreply, %{s | timer: nil}}

      {:error, reason} ->
        Logger.warning("tiny-axe site: not sent (#{reason}); trying again in a few minutes")
        {:noreply, %{s | timer: Process.send_after(self(), :run, @retry)}}
    end
  end

  defp safely(fun) do
    fun.()
  catch
    kind, reason -> {:error, Exception.format(kind, reason)}
  end

  defp push_chats(history, sent, call) do
    changed =
      for file <- ls(history),
          id = String.trim_trailing(file, ".json"),
          String.ends_with?(file, ".json") and History.id?(id),
          {:ok, raw} <- [File.read(Path.join(history, file))],
          {:ok, %{} = doc} <- [JSON.decode(raw)],
          doc["local_only"] != true,
          # What reopening it gives the model stays here.
          chat = Map.delete(doc, "context"),
          hash = sha256(JSON.encode!(chat)),
          sent["chats"][id] != hash,
          do: {id, hash, chat}

    Enum.reduce_while(changed, {:ok, sent, 0}, fn {id, hash, chat}, {:ok, sent, count} ->
      case call.("chat_push", %{"chat" => chat}) do
        {:ok, _text} ->
          sent = put_in(sent, ["chats", id], hash)
          write_sent(sent)
          {:cont, {:ok, sent, count + 1}}

        # One the site won't take is noted and left; the rest still go.
        {:error, "that isn't a tiny-axe chat" <> _ = reason} ->
          Logger.warning("tiny-axe site: chat #{id} refused: #{reason}")
          {:cont, {:ok, sent, count}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  ## The record

  defp read_sent(account) do
    fresh = %{"site" => account.site, "username" => account.username, "chats" => %{}}

    with {:ok, raw} <- File.read(path()),
         {:ok, %{"site" => site, "username" => name} = sent} <- JSON.decode(raw),
         true <- site == account.site and name == account.username do
      Map.merge(fresh, Map.take(sent, ["chats"]))
    else
      _ -> fresh
    end
  end

  defp write_sent(sent) do
    File.mkdir_p!(Path.dirname(path()))
    tmp = path() <> ".tmp"
    File.write!(tmp, JSON.encode!(sent))
    File.rename!(tmp, path())
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, files} -> Enum.sort(files)
      _ -> []
    end
  end

  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
