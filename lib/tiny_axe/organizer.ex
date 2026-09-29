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

  alias TinyAxe.{Decider, Files, Ollama, Ops}

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

  @spec run([Ollama.message()], String.t(), [Ollama.message()], (term() -> any())) :: :ok
  def run(history, prompt, web_context, notify) do
    notify.({:stage, "looking around…"})

    messages = [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: first_message(history, prompt)}
    ]

    case plan(messages, prompt, notify, 1, false) do
      {:ok, ops, reply, review} ->
        notify.({:stage, "writing…"})
        steps = Enum.map_join(ops, "\n", &("- " <> Ops.describe(&1)))
        ops = Enum.map(ops, &write_content(&1, prompt, steps, web_context, notify))
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

  defp plan(messages, _prompt, _notify, round, _reviewed) when round > @max_rounds do
    # The last message is tiny-axe's list of what was wrong; pass it on.
    problems = List.last(messages).content |> String.split("\n\n") |> hd()

    {:reply,
     "I couldn't put together a plan that works. The last attempt's problems:\n\n" <>
       problems <> "\n\nCould you say more precisely what you'd like?"}
  end

  defp plan(messages, prompt, notify, round, reviewed?) do
    with {:ok, %{"message" => %{"content" => json}}} <-
           Ollama.chat(messages, format: @schema, options: [temperature: 0.2]),
         {:ok, answer} <- JSON.decode(json) do
      look = answer |> Map.get("look", []) |> List.wrap() |> Enum.take(4)
      steps = steps(answer)
      reply = Map.get(answer, "reply", "")
      messages = messages ++ [%{role: "assistant", content: json}]

      cond do
        steps == [] and look != [] and round <= @look_rounds ->
          notify.({:looked, Enum.map(look, &(&1 |> Ops.resolve() |> Ops.show()))})
          plan(messages ++ [user(listings(look))], prompt, notify, round + 1, reviewed?)

        steps == [] ->
          {:reply, reply}

        true ->
          check(steps, reply, messages, prompt, notify, round, reviewed?)
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

  defp check(steps, reply, messages, prompt, notify, round, reviewed?) do
    case Ops.expand(steps) do
      {:error, problems} ->
        notify.({:plan_problems, problems})

        fix =
          "tiny-axe checked the plan and it can't be done as written:\n" <>
            Enum.map_join(problems, "\n", &"- #{&1}") <>
            "\n\nLook again if you need to, and reply with a corrected plan."

        plan(messages ++ [user(fix)], prompt, notify, round + 1, reviewed?)

      {:ok, ops} ->
        {review, feedback, ops} = review(prompt, ops)
        notify.({:review, review})

        # One second chance when the reviewer doubts the plan; after that the
        # user sees the score and decides.
        if review < 0.5 and not reviewed? and round < @max_rounds do
          plan(messages ++ [user(feedback)], prompt, notify, round + 1, true)
        else
          {:ok, ops, reply, review}
        end
    end
  end

  # One Decider call asks, for each step, whether the user asked for it, and
  # whether the plan does everything asked. The plan's score is its weakest
  # link. Two phrasings proved badly calibrated: "does the plan do what was
  # asked, and nothing else?" (33% for a plan whose steps scored 75-96%), and
  # "does it leave out anything?" (35-58% for the same plan as wording varied,
  # where "does it do everything asked?" held at 76-77%).
  @max_step_questions 30

  defp review(prompt, ops) do
    plan = Enum.map_join(ops, "\n", &("- " <> describe_step(&1)))
    reviewed = Enum.take(ops, @max_step_questions)

    questions =
      reviewed
      |> Enum.with_index()
      |> Map.new(fn {op, i} ->
        {:"step_#{i}",
         %{
           type: :noul,
           instructions:
             "Did the user ask for this step, with this exact action (a copy keeps the " <>
               "original, a move doesn't; trash removes): #{describe_step(op)}?"
         }}
      end)
      |> Map.put(:complete, %{
        type: :noul,
        instructions: "Does the plan do everything the user asked for?"
      })

    # What's in the folders files are taken from (moved, copied or trashed), so
    # the reviewer can tell whether "all the PDFs" really are all of them, and
    # that a .txt isn't one.
    source_folders =
      ops
      |> Enum.flat_map(fn
        %{op: op, from: from} when op in [:move, :copy] -> [Path.dirname(from)]
        %{op: :trash, path: path} -> [Path.dirname(path)]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.map_join("\n\n", &listing/1)

    state = %{
      request: prompt,
      plan: plan,
      source_folders: source_folders,
      # Without this the reviewer marks "delete X" → "trash X" as missing the delete.
      how_tiny_axe_works:
        "tiny-axe never deletes permanently: moving to the Trash is how it deletes, " <>
          "removes or cleans out files. It never overwrites: replacing a file means " <>
          "trashing the old one and moving the new one into place. Making a folder " <>
          "that a move or write needs is part of that move or write."
    }

    case Decider.decide(state, questions) do
      {:ok, answers} ->
        scores = Enum.map(Enum.with_index(reviewed), fn {_, i} -> answers[:"step_#{i}"].noul end)
        complete = answers.complete.noul
        score = Enum.min([complete | scores])

        doubtful =
          reviewed
          |> Enum.zip(scores)
          |> Enum.filter(fn {_op, p} -> p < 0.5 end)
          |> Enum.map(fn {op, p} ->
            "- probably not what the user asked for (#{pct(p)}): " <> describe_step(op)
          end)

        missing_line =
          if complete < 0.5,
            do: [
              "- something the user asked for seems to be missing (complete: #{pct(complete)})"
            ],
            else: []

        feedback =
          "A reviewer checked each step against the request:\n" <>
            Enum.join(doubtful ++ missing_line, "\n") <>
            "\n\nRe-read the request word by word (move is not copy) and reply with a corrected plan."

        # Steps past the reviewed ones get no score of their own.
        ops_scored =
          Enum.zip_with([ops, scores ++ List.duplicate(nil, length(ops))], fn [op, p] ->
            Map.put(op, :review, p)
          end)

        {score, feedback, ops_scored}

      _ ->
        {0.5, "", ops}
    end
  end

  defp pct(p), do: "#{round(p * 100)}%"

  defp describe_step(%{op: :write, about: about} = op), do: Ops.describe(op) <> ": " <> about
  defp describe_step(op), do: Ops.describe(op)

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
        if File.dir?(abs), do: listing(abs), else: "File mentioned: #{Ops.show(abs)}"
      end)

    hits = search(prompt)

    [
      if(recent != "", do: "Conversation so far:\n#{recent}"),
      "Request: #{prompt}",
      "Today is #{Date.utc_today()}. The home folder is #{Ops.show(Ops.root())}.",
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
  def home_map do
    root = Ops.root()

    root
    |> visible_entries()
    |> Enum.map_join("\n", fn name ->
      abs = Path.join(root, name)

      if File.dir?(abs) do
        inner = visible_entries(abs)
        shown = inner |> Enum.take(15) |> Enum.map(&entry_name(abs, &1))
        more = if length(inner) > 15, do: ", … (#{length(inner) - 15} more)", else: ""
        "#{Ops.show(abs)}/: #{Enum.join(shown, ", ")}#{more}"
      else
        Ops.show(abs)
      end
    end)
  end

  defp listings(paths) do
    paths
    |> Enum.map(&Ops.resolve/1)
    |> Enum.map_join("\n\n", &listing/1)
  end

  defp listing(abs) do
    cond do
      not File.dir?(abs) ->
        "#{Ops.show(abs)} is not a folder."

      hidden?(abs) ->
        "#{Ops.show(abs)} is hidden and off limits."

      true ->
        entries = visible_entries(abs)
        shown = Enum.take(entries, 80)

        lines =
          Enum.map(shown, fn name ->
            path = Path.join(abs, name)

            case File.stat(path) do
              {:ok, %{type: :directory}} -> "  #{name}/"
              {:ok, %{size: size}} -> "  #{name}  (#{human_size(size)})"
              _ -> "  #{name}"
            end
          end)

        more = if length(entries) > 80, do: "\n  … (#{length(entries) - 80} more)", else: ""

        "Inside #{Ops.show(abs)}/ (#{length(entries)} entries):\n" <>
          Enum.join(lines, "\n") <> more
    end
  end

  defp visible_entries(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.reject(&String.starts_with?(&1, ".")) |> Enum.sort()
      _ -> []
    end
  end

  defp entry_name(dir, name), do: if(File.dir?(Path.join(dir, name)), do: name <> "/", else: name)

  defp hidden?(abs) do
    abs != Ops.root() and
      abs
      |> Path.relative_to(Ops.root())
      |> Path.split()
      |> Enum.any?(&String.starts_with?(&1, "."))
  end

  defp human_size(n) when n < 1024, do: "#{n} B"
  defp human_size(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp human_size(n), do: "#{Float.round(n / 1024 / 1024, 1)} MB"

  @stopwords ~w(move copy make folder folders file files into from with what that this the
                 have them there their some every each please about write notes note create
                 organise organize rename where want would could should)

  # Names on disk matching words in the request, found with fd (hidden files
  # and .gitignored paths skipped).
  defp search(prompt) do
    words =
      ~r/[\p{L}\p{N}_-]{4,}/u
      |> Regex.scan(String.downcase(prompt))
      |> List.flatten()
      |> Enum.reject(&(&1 in @stopwords))
      |> Enum.uniq()

    with [_ | _] <- words, fd when fd != nil <- System.find_executable("fd") do
      pattern = Enum.map_join(words, "|", &Regex.escape/1)

      args =
        ~w(--ignore-case --max-depth 6 --max-results 30 --exclude node_modules --exclude _build --exclude deps)

      case System.cmd(fd, args ++ [pattern, Ops.root()], stderr_to_stdout: true) do
        {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&Ops.show/1)
        _ -> []
      end
    else
      _ -> []
    end
  end

  ## Writing documents

  defp write_content(%{op: :write, path: path} = op, prompt, steps, web_context, notify) do
    notify.({:stage, "writing #{Ops.show(path)}…"})

    old =
      case Files.read(path, 20_000) do
        {:ok, text, false} -> text
        _ -> nil
      end

    content = generate(op, old, prompt, steps, web_context, notify, 0.5)
    check = check_document(op, prompt, content)

    {content, check} =
      if check < 0.5 do
        retry = generate(op, old, prompt, steps, web_context, notify, 0.9)
        retry_check = check_document(op, prompt, retry)
        if retry_check > check, do: {retry, retry_check}, else: {content, check}
      else
        {content, check}
      end

    notify.({:wrote, %{path: Ops.show(path), check: check}})

    op
    |> Map.merge(%{content: content, old: old, old_hash: old && Ops.hash(old), check: check})
  end

  defp write_content(op, _prompt, _steps, _web_context, _notify), do: op

  defp generate(op, old, prompt, steps, web_context, notify, temperature) do
    markdown? = Path.extname(op.path) in [".md", ".markdown"]

    sources =
      op.sources
      |> Enum.map_join("\n\n", fn abs ->
        case Files.read(abs, 8_000) do
          {:ok, text, cut?} ->
            "===== #{Ops.show(abs)} =====\n#{text}#{if cut?, do: "\n(cut off)"}\n===== end ====="

          {:error, _} ->
            ""
        end
      end)

    ask =
      [
        "Write the complete contents of the file #{Ops.show(op.path)}.",
        "What it should contain: #{op.about}",
        "The user's request: #{prompt}",
        "This file is part of a plan that runs once the user approves it:\n#{steps}\n" <>
          "Describe files by where they will be after the plan, and name only real files.",
        old && "The file exists; revise it as asked. Its current contents:\n#{old}",
        sources != "" && "Source files:\n#{sources}",
        web_context != [] &&
          "Use the web search results you were given, and end with a \"Sources\" section linking them.",
        "Reply with only the file's contents#{if markdown?, do: ", in Markdown"}: no preamble, " <>
          "no code fence around the whole file."
      ]
      |> Enum.filter(& &1)
      |> Enum.join("\n\n")

    messages =
      [
        %{
          role: "system",
          content: "You are a skilled writer. Write clear, well-organised documents."
        }
      ] ++
        web_context ++ [user(ask)]

    notify.({:attempt, 1})

    case Ollama.stream_chat(messages, &notify.({:delta, &1}),
           options: [temperature: temperature],
           on_usage: &notify.({:usage, &1})
         ) do
      {:ok, text} -> text |> unfence() |> String.trim() |> Kernel.<>("\n")
      {:error, _} -> old || ""
    end
  end

  # Models sometimes wrap the whole file in a code fence anyway.
  defp unfence(text) do
    case Regex.run(~r/\A\s*```[\w-]*[^\n]*\n(.*)\n```\s*\z/s, text) do
      [_, inner] -> inner
      nil -> text
    end
  end

  defp check_document(op, prompt, content) do
    question = %{
      fits: %{
        type: :noul,
        instructions: "Is this document what was asked for, complete and well written?"
      }
    }

    case Decider.decide(%{asked: op.about, user_request: prompt, document: content}, question) do
      {:ok, %{fits: %{noul: p}}} -> p
      _ -> 0.5
    end
  end

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
