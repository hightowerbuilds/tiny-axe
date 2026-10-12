defmodule TinyAxe.Sync do
  @moduledoc """
  Sends the know-how vault (`TinyAxe.Vault`) and the chat history
  (`TinyAxe.History`) to the user's page of tiny-axe's website
  (`TinyAxe.Graph`, `docs/plan-lobsterattack.md`), as they change.

  What has gone up is recorded in `<state_dir>/site-sync.json`: each note's
  and chat's SHA-256 as last sent. A run sends whatever on disk differs from
  that, and records each batch once the site has it. So the difference *is*
  the outbox: a run cut short by a crash, a closed laptop or no network loses
  nothing, and the next sends it. Sending again is harmless (the site skips
  what it already has). A different account or site starts the record afresh.

  Runs come from `soon/0` (the vault writer after it writes, the history
  after it saves, an account just made), a couple of seconds later so a burst
  of writes goes as one; at start; and every few minutes after a failure.
  What's sent is redacted already (the vault's escaping and the history's
  `Tools.Redact.secrets/1`); a chat's `context` (what reopening it gives the
  model) is never sent.

  `config :tiny_axe, :sync, enabled:` (by default only when the TUI runs, so
  tests and `mix run` send nothing).
  """

  use GenServer

  require Logger

  alias TinyAxe.{Account, Graph, History, Vault}

  @delay 2_000
  @retry 5 * 60_000
  @batch 200
  @folders ~w(Sites Pages Controls Paths Tools Tasks Workflows)

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
  called, for tests), `:vault` and `:history` (the folders).
  """
  @spec run(keyword()) :: {:ok, %{notes: integer(), chats: integer()}} | {:error, String.t()}
  def run(opts \\ []) do
    call = Keyword.get(opts, :call, &Graph.call/2)
    vault = Keyword.get(opts, :vault, Vault.dir())
    history = Keyword.get(opts, :history, History.dir())

    case Account.current() do
      nil ->
        {:error, "no account yet"}

      account ->
        sent = read_sent(account)

        with {:ok, sent, notes} <- push_notes(vault, sent, call),
             {:ok, _sent, chats} <- push_chats(history, sent, call) do
          {:ok, %{notes: notes, chats: chats}}
        end
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
      {:ok, %{notes: 0, chats: 0}} ->
        {:noreply, %{s | timer: nil}}

      {:ok, counts} ->
        Logger.info("tiny-axe site: sent #{counts.notes} notes and #{counts.chats} chats")
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

  ## Notes

  defp push_notes(vault, sent, call) do
    manifest =
      with {:ok, raw} <- File.read(Path.join([vault, ".tiny-axe", "vault.json"])),
           {:ok, %{} = manifest} <- JSON.decode(raw),
           do: manifest,
           else: (_ -> nil)

    changed =
      for folder <- @folders,
          file <- ls(Path.join(vault, folder)),
          String.ends_with?(file, ".md"),
          rel = folder <> "/" <> file,
          {:ok, text} <- [File.read(Path.join(vault, rel))],
          hash = sha256(text),
          sent["notes"][rel] != hash,
          do:
            {rel, hash,
             %{"folder" => folder, "id" => String.trim_trailing(file, ".md"), "text" => text}}

    cond do
      changed == [] ->
        {:ok, sent, 0}

      manifest == nil ->
        {:error, "the vault has notes but no manifest yet"}

      true ->
        changed
        |> Enum.chunk_every(@batch)
        |> Enum.reduce_while({:ok, sent, 0}, fn batch, {:ok, sent, count} ->
          args = %{"manifest" => manifest, "notes" => Enum.map(batch, &elem(&1, 2))}

          with {:ok, text} <- call.("vault_push", args),
               {:ok, %{"refused" => refused}} <- JSON.decode(text) do
            no = MapSet.new(refused, & &1["id"])

            for r <- refused,
                do: Logger.warning("tiny-axe site: note #{r["id"]} refused: #{r["reason"]}")

            taken =
              for {rel, hash, note} <- batch, note["id"] not in no, into: %{}, do: {rel, hash}

            sent = update_in(sent, ["notes"], &Map.merge(&1, taken))
            write_sent(sent)
            {:cont, {:ok, sent, count + map_size(taken)}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
            _ -> {:halt, {:error, "the site's answer to vault_push didn't make sense"}}
          end
        end)
    end
  end

  ## Chats

  defp push_chats(history, sent, call) do
    changed =
      for file <- ls(history),
          id = String.trim_trailing(file, ".json"),
          String.ends_with?(file, ".json") and History.id?(id),
          {:ok, raw} <- [File.read(Path.join(history, file))],
          {:ok, %{} = doc} <- [JSON.decode(raw)],
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
    fresh = %{
      "site" => account.site,
      "username" => account.username,
      "notes" => %{},
      "chats" => %{}
    }

    with {:ok, raw} <- File.read(path()),
         {:ok, %{"site" => site, "username" => name} = sent} <- JSON.decode(raw),
         true <- site == account.site and name == account.username do
      Map.merge(fresh, Map.take(sent, ["notes", "chats"]))
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
