defmodule TinyAxe.Pipeline do
  @moduledoc """
  The route → generate → check → verify loop.

  Routing stays here. `Pipeline.Answer` owns generation and retries;
  `Pipeline.WebContext` and `Pipeline.ProjectContext` supply evidence and wrap
  final-answer notifications. `Pipeline.RequestContext` is shared by decisions
  throughout the application through `context/2`.

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

  At most `:max_attempts` generations per request with the local model. If
  none is good enough, the escalation ladder (`TinyAxe.Escalation`) may try
  bigger models, `:escalate_attempts` each.

  Progress is reported through `notify`, a 1-arity function receiving:

      {:route, answers}
      {:search, %{query: q, engine: e, results: n, read: n}}
      {:search_failed, %{query: q, reason: reason}}
      {:decider_unavailable, what}   a decision couldn't be made; carried on without it
      {:trimmed, %{cut: [what], before: tokens, after: tokens}}   fitted into the window
      {:moved, %{from: path, to: path, confidence: p}}   the Decider picked a folder
      {:files, %{read: [path], listed: n}}
      {:attempt, n}
      {:delta, text}
      {:stage, status_label}
      {:check, {:ran, result} | {:skipped, reason}}
      {:verify, answers}
      {:escalate, %{to: label, reason: why}}   the local model fell short; trying a bigger one
      {:escalate_skipped, %{to: label, reason: why}} | {:escalate_failed, %{to: label, reason: term}}
      {:ask_remote, %{to: label, reason: why, reply_to: pid, ref: ref}}   answer with {:remote_answer, ref, boolean}
      {:answered_by, %{model: label}}   the answer came from a model off this machine
      {:usage, %{prompt_tokens: n, output_tokens: n, prompt_chars: n}}   after each generation
      {:chose, %{attempt: n, score: p, attempts: n}}   # answering with an earlier attempt
      {:edits, [%{path: p, abs: abs, old: old | nil, new: new}]}   # just before :done
      {:edit_refused, %{path: p, reason: text}}
      {:done, text}
      {:error, reason}
  """

  alias TinyAxe.{Decider, Files, Location, Ollama, Ops}
  alias TinyAxe.Pipeline.{Answer, ProjectContext, RequestContext, WebContext}

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
          "file is. No if they want code in their project written or changed, or if " <>
          "they're asking how to do it themselves (\"how do I move a file?\")."
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

  @doc """
  Handles one request. `opts`: `:remote` (`:ask`, `:allowed` or `:denied`,
  the default), whether a request that falls short may go to a model off this
  machine (see `TinyAxe.Escalation`).
  """
  @spec run([Ollama.message()], String.t(), (term() -> any()), keyword()) :: :ok
  def run(history, prompt, notify, opts \\ []) do
    remote = Keyword.get(opts, :remote, :denied)

    # The router sees the conversation and where tiny-axe is, so "now run it"
    # or "put those there" can be understood, and a request that means
    # somewhere else can be told apart.
    state = context(history, prompt)

    with {:ok, route} <- Decider.decide(state, route_questions()) do
      notify.({:route, route})
      # An unknown task kind gets the plain question prompt.
      kind = route.kind.choice || :question
      navigate(route, prompt, notify)
      {web_context, request, notify} = WebContext.prepare(route, history, prompt, notify)

      task = task(route)
      notify.({:task, task})

      case task do
        :command ->
          TinyAxe.Commander.run(history, prompt, notify, remote: remote)

        :organize ->
          TinyAxe.Organizer.run(history, prompt, web_context, notify, remote: remote)

        :agent ->
          TinyAxe.Agent.run(history, prompt, notify, remote: remote)

        :answer ->
          {file_context, request, notify} =
            ProjectContext.prepare(route, history, prompt, request, notify)

          messages =
            [%{role: "system", content: Answer.system_prompt(kind)} | history] ++
              web_context ++ file_context ++ [%{role: "user", content: prompt}]

          Answer.run(messages, request, notify, remote)
      end
    else
      {:error, reason} -> notify.({:error, reason})
    end

    :ok
  end

  # With MCP servers connected, the router also asks whether the request needs
  # them; their names make the question concrete.
  defp route_questions do
    case TinyAxe.MCP.running() do
      [] ->
        @route_questions

      servers ->
        Map.put(@route_questions, :tools, %{
          type: :noul,
          instructions:
            "Does the request need one of tiny-axe's connected services to act or look " <>
              "something up (#{Enum.join(servers, ", ")}), rather than only an answer, edits " <>
              "to project files, organising files, or shell commands?"
        })
    end
  end

  # Commands go to the Commander, file tasks (moving, organising, writing
  # documents) to the Organizer, and requests that need connected services to
  # the agent; when several look likely, the likeliest wins.
  defp task(route) do
    command = if config(:commands, true), do: Decider.p(route, :command) || 0, else: 0
    organize = if config(:file_ops, true), do: Decider.p(route, :organize) || 0, else: 0
    agent = if TinyAxe.Agent.available?(), do: Decider.p(route, :tools) || 0, else: 0

    [command: command, organize: organize, agent: agent]
    |> Enum.filter(fn {_task, p} -> p >= config(:route_threshold, 0.5) end)
    |> Enum.max_by(&elem(&1, 1), fn -> {:answer, 0} end)
    |> elem(0)
  end

  ## Location

  # When a request names another folder, the Decider picks it from real folders
  # (TinyAxe.Location.candidates/1), so the location is never a path a model made up.
  defp navigate(route, prompt, notify) do
    if Decider.yes?(route, :elsewhere, config(:route_threshold, 0.5)),
      do: go_to_named_folder(prompt, notify),
      else: :ok
  end

  defp go_to_named_folder(prompt, notify) do
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

    case Decider.decide(state, question) do
      {:ok, %{folder: %{choice: choice, probabilities: probs}}}
      when is_binary(choice) and choice != "(stay)" ->
        with true <- (probs[choice] || 0) >= config(:navigate_min, 0.4),
             {:ok, to} <- Location.cd(choice),
             true <- to != here do
          notify.({:moved, %{from: Ops.show(here), to: Ops.show(to), confidence: probs[choice]}})
        end

      {:ok, %{folder: %{choice: nil}}} ->
        notify.({:decider_unavailable, "picking the folder the request names"})

      {:ok, _stay} ->
        :ok

      {:error, _} ->
        notify.({:decider_unavailable, "picking the folder the request names"})
    end
  end

  @doc "Shared request context for routing, verification, and plan reviews."
  @spec context([Ollama.message()], String.t()) :: map()
  defdelegate context(history, prompt), to: RequestContext, as: :build

  defp config(key, default), do: Application.get_env(:tiny_axe, key, default)
end
