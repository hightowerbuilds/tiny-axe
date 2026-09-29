defmodule TinyAxe.Pipeline do
  @moduledoc """
  The route → generate → check → verify loop.

  1. **Route** — the Decider classifies the request, which picks the system prompt,
     and decides whether it needs the web. If so, the model writes a search query,
     the Decider checks the results are on topic, and the top pages are read and
     given to the model as numbered sources (`TinyAxe.Web`). Likewise for project
     files: `@path` mentions are attached, or the Decider picks the files a request
     is about from the project listing (`TinyAxe.Files`). When the Decider says
     the user wants files changed, whole-file code blocks labelled with a path
     come back as proposed edits for the user to approve.
  2. **Generate** — the local model streams a response.
  3. **Check** — Elixir/Python code blocks are compiled and doctested in a
     sandbox (`TinyAxe.CodeCheck`). On failure, the model gets the real
     compiler/test output and is asked to fix it.
  4. **Verify** — the Decider judges whether the response addresses the request,
     seeing the check result too. Below the acceptance threshold, regenerate.

  At most `:max_attempts` generations per request.

  Progress is reported through `notify`, a 1-arity function receiving:

      {:route, answers}
      {:search, %{query: q, engine: e, results: n, read: n}}
      {:search_failed, %{query: q, reason: reason}}
      {:moved, %{from: path, to: path, confidence: p}}   the Decider picked a folder
      {:files, %{read: [path], listed: n}}
      {:attempt, n}
      {:delta, text}
      {:stage, status_label}
      {:check, {:ran, result} | {:skipped, reason}}
      {:verify, answers}
      {:usage, %{prompt_tokens: n, output_tokens: n, prompt_chars: n}}   after each generation
      {:chose, %{attempt: n, score: p, attempts: n}}   # answering with an earlier attempt
      {:edits, [%{path: p, abs: abs, old: old | nil, new: new}]}   # just before :done
      {:edit_refused, %{path: p, reason: text}}
      {:done, text}
      {:error, reason}
  """

  alias TinyAxe.{CodeCheck, Decider, Files, Location, Ollama, Ops, Web}

  @route_questions %{
    kind: %{
      type: :choice,
      instructions: "What kind of task is the user asking for?",
      options: %{
        code: "Writing, changing, explaining or debugging code",
        writing: "Writing, rewriting, summarising or editing prose",
        question: "A factual or conceptual question to answer"
      }
    },
    web: %{
      type: :noul,
      instructions:
        "Does answering well need a web search: current events, recent releases or " <>
          "versions, prices, documentation for a specific library or tool, or facts about " <>
          "specific people, products or companies? Also yes if the user asks to search or " <>
          "look something up. No for questions about you, the assistant, or this " <>
          "conversation."
    },
    files: %{
      type: :noul,
      instructions:
        "Is the request about files, folders or code in the user's current project, for " <>
          "example \"my mix.exs\", \"the TUI module\", \"this project\" or \"what's in " <>
          "this folder\"?"
    },
    change: %{
      type: :noul,
      instructions:
        "Does the user want files created or changed (code or text), rather than only " <>
          "an answer or an explanation?"
    },
    organize: %{
      type: :noul,
      instructions:
        "Does the user want files or folders moved, copied, renamed, organised, deleted " <>
          "or cleaned out, folders " <>
          "made, or a document (notes, Markdown, plain text) written to a file on their " <>
          "computer? Also yes if they ask what's in a folder on their computer or where a " <>
          "file is. No if they want code in their project written or changed."
    },
    elsewhere: %{
      type: :noul,
      instructions:
        "Does the request name a folder to work in other than the current folder " <>
          "(e.g. \"in my tiny-app repo\", \"go to Downloads\", \"the web folder\")?"
    },
    command: %{
      type: :noul,
      instructions:
        "Does the user want a shell command run for them: installing packages, " <>
          "scaffolding a project (e.g. Vite), git, or running build, test or dev tools? " <>
          "No if they only want to know which command to use."
    }
  }

  @system_prompts %{
    code:
      "You are a careful programming assistant. Put all code in ONE fenced block with the " <>
        "language named, complete and compilable on its own. For Elixir and Python, include " <>
        "doctests that show correct behaviour: `iex>` examples in each public function's " <>
        "@doc for Elixir, `>>>` examples in docstrings for Python. They are run for you, so " <>
        "do not call `doctest` or add a test runner. After the block, add at most two " <>
        "sentences of explanation. Do not explain how to run it.",
    writing:
      "You are a skilled editor and writer. Reply with only the requested text, in the " <>
        "user's requested tone and length. No alternatives, preamble or list of changes " <>
        "unless asked.",
    question:
      "You are a knowledgeable assistant. Answer directly and concisely, then add detail if useful."
  }

  @false_claim_fix """
  Your answer says you ran, installed or executed something, or that you're about to. \
  You can't run commands. Rewrite it so the user runs them: give each command in a \
  code block, say where to run it, and what to expect. The user never saw your earlier \
  answer or this message, so don't mention either.
  """

  @spec run([Ollama.message()], String.t(), (term() -> any())) :: :ok
  def run(history, prompt, notify) do
    # The router sees where tiny-axe is, so it can tell whether a request means somewhere else.
    state = %{request: prompt, current_folder: Ops.show(Location.current())}

    with {:ok, route} <- Decider.decide(state, @route_questions) do
      notify.({:route, route})
      kind = route.kind.choice
      navigate(route, prompt, notify)
      {web_context, request, notify} = maybe_search(route, history, prompt, notify)

      case task(route) do
        :command -> TinyAxe.Commander.run(history, prompt, notify)
        :organize -> TinyAxe.Organizer.run(history, prompt, web_context, notify)
        :answer -> answer(route, kind, history, prompt, web_context, request, notify)
      end
    else
      {:error, reason} -> notify.({:error, reason})
    end

    :ok
  end

  # Commands go to the Commander and file tasks (moving, organising, writing
  # documents) to the Organizer; when both look likely, the likelier wins.
  defp task(route) do
    command = if config(:commands, true), do: get_in(route, [:command, :noul]) || 0, else: 0
    organize = if config(:file_ops, true), do: get_in(route, [:organize, :noul]) || 0, else: 0

    cond do
      command >= 0.5 and command >= organize -> :command
      organize >= 0.5 -> :organize
      true -> :answer
    end
  end

  defp answer(route, kind, history, prompt, web_context, request, notify) do
    {file_context, request, notify} = maybe_files(route, history, prompt, request, notify)

    messages =
      [%{role: "system", content: system_prompt(kind)} | history] ++
        web_context ++ file_context ++ [%{role: "user", content: prompt}]

    attempt(%{messages: messages, request: request, notify: notify, best: nil}, 1)
  end

  # One request's retry loop. `run` holds what every attempt shares: the messages,
  # `request` (the verifier's view of the task), `notify`, and `best`, the
  # highest-rated verified attempt so far.
  defp attempt(run, n, temperature \\ 0.4) do
    run.notify.({:attempt, n})

    with {:ok, text} <-
           Ollama.stream_chat(run.messages, &run.notify.({:delta, &1}),
             options: [temperature: temperature],
             on_usage: &run.notify.({:usage, &1})
           ) do
      run.notify.({:stage, "checking code…"})
      check = CodeCheck.run(text)
      run.notify.({:check, check})
      last? = n >= config(:max_attempts, 3)

      case check do
        {:ran, %{status: :failed}} when last? ->
          finish(run, text, n)

        {:ran, %{status: :failed} = result} ->
          # Concrete feedback beats resampling, so keep temperature low.
          fix = [
            %{role: "assistant", content: text},
            %{role: "user", content: fix_prompt(result)}
          ]

          attempt(%{run | messages: run.messages ++ fix}, n + 1, 0.3)

        _ ->
          verify_and_finish(run, text, check, n, last?, temperature)
      end
    else
      {:error, reason} -> run.notify.({:error, reason})
    end
  end

  defp verify_and_finish(run, text, check, n, last?, temperature) do
    run.notify.({:stage, "verifying…"})

    case verify(run.request, text, check) do
      {:ok, verdict} ->
        run.notify.({:verify, verdict})
        claim = get_in(verdict, [:false_claim, :noul]) || 0.0
        # An answer that claims to have done what it can't is only as good as its honesty.
        score = min(verdict.addresses.noul, 1 - claim)
        run = remember(run, text, n, score)

        cond do
          score >= config(:accept_threshold, 0.7) ->
            run.notify.({:done, text})

          last? ->
            finish(run, text, n)

          claim >= 0.5 ->
            fix = [
              %{role: "assistant", content: text},
              %{role: "user", content: @false_claim_fix}
            ]

            attempt(%{run | messages: run.messages ++ fix}, n + 1, 0.3)

          true ->
            # No concrete feedback to give, so nudge sampling for a different answer.
            attempt(run, n + 1, min(temperature + 0.25, 1.1))
        end

      {:error, reason} ->
        run.notify.({:error, reason})
    end
  end

  defp remember(%{best: best} = run, text, n, score) do
    if best == nil or score > best.score,
      do: %{run | best: %{text: text, n: n, score: score}},
      else: run
  end

  # Out of attempts: answer with the highest-rated one, which may be an earlier attempt.
  defp finish(%{best: %{n: best_n} = best} = run, _text, n) when best_n != n do
    run.notify.({:chose, %{attempt: best_n, score: best.score, attempts: n}})
    run.notify.({:done, best.text})
  end

  defp finish(run, text, _n), do: run.notify.({:done, text})

  defp fix_prompt(%{language: lang, summary: summary, output: output}) do
    """
    I compiled and tested your #{lang} code in a sandbox. Result: #{summary}.

    ```
    #{output}
    ```

    Fix the problems and reply with the complete corrected answer in the same format.
    Keep the doctests: if one is wrong, correct the code or the expected value rather
    than deleting it. The user never saw your earlier answer or this message, so write
    as if answering for the first time: don't mention errors, fixes or earlier attempts.
    """
  end

  defp verify(request, response, check) do
    check_note =
      case check do
        {:ran, %{language: lang, summary: summary}} ->
          "#{lang} code was compiled and tested: #{summary}"

        {:skipped, reason} ->
          "not run (#{reason})"
      end

    state = Map.merge(request, %{response: response, automated_code_check: check_note})

    Decider.decide(state, %{
      addresses: %{
        type: :noul,
        instructions:
          "Does the response fully and correctly address the request, without errors or " <>
            "missing parts?"
      },
      # Small models say "I ran npm install" when nothing ran.
      false_claim: %{
        type: :noul,
        instructions:
          "Does the response claim that the assistant ran a command, installed software or " <>
            "did something on the computer (or is about to), rather than telling the user " <>
            "what to run?"
      }
    })
  end

  ## System prompt

  ## Location

  # When a request names another folder, the Decider picks it from real folders
  # (TinyAxe.Location.candidates/1), so the location is never a path a model made up.
  defp navigate(%{elsewhere: %{noul: p}}, prompt, notify) when p >= 0.5 do
    here = Location.current()

    candidates =
      prompt
      |> Location.candidates()
      |> Enum.map(&Ops.show/1)
      |> Files.shortlist(prompt, Decider.max_options() - 1)

    options =
      candidates
      |> Map.new(&{&1, &1})
      |> Map.put("(stay)", "The current folder, #{Ops.show(here)}")

    question = %{
      folder: %{
        type: :choice,
        instructions: "Which folder does the user want to work in?",
        options: options
      }
    }

    state = %{request: prompt, current_folder: Ops.show(here)}

    with {:ok, %{folder: %{choice: choice, probabilities: probs}}} <-
           Decider.decide(state, question),
         true <- choice != "(stay)" and (probs[choice] || 0) >= 0.4,
         {:ok, to} <- Location.cd(choice),
         true <- to != here do
      notify.({:moved, %{from: Ops.show(here), to: Ops.show(to), confidence: probs[choice]}})
    end
  end

  defp navigate(_route, _prompt, _notify), do: :ok

  defp location_note do
    here = Location.current()

    "You're working in #{Ops.show(here)} (tiny-axe's current folder; relative paths mean " <>
      "this folder). What's in it:\n#{Location.listing(here, 30)}"
  end

  defp system_prompt(kind) do
    "You are tiny-axe, an assistant running locally on the user's computer " <>
      "(model: #{config(:model, "unknown")}). Today is #{today()}. When a request needs " <>
      "current information, tiny-axe searches the web and gives you the results. It can " <>
      "also give you files from the user's project (#{Files.display(Files.root())}) and " <>
      "offer your changes to them for the user to approve. This answer can't run shell " <>
      "commands: give any command in a code block, and never say you ran, installed or " <>
      "executed anything. If the user wants a command run, tell them to ask tiny-axe to " <>
      "run it; it will show the command for approval and run it in a sandbox.\n\n" <>
      location_note() <> "\n\n" <> @system_prompts[kind]
  end

  defp today do
    NaiveDateTime.local_now() |> NaiveDateTime.to_date() |> Calendar.strftime("%A, %B %-d, %Y")
  end

  ## Web search

  # Returns extra context messages, the verifier's view of the request, and a
  # notify that appends the cited sources to the final answer.
  defp maybe_search(%{web: %{noul: p}}, history, prompt, notify) do
    if config(:web_search, true) and p >= config(:web_threshold, 0.5),
      do: search(history, prompt, notify),
      else: {[], %{request: prompt, current_folder: Ops.show(Location.current())}, notify}
  end

  defp maybe_search(_route, _history, prompt, notify),
    do: {[], %{request: prompt, current_folder: Ops.show(Location.current())}, notify}

  defp search(history, prompt, notify) do
    notify.({:stage, "searching the web…"})
    query = search_query(history, prompt)

    case Web.search(query, accept?: &relevant?(query, &1)) do
      {:ok, results, engine} ->
        notify.({:stage, "reading pages…"})
        sources = read_sources(results)
        read = Enum.count(sources, & &1.read?)
        notify.({:search, %{query: query, engine: engine, results: length(results), read: read}})

        # The verifier sees the same sources, so it can check the answer against them.
        {[%{role: "system", content: sources_prompt(query, sources)}],
         %{request: prompt, web_sources: sources_text(sources)}, append_sources(notify, sources)}

      {:error, reason} ->
        notify.({:search_failed, %{query: query, reason: reason}})

        failed =
          "A web search for this request failed. Answer from your own knowledge and say " <>
            "that you couldn't check the web, so recent details may be out of date."

        {[%{role: "system", content: failed}],
         %{request: prompt, current_folder: Ops.show(Location.current())}, notify}
    end
  end

  defp recent(history) do
    history
    |> Enum.take(-4)
    |> Enum.map_join("\n", &"#{&1.role}: #{String.slice(&1.content, 0, 300)}")
  end

  defp search_query(history, prompt) do
    recent = recent(history)

    ask = """
    #{if recent != "", do: "Conversation so far:\n#{recent}\n\n"}Request: #{prompt}

    Write the best web search query (2–10 words) for finding what's needed to answer \
    the request. Use the conversation to work out what words like "it" refer to. \
    Include a year only if the request is about something recent.
    """

    messages = [
      %{role: "system", content: "You write web search queries. Today is #{today()}."},
      %{role: "user", content: ask}
    ]

    schema = %{type: "object", properties: %{query: %{type: "string"}}, required: ["query"]}

    with {:ok, %{"message" => %{"content" => json}}} <-
           Ollama.chat(messages, format: schema, options: [temperature: 0]),
         {:ok, %{"query" => query}} <- JSON.decode(json),
         query when query != "" <- String.trim(query) do
      String.slice(query, 0, 200)
    else
      _ -> String.slice(prompt, 0, 200)
    end
  end

  # Search engines sometimes answer scripted requests with off-topic results.
  defp relevant?(query, results) do
    listing = Enum.map_join(results, "\n", &"- #{&1.title}: #{String.slice(&1.snippet, 0, 200)}")

    case Decider.decide(%{search_query: query, results: listing}, %{
           relevant: %{
             type: :noul,
             instructions: "Are these search results relevant to the search query?"
           }
         }) do
      {:ok, %{relevant: %{noul: p}}} -> p >= 0.5
      _ -> true
    end
  end

  # Reads the top pages in full; the rest contribute their snippets.
  defp read_sources(results) do
    {to_read, rest} = Enum.split(results, config(:web_pages, 3))

    read =
      to_read
      |> Task.async_stream(&Web.fetch(&1.url, max_chars: config(:web_page_chars, 2_500)),
        timeout: 40_000,
        on_timeout: :kill_task
      )
      |> Enum.zip(to_read)
      |> Enum.map(fn
        {{:ok, {:ok, %{text: text}}}, r} when text != "" -> source(r, text, true)
        {_, r} -> source(r, r.snippet, false)
      end)

    (read ++ Enum.map(rest, &source(&1, &1.snippet, false)))
    |> Enum.with_index(1)
    |> Enum.map(fn {s, n} -> Map.put(s, :n, n) end)
  end

  defp source(result, text, read?),
    do: %{title: result.title, url: result.url, text: text, read?: read?}

  defp sources_text(sources) do
    Enum.map_join(sources, "\n\n", fn s ->
      label = if s.read?, do: "page text", else: "search snippet"
      "[#{s.n}] #{s.title}\n#{s.url}\n(#{label})\n#{s.text}"
    end)
  end

  defp sources_prompt(query, sources) do
    """
    Web search results for #{inspect(query)}, retrieved #{today()}. Use them to answer \
    and cite them inline as [1], [2] and so on. Where they disagree with what you \
    remember, trust them. If they don't answer the request, say so rather than \
    guessing. Don't write a list of sources at the end: the list is added \
    automatically after your answer.

    #{sources_text(sources)}
    """
  end

  defp append_sources(notify, sources) do
    fn
      {:done, text} -> notify.({:done, text <> source_list(text, sources)})
      event -> notify.(event)
    end
  end

  # Lists the sources the answer cites, or the pages it was given if it cites none.
  defp source_list(text, sources) do
    cited = Enum.filter(sources, &String.contains?(text, "[#{&1.n}]"))
    listed = if cited == [], do: Enum.filter(sources, & &1.read?), else: cited

    case listed do
      [] -> ""
      _ -> "\n\nSources:\n" <> Enum.map_join(listed, "\n", &"[#{&1.n}] #{&1.title} — #{&1.url}")
    end
  end

  ## Project files

  @edit_instructions """
  To change a file, reply with its complete new contents in one fenced code block \
  whose opening line is the language followed by the path, like ```elixir lib/foo.ex \
  — every line of the file, not just the changed part. To create a file, do the same \
  with the new path. tiny-axe shows the user a diff and saves only if they approve, \
  so don't claim the change is already made.\
  """

  @answer_only "Answer from these files. The user wants an answer, not changes, so " <>
                 "don't rewrite the files."

  # Returns extra context messages, the verifier's view of the request, and a
  # notify that reports proposed edits just before the final answer.
  defp maybe_files(route, history, prompt, request, notify) do
    mentioned = Files.mentions(prompt)
    threshold = config(:files_threshold, 0.5)

    wanted? =
      mentioned != [] or
        (config(:file_access, true) and match?(%{files: %{noul: p}} when p >= threshold, route))

    # Without this, models "helpfully" rewrite files when only asked about them.
    edit? = match?(%{change: %{noul: p}} when p >= 0.5, route)

    if wanted?,
      do: read_files(mentioned, edit?, history, prompt, request, notify),
      else: {[], request, notify}
  end

  defp read_files(mentioned, edit?, history, prompt, request, notify) do
    notify.({:stage, "reading files…"})
    listing = Files.list()
    picked = if mentioned == [], do: pick_files(listing, history, prompt), else: []
    # A question about the project as a whole is best answered from its README.
    picked = if mentioned == [] and picked == [], do: readme(listing), else: picked
    attached = attach(mentioned ++ Enum.map(picked, &Files.resolve/1))
    notify.({:files, %{read: Enum.map(attached, & &1.path), listed: length(listing)}})

    # The verifier sees the same files, so it can check the answer against them.
    request =
      Map.merge(request, %{
        project_listing: listing |> Enum.take(150) |> Enum.join("\n"),
        project_files: files_text(attached)
      })

    partial = for %{partial?: true, abs: abs} <- attached, into: MapSet.new(), do: abs

    {[%{role: "system", content: files_prompt(listing, attached, prompt, edit?)}], request,
     if(edit?, do: propose_edits(notify, partial), else: notify)}
  end

  # Asks the Decider which files the request is about, shortlisting big projects
  # to what it can take as options. Keeps up to 3 likely files.
  defp pick_files([], _history, _prompt), do: []

  defp pick_files(listing, history, prompt) do
    candidates = Files.shortlist(listing, prompt, Decider.max_options() - 1)
    options = candidates |> Map.new(&{&1, &1}) |> Map.put("(none)", "No specific file")

    question = %{
      file: %{
        type: :choice,
        instructions:
          "Which file in the user's project is the request about? Pick (none) if it " <>
            "isn't about a specific file.",
        options: options
      }
    }

    case Decider.decide(%{request: prompt, recent_conversation: recent(history)}, question) do
      {:ok, %{file: %{probabilities: probs}}} ->
        probs
        |> Enum.filter(fn {path, p} -> path != "(none)" and p >= config(:file_pick_min, 0.2) end)
        |> Enum.sort_by(&(-elem(&1, 1)))
        |> Enum.take(3)
        |> Enum.map(&elem(&1, 0))

      _ ->
        []
    end
  end

  defp readme(listing) do
    listing |> Enum.filter(&(&1 =~ ~r/^readme(\.\w+)?$/i)) |> Enum.take(1)
  end

  # Reads files (and lists directories) within a shared character budget.
  defp attach(paths) do
    paths = Enum.uniq(paths)
    per_file = max(div(config(:file_chars, 12_000), max(length(paths), 1)), 2_000)

    Enum.flat_map(paths, fn abs ->
      path = Files.display(abs)

      cond do
        File.dir?(abs) ->
          files = Files.list(abs)
          shown = Enum.take(files, 100)
          more = if length(files) > 100, do: "\n(#{length(files) - 100} more)", else: ""

          [
            %{
              path: path <> "/",
              abs: abs,
              partial?: false,
              text: "Directory listing:\n" <> Enum.join(shown, "\n") <> more
            }
          ]

        true ->
          case Files.read(abs, per_file) do
            {:ok, text, false} ->
              [%{path: path, abs: abs, partial?: false, text: text}]

            {:ok, text, true} ->
              text = text <> "\n(cut off here: the file is longer)"
              [%{path: path, abs: abs, partial?: true, text: text}]

            {:error, _} ->
              []
          end
      end
    end)
  end

  defp files_text(attached) do
    Enum.map_join(attached, "\n\n", fn f ->
      "===== #{f.path} =====\n#{f.text}\n===== end of #{f.path} ====="
    end)
  end

  defp files_prompt(listing, attached, prompt, edit?) do
    shown = if length(listing) > 150, do: Files.shortlist(listing, prompt, 150), else: listing
    more = if length(listing) > length(shown), do: " (#{length(shown)} shown)", else: ""

    files = files_text(attached)

    """
    The user's project is #{Files.display(Files.root())}. It has #{length(listing)} \
    files#{more}:
    #{Enum.join(Enum.sort(shown), "\n")}

    #{if files != "", do: "Files you were given:\n\n" <> files, else: "No file contents were given."}

    #{if edit?, do: @edit_instructions, else: @answer_only}
    """
  end

  # A rewrite of a file the model only saw part of would drop the rest, so it's refused.
  defp propose_edits(notify, partial) do
    fn
      {:done, text} ->
        {refused, edits} = text |> Files.proposed_edits() |> Enum.split_with(&(&1.abs in partial))

        for e <- refused do
          reason =
            "the file was too long to show the model in full, so its rewrite would drop the rest"

          notify.({:edit_refused, %{path: e.path, reason: reason}})
        end

        if edits != [], do: notify.({:edits, edits})
        notify.({:done, text})

      event ->
        notify.(event)
    end
  end

  defp config(key, default), do: Application.get_env(:tiny_axe, key, default)
end
