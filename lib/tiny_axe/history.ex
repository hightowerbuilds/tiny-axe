defmodule TinyAxe.History do
  @moduledoc """
  The history of every chat, kept on disk so it outlives tiny-axe: one file
  per chat in `<state_dir>/history/`, as `docs/plan-history.md` describes (the
  website, `tiny-axe graph`, reads the same files).

  The TUI hands over its chats whenever what they show changes (`save/1`,
  from `TinyAxe.TUI.Chats.persist/2`); a chat is written once it has a
  message from the user, and only when its entries or context changed. Every
  text is redacted first (`TinyAxe.Tools.Redact.secrets/1`: card numbers,
  keys and tokens). `/history` in the TUI lists chats (`list/1`) and reopens
  one (`load/1`), which goes on writing to the same file.

  A session is one launch of tiny-axe: this process's start.
  """

  use GenServer

  require Logger

  alias TinyAxe.{Location, Ops}
  alias TinyAxe.Tools.Redact

  @version 1
  @id ~r/\A\d{8}-\d{6}-[0-9a-f]{4}\z/
  @title_chars 80

  @type chat :: %{
          saved_as: String.t() | nil,
          history: [map()],
          transcript: list(),
          summary: map() | nil
        }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "A new chat's id: the time it started (UTC) and four hex digits."
  @spec new_id() :: String.t()
  def new_id do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    stamp <> "-" <> Base.encode16(:crypto.strong_rand_bytes(2), case: :lower)
  end

  @doc "Whether `id` is a chat id (and so safe as a file name)."
  @spec id?(term()) :: boolean()
  def id?(id), do: is_binary(id) and id =~ @id

  @doc "The folder the chats are kept in."
  @spec dir() :: String.t()
  def dir, do: Path.join(Ops.Journal.state_dir(), "history")

  @doc "This launch's session id."
  @spec session() :: String.t()
  def session, do: GenServer.call(__MODULE__, :session)

  @doc "Writes the chats that changed (in the background)."
  @spec save([chat()]) :: :ok
  def save(chats), do: GenServer.cast(__MODULE__, {:save, chats})

  @doc "Waits until every chat handed to `save/1` so far is written."
  @spec sync() :: :ok
  def sync, do: GenServer.call(__MODULE__, :sync)

  @doc """
  The kept chats, most recently updated first: `id`, `title`, `started`,
  `updated`, `folder`, `session` and `messages` (the user's and tiny-axe's).
  `query:` keeps those that have every one of its words somewhere in their
  entries (case doesn't matter), as the website's search does; `limit:`
  keeps the first that many.
  """
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    query = opts[:query] |> to_string() |> String.trim() |> String.downcase()

    dir()
    |> File.ls()
    |> case do
      {:ok, names} -> names
      _ -> []
    end
    |> Enum.filter(&(Path.extname(&1) == ".json" and id?(Path.rootname(&1))))
    |> Enum.flat_map(fn name ->
      case read(Path.rootname(name)) do
        {:ok, doc} -> if matches?(doc, query), do: [summary(doc)], else: []
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.updated, :desc)
    |> then(&if(opts[:limit], do: Enum.take(&1, opts[:limit]), else: &1))
  end

  defp matches?(_doc, ""), do: true

  defp matches?(doc, query) do
    text = Enum.map_join(doc["entries"], "\n", &String.downcase(&1["text"]))
    query |> String.split() |> Enum.all?(&String.contains?(text, &1))
  end

  defp summary(doc) do
    %{
      id: doc["id"],
      title: doc["title"],
      started: doc["started"],
      updated: doc["updated"],
      folder: doc["folder"],
      session: doc["session"],
      messages: Enum.count(doc["entries"], &(&1["kind"] in ["user", "assistant"]))
    }
  end

  @doc """
  A kept chat, as the TUI holds one: `saved_as`, `transcript`, `history` and
  `summary`, plus its `title` and `started`.
  """
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(id) do
    with {:ok, doc} <- read(id) do
      context = if is_map(doc["context"]), do: doc["context"], else: %{}

      {:ok,
       %{
         saved_as: doc["id"],
         title: doc["title"],
         started: doc["started"],
         transcript: Enum.flat_map(doc["entries"], &entry/1),
         history: context |> Map.get("history") |> List.wrap() |> Enum.flat_map(&message/1),
         summary: summary_from(context["summary"])
       }}
    end
  end

  defp entry(%{"kind" => kind, "text" => text}) when kind in ~w(user assistant meta),
    do: [{String.to_existing_atom(kind), text}]

  defp entry(_), do: []

  defp message(%{"role" => role, "content" => content})
       when is_binary(role) and is_binary(content),
       do: [%{role: role, content: content}]

  defp message(_), do: []

  defp summary_from(%{"text" => text} = s) when is_binary(text) do
    %{
      text: text,
      turns: if(is_integer(s["turns"]), do: s["turns"], else: 0),
      check: if(is_number(s["check"]), do: s["check"])
    }
  end

  defp summary_from(_), do: nil

  defp read(id) do
    with true <- id?(id) || {:error, :bad_id},
         {:ok, body} <- File.read(Path.join(dir(), id <> ".json")),
         {:ok, %{"id" => ^id, "entries" => entries} = doc} when is_list(entries) <-
           JSON.decode(body) do
      entries = Enum.filter(entries, &(is_binary(&1["text"]) and is_binary(&1["kind"])))
      {:ok, %{doc | "entries" => entries}}
    else
      {:ok, _other} -> {:error, :not_a_chat}
      {:error, reason} -> {:error, reason}
      false -> {:error, :bad_id}
    end
  end

  ## Writing

  @impl true
  def init(:ok) do
    # A chat's started, session and folder, from its file or its first
    # write; and what was last written, so unchanged chats aren't again.
    {:ok, %{session: new_id(), known: %{}, written: %{}}}
  end

  @impl true
  def handle_call(:session, _from, state), do: {:reply, state.session, state}
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast({:save, chats}, state) do
    {:noreply, Enum.reduce(chats, state, &write/2)}
  end

  defp write(%{saved_as: id} = chat, state) when is_binary(id) do
    entries = entries(chat.transcript)

    cond do
      not id?(id) or not Enum.any?(entries, &(&1["kind"] == "user")) ->
        state

      true ->
        context = %{
          "history" =>
            for(
              %{role: r, content: c} <- chat.history,
              is_binary(c),
              do: %{"role" => to_string(r), "content" => Redact.secrets(c)}
            ),
          "summary" => summary_to(chat[:summary])
        }

        hash = :erlang.phash2({entries, context})

        if state.written[id] == hash do
          state
        else
          {known, state} = known(id, state)
          doc = document(id, known, entries, context)

          case put(id, doc) do
            :ok ->
              %{state | written: Map.put(state.written, id, hash)}

            {:error, reason} ->
              Logger.warning(
                "tiny-axe couldn't keep chat #{id} in its history: #{inspect(reason)}"
              )

              state
          end
        end
    end
  end

  defp write(_chat, state), do: state

  defp entries(transcript) do
    for {kind, text} <- transcript,
        kind in [:user, :assistant, :meta],
        is_binary(text),
        do: %{"kind" => Atom.to_string(kind), "text" => Redact.secrets(text)}
  end

  defp summary_to(%{text: text} = s) when is_binary(text),
    do: %{"text" => Redact.secrets(text), "turns" => s[:turns], "check" => number(s[:check])}

  defp summary_to(_), do: nil

  defp number(n) when is_number(n), do: n
  defp number(_), do: nil

  # A reopened chat keeps the session, start and folder in its file.
  defp known(id, state) do
    case state.known do
      %{^id => known} ->
        {known, state}

      _ ->
        known =
          case read(id) do
            {:ok, doc} ->
              Map.take(doc, ["session", "started", "folder"])

            _ ->
              %{
                "session" => state.session,
                "started" => now(),
                "folder" => Ops.show(Location.current())
              }
          end

        {known, %{state | known: Map.put(state.known, id, known)}}
    end
  end

  defp document(id, known, entries, context) do
    title =
      case Enum.find(entries, &(&1["kind"] == "user")) do
        %{"text" => text} ->
          line = text |> String.split("\n", parts: 2) |> hd() |> String.trim()

          if String.length(line) > @title_chars,
            do: String.slice(line, 0, @title_chars - 1) <> "…",
            else: line
      end

    %{
      "version" => @version,
      "id" => id,
      "session" => known["session"],
      "started" => known["started"],
      "updated" => now(),
      "title" => title,
      "folder" => known["folder"],
      "entries" => entries,
      "context" => context
    }
  end

  # Whole and atomic: the website never reads half a file.
  defp put(id, doc) do
    dir = dir()
    path = Path.join(dir, id <> ".json")
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(tmp, JSON.encode!(doc)),
         :ok <- File.chmod(tmp, 0o600) do
      File.rename(tmp, path)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
