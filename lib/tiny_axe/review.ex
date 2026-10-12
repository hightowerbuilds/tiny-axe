defmodule TinyAxe.Review do
  @moduledoc """
  Reads each chat and says what it was about, for the session graph on the
  user's page of tiny-axe's website (lobsterattack `docs/plan-session-graph.md`).

  Two models, as everywhere in tiny-axe: the local model (Gemma) reads the
  chat (the user's messages and tiny-axe's replies; never the context) and
  proposes a one-line summary, a category and a few concept tags, as JSON.
  Jev then judges: does the category fit, and is each concept a major one?
  Concepts Jev scores low are dropped; a category it rejects becomes
  "other". When the decider can't answer, Gemma's proposal stands as it is.

  Each review is a line in `<state_dir>/reviews.jsonl`, with the hash of the
  chat's entries it was made from, so a chat is read again only once it has
  grown. `TinyAxe.Sync` sends reviews to the site (`review_push`). Runs come
  from `soon/0` (the history after it saves, a little later so a burst goes
  as one), from `/review` in the TUI, and at start.
  """

  use GenServer

  require Logger

  alias TinyAxe.{Decider, History}

  @delay 5_000
  @categories ~w(coding research shopping writing tiny-axe other)
  @max_chars 6_000
  @max_concepts 8
  @keep 0.5

  @schema %{
    type: "object",
    properties: %{
      summary: %{type: "string"},
      category: %{type: "string", enum: @categories},
      concepts: %{type: "array", items: %{type: "string"}}
    },
    required: ["summary", "category", "concepts"]
  }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The categories a chat can be put in."
  def categories, do: @categories

  @doc "Whether runs happen on their own (as `TinyAxe.Sync`: with the TUI)."
  def enabled?,
    do:
      Keyword.get(
        Application.get_env(:tiny_axe, :review, []),
        :enabled,
        Application.get_env(:tiny_axe, :start_tui, false)
      )

  @doc "Reviews what changed, in a moment."
  @spec soon() :: :ok
  def soon, do: if(enabled?(), do: GenServer.cast(__MODULE__, :soon), else: :ok)

  def path, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "reviews.jsonl")

  @doc """
  Reviews every chat that's new or has grown since its last review, now, and
  waits. Options (for tests): `:history` (the folder), `:path` (the record),
  `:chat` (how the local model is asked), `:decide` (how Jev is).
  """
  @spec run(keyword()) :: {:ok, %{reviewed: integer(), skipped: integer(), failed: integer()}}
  def run(opts \\ []) do
    history = Keyword.get(opts, :history, History.dir())
    path = Keyword.get(opts, :path, path())
    known = latest(path)

    docs =
      for name <- ls(history),
          id = Path.rootname(name),
          Path.extname(name) == ".json" and History.id?(id),
          {:ok, doc} <- [History.doc(id, history)],
          do: doc

    Enum.reduce(docs, {:ok, %{reviewed: 0, skipped: 0, failed: 0}}, fn doc, {:ok, counts} ->
      hash = hash(doc)

      cond do
        match?(%{"hash" => ^hash}, known[doc["id"]]) ->
          {:ok, %{counts | skipped: counts.skipped + 1}}

        true ->
          case review(doc, opts) do
            {:ok, review} ->
              append(path, Map.put(review, :hash, hash))
              {:ok, %{counts | reviewed: counts.reviewed + 1}}

            {:error, reason} ->
              Logger.warning("tiny-axe review: #{doc["id"]} not reviewed (#{reason})")
              {:ok, %{counts | failed: counts.failed + 1}}
          end
      end
    end)
    |> tap(fn
      {:ok, %{reviewed: n}} when n > 0 -> TinyAxe.Sync.soon()
      _ -> :ok
    end)
  end

  @doc "The latest review of each chat, by chat id."
  @spec latest(Path.t()) :: %{String.t() => map()}
  def latest(path \\ path()) do
    case File.read(path) do
      {:ok, data} ->
        data
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case JSON.decode(line) do
            {:ok, %{"chat_id" => id} = r} when is_binary(id) -> [{id, r}]
            _ -> []
          end
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  @doc """
  One chat's review: Gemma's reading, judged by Jev. The chat is a history
  document (`TinyAxe.History.doc/1`).
  """
  @spec review(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def review(doc, opts \\ []) do
    chat = Keyword.get(opts, :chat, &TinyAxe.Ollama.chat/2)
    decide = Keyword.get(opts, :decide, &Decider.decide_traced/2)
    text = transcript(doc)

    if text == "" do
      {:error, "nothing said yet"}
    else
      with {:ok, proposal, model} <- propose(chat, doc["title"], text) do
        {category, concepts, decider} = judge(decide, text, proposal)

        {:ok,
         %{
           chat_id: doc["id"],
           summary: proposal.summary,
           category: category,
           concepts: concepts,
           model: model,
           decider: decider,
           reviewed_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
         }}
      end
    end
  end

  # What was said: the user's and tiny-axe's turns, cut to a size Gemma reads
  # quickly (the start and the end, when it's long).
  defp transcript(doc) do
    text =
      doc["entries"]
      |> Enum.filter(&(&1["kind"] in ["user", "assistant"]))
      |> Enum.map_join("\n\n", fn e ->
        who = if e["kind"] == "user", do: "User", else: "tiny-axe"
        "#{who}: #{String.trim(e["text"])}"
      end)

    if String.length(text) <= @max_chars do
      text
    else
      half = div(@max_chars, 2)
      String.slice(text, 0, half) <> "\n\n[…]\n\n" <> String.slice(text, -half, half)
    end
  end

  defp propose(chat, title, text) do
    messages = [
      %{
        role: "system",
        content:
          "You review a chat between a user and tiny-axe, a terminal assistant. Say what it was " <>
            "about. Answer with JSON: \"summary\" (one plain sentence), \"category\" (one of " <>
            Enum.join(@categories, ", ") <>
            "; \"tiny-axe\" is for chats about tiny-axe itself, its site or account) and " <>
            "\"concepts\" (3 to #{@max_concepts} short tags, lowercase, each a thing, place, " <>
            "product or topic the chat was about; no generic words)."
      },
      %{role: "user", content: "Title: #{title}\n\n#{text}"}
    ]

    case chat.(messages, format: @schema, options: [temperature: 0.2]) do
      {:ok, %{"message" => %{"content" => content}} = reply} ->
        case JSON.decode(content) do
          {:ok, %{"summary" => s, "category" => c, "concepts" => tags}}
          when is_binary(s) and is_binary(c) and is_list(tags) ->
            concepts =
              tags
              |> Enum.filter(&is_binary/1)
              |> Enum.map(&tidy/1)
              |> Enum.reject(&(&1 == ""))
              |> Enum.uniq()
              |> Enum.take(@max_concepts)

            {:ok,
             %{
               summary: String.trim(s) |> String.slice(0, 500),
               category: if(tidy(c) in @categories, do: tidy(c), else: "other"),
               concepts: concepts
             }, reply["model"]}

          _ ->
            {:error, "the local model's answer wasn't a review"}
        end

      {:error, reason} ->
        {:error, "the local model couldn't read it (#{inspect(reason)})"}
    end
  end

  # Jev: the category and each concept, as yes/no questions. Without an
  # answer, Gemma's proposal stands.
  defp judge(decide, text, %{category: category, concepts: concepts}) do
    questions =
      %{
        category_fits: %{
          type: :noul,
          instructions:
            "Is \"#{category}\" the right category for this chat? (#{Enum.join(@categories, ", ")})"
        }
      }
      |> Map.merge(
        concepts
        |> Enum.with_index()
        |> Map.new(fn {c, i} ->
          {:"concept_#{i}",
           %{
             type: :noul,
             instructions: "Is \"#{c}\" a major concept of this chat, not a passing one?"
           }}
        end)
      )

    case decide.(text, questions) do
      {:ok, answers, meta} ->
        kept =
          concepts
          |> Enum.with_index()
          |> Enum.filter(fn {_, i} -> Decider.yes?(answers, :"concept_#{i}", @keep) end)
          |> Enum.map(&elem(&1, 0))

        category = if Decider.yes?(answers, :category_fits, @keep), do: category, else: "other"
        {category, kept, meta[:model] || meta[:backend]}

      {:error, reason, _meta} ->
        Logger.debug("tiny-axe review: the decider didn't answer (#{inspect(reason)})")
        {category, concepts, nil}
    end
  end

  defp tidy(s), do: s |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, " ")

  defp hash(doc) do
    doc["entries"]
    |> Enum.filter(&(&1["kind"] in ["user", "assistant"]))
    |> JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp append(path, review) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(review) <> "\n", [:append])
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.sort(names)
      _ -> []
    end
  end

  ## Server

  @impl true
  def init(_opts) do
    if enabled?(), do: Process.send_after(self(), :run, @delay)
    {:ok, %{timer: nil}}
  end

  @impl true
  def handle_cast(:soon, %{timer: nil} = s),
    do: {:noreply, %{s | timer: Process.send_after(self(), :run, @delay)}}

  def handle_cast(:soon, s), do: {:noreply, s}

  @impl true
  def handle_info(:run, s) do
    if s.timer, do: Process.cancel_timer(s.timer)

    try do
      case run() do
        {:ok, %{reviewed: n}} when n > 0 -> Logger.info("tiny-axe review: read #{n} chats")
        _ -> :ok
      end
    catch
      kind, reason -> Logger.warning("tiny-axe review: #{Exception.format(kind, reason)}")
    end

    {:noreply, %{s | timer: nil}}
  end
end
