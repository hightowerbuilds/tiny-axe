defmodule TinyAxe.Organizer do
  @moduledoc """
  Turns a request like "move the PDFs in Downloads into Documents/papers" or
  "write notes.md summarising @talk.txt" into a checked plan for the user to
  approve. Nothing here touches the disk: approved plans are carried out by
  `TinyAxe.Ops.Runner`.

  1. **Look** — the model sees a map of the home folder, search hits for names
     in the request, and anything `@mentioned`. It answers in a fixed JSON
     shape, either asking to see inside folders (up to 3 rounds) or giving a plan.
  2. **Check** — `TinyAxe.Ops.expand/1` expands wildcards and simulates the
     plan; problems go back to the model to fix.
  3. **Review** — the Decider checks the plan does what was asked and nothing
     more; a low score sends it back once.
  4. **Write** — each `write` step's file is generated on its own, from the
     request, the step's description, its source files and any web results,
     and the Decider checks it; a weak one is regenerated once.

  Events, besides the pipeline's `:stage`, `:delta` and `:done`:

      {:looked, [path]}
      {:plan_problems, [problem]}
      {:review, probability}
      {:wrote, %{path: path, check: probability}}
      {:plan, %{request: text, ops: [op], review: probability}}   just before :done
  """

  alias TinyAxe.{Decider, Escalation, Files, Model, Ollama, Ops}
  alias TinyAxe.Organizer.{Discovery, Documents, Review}

  @max_rounds 5
  @look_rounds 3

  # One list per kind of step, each with exactly its own required fields: with a
  # single list of mixed steps and optional fields, small models split one move
  # into a step with only "from" and another with only "to".
  @pair %{
    type: "object",
    properties: %{from: %{type: "string"}, to: %{type: "string"}},
    required: ["from", "to"]
  }

  @schema %{
    type: "object",
    properties: %{
      look: %{type: "array", items: %{type: "string"}},
      mkdir: %{type: "array", items: %{type: "string"}},
      trash: %{type: "array", items: %{type: "string"}},
      copy: %{type: "array", items: @pair},
      move: %{type: "array", items: @pair},
      write: %{
        type: "array",
        items: %{
          type: "object",
          properties: %{
            path: %{type: "string"},
            about: %{type: "string"},
            sources: %{type: "array", items: %{type: "string"}}
          },
          required: ["path", "about", "sources"]
        }
      },
      reply: %{type: "string"}
    },
    required: ["look", "mkdir", "copy", "trash", "move", "write", "reply"]
  }

  @doc """
  Plans a file task. If the local model can't make a working plan in
  #{@max_rounds} rounds, the escalation ladder (`TinyAxe.Escalation`) may try
  bigger models, each from the start; `opts[:remote]` says whether they may
  run off this machine. Documents are still written by the local model.
  """
  @spec run([Ollama.message()], String.t(), [Ollama.message()], (term() -> any()), keyword()) ::
          :ok
  def run(history, prompt, web_context, notify, opts \\ []) do
    notify.({:stage, "looking around…"})

    messages = [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: first_message(history, prompt)}
    ]

    context = TinyAxe.Pipeline.context(history, prompt)

    result =
      case plan(messages, context, notify, 1, false) do
        {:gave_up, reply} ->
          why = "its file plan still had problems after #{@max_rounds} tries"

          escalated = fn choice, acc ->
            case plan(messages, Map.put(context, :use, choice), notify, 1, false) do
              {:gave_up, _} -> {:fell_short, acc}
              {:error, reason} -> {:error, reason, acc}
              result -> {:ok, result}
            end
          end

          case Escalation.climb(why, Keyword.get(opts, :remote, :denied), notify, nil, escalated) do
            {:ok, result, choice} ->
              notify.({:answered_by, %{model: Model.label(choice)}})
              result

            {:none, _} ->
              {:reply, reply}
          end

        result ->
          result
      end

    case result do
      {:ok, ops, reply, review} ->
        notify.({:stage, "writing…"})
        steps = Enum.map_join(ops, "\n", &("- " <> Ops.describe(&1)))
        ops = Enum.map(ops, &Documents.prepare(&1, prompt, steps, web_context, notify))
        notify.({:plan, %{request: prompt, ops: ops, review: review}})
        notify.({:done, summary(reply, ops)})

      {:reply, reply} ->
        notify.({:done, reply})

      {:error, reason} ->
        notify.({:error, reason})
    end

    :ok
  end

  ## Planning

  defp plan(messages, _context, _notify, round, _reviewed) when round > @max_rounds do
    # The last message is tiny-axe's list of what was wrong; pass it on.
    problems = List.last(messages).content |> String.split("\n\n") |> hd()

    {:gave_up,
     "I couldn't put together a plan that works. The last attempt's problems:\n\n" <>
       problems <> "\n\nCould you say more precisely what you'd like?"}
  end

  defp plan(messages, context, notify, round, reviewed?) do
    with {:ok, %{"message" => %{"content" => json}}} <-
           Model.chat(messages, format: @schema, options: [temperature: 0.2], use: context[:use]),
         {:ok, answer} <- JSON.decode(json) do
      look = answer |> Map.get("look", []) |> List.wrap() |> Enum.take(4)
      steps = steps(answer)
      reply = Map.get(answer, "reply", "")
      messages = messages ++ [%{role: "assistant", content: json}]

      cond do
        steps == [] and look != [] and round <= @look_rounds ->
          notify.({:looked, Enum.map(look, &(&1 |> Ops.resolve() |> Ops.show()))})

          plan(
            messages ++ [user(Discovery.listings(look))],
            context,
            notify,
            round + 1,
            reviewed?
          )

        steps == [] ->
          {:reply, reply}

        true ->
          check(steps, reply, messages, context, notify, round, reviewed?)
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :bad_plan_json}
    end
  end

  # Folders first; copies before trash and moves (so "back up, then trash" works);
  # trash before moves (so "trash the old one, move the new one into its place"
  # works); writes last.
  defp steps(answer) do
    list = &(answer |> Map.get(&1, []) |> List.wrap())

    Enum.map(list.("mkdir"), &%{"op" => "mkdir", "path" => &1}) ++
      Enum.map(list.("copy"), &Map.put(&1, "op", "copy")) ++
      Enum.map(list.("trash"), &%{"op" => "trash", "path" => &1}) ++
      Enum.map(list.("move"), &Map.put(&1, "op", "move")) ++
      Enum.map(list.("write"), &Map.put(&1, "op", "write"))
  end

  defp check(steps, reply, messages, context, notify, round, reviewed?) do
    case Ops.expand(steps) do
      {:error, problems} ->
        notify.({:plan_problems, problems})

        fix =
          "tiny-axe checked the plan and it can't be done as written:\n" <>
            Enum.map_join(problems, "\n", &"- #{&1}") <>
            "\n\nLook again if you need to, and reply with a corrected plan."

        plan(messages ++ [user(fix)], context, notify, round + 1, reviewed?)

      {:ok, ops} ->
        {review, feedback, ops} = Review.assess(context, ops)
        notify.({:review, review})
        if review == nil, do: notify.({:decider_unavailable, "reviewing the plan"})

        # One second chance when the reviewer doubts the plan; after that the
        # user sees the score and decides. No score means no second chance.
        if is_number(review) and review < Decider.review_threshold() and not reviewed? and
             round < @max_rounds do
          plan(messages ++ [user(feedback)], context, notify, round + 1, true)
        else
          {:ok, ops, reply, review}
        end
    end
  end

  ## What the model sees

  defp system_prompt do
    """
    You organise files and write documents on the user's computer for tiny-axe. \
    You don't touch anything yourself: you reply with JSON, tiny-axe checks the plan \
    and shows it to the user, and it only happens if they approve.

    Reply with JSON:
    - "look": folders you need to see inside before you can plan (at most 4). \
    Leave it empty once you can plan.
    - "mkdir": folders to make, e.g. ["~/Documents/papers"]
    - "copy" and "move": [{"from": ..., "to": ...}]. Wildcards work in "from" \
    (~/Downloads/*.pdf); a "to" ending in / means "into this folder".
    - "trash": files or folders to move to the system Trash, e.g. ["~/Downloads/*.tmp"]. \
    The user can restore them from the Trash, but only trash what they asked to be \
    removed, deleted, cleaned out or thrown away.
    - "write": files to write, [{"path": ..., "about": ..., "sources": [...]}]. \
    "about" says in detail what the file should contain. "sources" lists every file \
    the document is based on: the writer sees only those files, nothing else.
    - "reply": for the user. With a plan, one or two sentences saying what it will \
    do once they approve it (nothing has happened yet, so don't say "I have moved"). \
    If the user only asked a question (what's in a folder, where a file is), answer \
    it fully here, naming the files, and leave the steps empty. If the request is \
    unclear or can't be done, say so here.

    Steps run in this order: mkdir, copy, trash, move, write. Leave a list empty when \
    there's nothing of that kind.

    Rules:
    - Use ~/… or absolute paths, exactly as they appear in the listings.
    - "a notes.md in Documents/notes" means the path ~/Documents/notes/notes.md.
    - "Put", "file", "sort" or "organise" things somewhere means move them. Copy only \
    when the user says copy, duplicate or back up, or wants to keep the originals.
    - To rename, move to the new name. That's all a rename is: don't also write the \
    file.
    - Nothing may be overwritten; pick another name if one is taken. To replace a \
    file, trash the old one and move the new one into its place. "write" may rewrite \
    an existing text file when the user asks for changes to it.
    - Hidden files and folders (names starting with a dot) are off limits.
    - Only include steps the user asked for.
    """
  end

  defp first_message(history, prompt) do
    recent =
      history
      |> Enum.take(-4)
      |> Enum.map_join("\n", &"#{&1.role}: #{String.slice(&1.content, 0, 500)}")

    mentioned =
      prompt
      |> Files.mentions()
      |> Enum.map_join("\n\n", fn abs ->
        if File.dir?(abs), do: Discovery.listing(abs), else: "File mentioned: #{Ops.show(abs)}"
      end)

    hits = Discovery.search(prompt)

    [
      if(recent != "", do: "Conversation so far:\n#{recent}"),
      "Request: #{prompt}",
      "Today is #{Date.utc_today()}. The home folder is #{Ops.show(Ops.root())}.",
      "The current folder is #{Ops.show(TinyAxe.Location.current())}; relative paths mean " <>
        "this folder. What's in it:\n#{TinyAxe.Location.listing()}",
      "Map of the home folder (two levels, hidden entries left out):\n#{home_map()}",
      if(hits != [],
        do: "Files and folders whose names match words in the request:\n" <> Enum.join(hits, "\n")
      ),
      if(mentioned != "", do: mentioned)
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n\n")
  end

  defp user(content), do: %{role: "user", content: content}

  @doc false
  defdelegate home_map(), to: Discovery

  ## The answer shown in the transcript

  defp summary(reply, ops) do
    steps = Enum.map_join(ops, "\n", &("- " <> Ops.describe(&1)))

    documents =
      for %{op: :write, content: content, path: path} <- ops, into: "" do
        lang = if Path.extname(path) in [".md", ".markdown"], do: "markdown", else: "text"
        "\n\n```#{lang} #{Ops.show(path)}\n#{content}```"
      end

    "#{reply}\n\n**Plan** (waiting for your approval):\n#{steps}#{documents}"
  end
end
