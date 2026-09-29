defmodule TinyAxe.Commander do
  @moduledoc """
  Turns a request like "install Vite with the React template in my tiny-app
  repo" into shell commands for the user to approve. Nothing runs here:
  approved commands are run by `execute/2`, one at a time, each in the
  `TinyAxe.Shell` sandbox where only the working folder can change.

  1. **Plan** — the model writes the commands, answering in a fixed JSON shape.
     They run in the current folder (`TinyAxe.Location`), which code tracks: the
     model never picks the folder, because given `~/code/app` a small model will
     "expand" it to a home folder that doesn't exist.
  2. **Check** — the folder must exist, be inside the home folder or project,
     not be the home folder itself, and not be hidden; `sudo` is refused.
     Problems go back to the model.
  3. **Review** — the Decider asks, per command, whether it's needed for what
     the user asked, and whether the commands together would do it. The plan's
     score is its weakest link; a doubtful plan goes back once with reasons.

  Events: `{:command_problems, [text]}`, `{:review, p}`, then
  `{:command_plan, %{request:, dir:, commands: [%{command:, review:}], review:}}`
  just before `:done`.
  """

  alias TinyAxe.{Decider, Files, Location, Ollama, Ops, Organizer, Shell}

  @max_rounds 4

  @schema %{
    type: "object",
    properties: %{
      commands: %{type: "array", items: %{type: "string"}},
      reply: %{type: "string"}
    },
    required: ["commands", "reply"]
  }

  @spec run([Ollama.message()], String.t(), (term() -> any())) :: :ok
  def run(history, prompt, notify) do
    notify.({:stage, "planning commands…"})

    messages = [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: first_message(history, prompt)}
    ]

    case plan(messages, prompt, notify, 1, false) do
      {:ok, plan, reply} ->
        notify.({:command_plan, plan})
        notify.({:done, summary(reply, plan)})

      {:reply, reply} ->
        notify.({:done, reply})

      {:error, reason} ->
        notify.({:error, reason})
    end

    :ok
  end

  defp plan(messages, _prompt, _notify, round, _reviewed?) when round > @max_rounds do
    problems = List.last(messages).content |> String.split("\n\n") |> hd()

    {:reply,
     "I couldn't put together commands that work. The last attempt's problems:\n\n" <>
       problems <> "\n\nCould you say more precisely what you'd like?"}
  end

  defp plan(messages, prompt, notify, round, reviewed?) do
    with {:ok, %{"message" => %{"content" => json}}} <-
           Ollama.chat(messages, format: @schema, options: [temperature: 0.2]),
         {:ok, answer} <- JSON.decode(json) do
      commands = answer |> Map.get("commands", []) |> List.wrap() |> Enum.map(&String.trim/1)
      commands = Enum.reject(commands, &(&1 == ""))
      reply = Map.get(answer, "reply", "")
      messages = messages ++ [%{role: "assistant", content: json}]

      if commands == [] do
        {:reply, reply}
      else
        case check(Location.current(), commands) do
          {:ok, dir} ->
            review(dir, commands, reply, messages, prompt, notify, round, reviewed?)

          {:error, problems} ->
            notify.({:command_problems, problems})

            fix =
              "tiny-axe can't run this as written:\n" <> Enum.map_join(problems, "\n", &"- #{&1}")

            plan(
              messages ++ [user(fix <> "\n\nReply with corrected JSON.")],
              prompt,
              notify,
              round + 1,
              reviewed?
            )
        end
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :bad_plan_json}
    end
  end

  @doc """
  Checks the working folder and commands. Returns the folder as an absolute
  path, or the problems in plain words.
  """
  @spec check(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, [String.t()]}
  def check(dir, commands) do
    abs = Ops.resolve(dir)

    problems =
      [
        dir == "" && "Give the working folder in \"dir\".",
        (dir != "" and not File.dir?(abs)) &&
          "#{Ops.show(abs)} isn't an existing folder. Use its parent and create it with a command.",
        (File.dir?(abs) and not workable?(abs)) &&
          "Commands can't run in #{Ops.show(abs)}: pick a folder inside the home folder " <>
            "(not the home folder itself) or the project, outside hidden folders."
      ] ++
        Enum.map(commands, fn c ->
          c =~ ~r/(^|[\s;&|(])(sudo|su|doas)\s/ &&
            "#{inspect(c)} uses sudo/su/doas; commands run as the user, in a sandbox."
        end) ++
        Enum.map(commands, fn c ->
          (scaffolds_here?(c) and File.dir?(abs) and visible_entries(abs) != []) &&
            "#{inspect(c)} scaffolds into #{Ops.show(abs)}, which isn't empty " <>
              "(#{abs |> visible_entries() |> Enum.take(3) |> Enum.join(", ")}), so it would " <>
              "cancel. Scaffold into a new subfolder instead, e.g. `npm create vite@latest web -- --template react`."
        end)

    case Enum.filter(problems, & &1) do
      [] -> {:ok, abs}
      problems -> {:error, problems}
    end
  end

  # `npm create vite@latest . …`, `npx create-next-app .`, `yarn create vite .`: a
  # scaffolder aimed at the working folder itself (as opposed to a new subfolder).
  defp scaffolds_here?(command) do
    command =~
      ~r/\b(npm|pnpm|yarn|bun|npx|bunx)\s+(create|init)?\s*[\w@\/.-]*create[\w@\/.-]*\s+\.(\s|$)/ or
      command =~ ~r/\b(npm|pnpm|yarn|bun)\s+(create|init)\s+[\w@\/.-]+\s+\.(\s|$)/
  end

  defp visible_entries(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.reject(&String.starts_with?(&1, ".")) |> Enum.sort()
      _ -> []
    end
  end

  # The home folder itself would make every file writable; any folder below it is fine.
  defp workable?(abs), do: abs == Files.root() or Ops.changeable?(abs)

  defp review(dir, commands, reply, messages, prompt, notify, round, reviewed?) do
    listing =
      commands |> Enum.with_index(1) |> Enum.map_join("\n", fn {c, i} -> "#{i}. $ #{c}" end)

    questions =
      commands
      |> Enum.with_index()
      |> Map.new(fn {c, i} ->
        {:"cmd_#{i}",
         %{type: :noul, instructions: "Is this command needed for what the user asked: $ #{c}"}}
      end)
      |> Map.put(:complete, %{
        type: :noul,
        instructions: "Would running these commands, in this order, do everything the user asked?"
      })
      |> Map.put(:right_folder, %{
        type: :noul,
        instructions:
          "Is the working folder the right place to run these, given the request and " <>
            "the current folder?"
      })

    state = %{
      request: prompt,
      working_folder: Ops.show(dir),
      current_folder: Ops.show(Location.current()),
      commands: listing,
      folder_contents: folder_listing(dir),
      how_commands_run:
        "Each command runs with sh -c in the working folder; `cd x && ...` works within " <>
          "one command. Nothing answers prompts, so commands use flags that skip questions."
    }

    case Decider.decide(state, questions) do
      {:ok, answers} ->
        scores = Enum.map(Enum.with_index(commands), fn {_, i} -> answers[:"cmd_#{i}"].noul end)
        score = Enum.min([answers.complete.noul, answers.right_folder.noul | scores])
        notify.({:review, score})

        plan = %{
          request: prompt,
          dir: dir,
          commands: Enum.zip_with(commands, scores, &%{command: &1, review: &2}),
          review: score
        }

        if score < 0.5 and not reviewed? do
          doubtful =
            for {c, p} <- Enum.zip(commands, scores),
                p < 0.5,
                do: "- probably not needed (#{pct(p)}): $ #{c}"

          missing =
            if answers.complete.noul < 0.5,
              do: ["- together they may not do everything asked (#{pct(answers.complete.noul)})"],
              else: []

          missing =
            if answers.right_folder.noul < 0.5,
              do:
                missing ++
                  [
                    "- #{Ops.show(dir)} may be the wrong folder (#{pct(answers.right_folder.noul)})"
                  ],
              else: missing

          feedback =
            "A reviewer checked the commands against the request:\n" <>
              Enum.join(doubtful ++ missing, "\n") <> "\n\nReply with corrected JSON."

          plan(messages ++ [user(feedback)], prompt, notify, round + 1, true)
        else
          {:ok, plan, reply}
        end

      _ ->
        {:ok,
         %{
           request: prompt,
           dir: dir,
           commands: Enum.map(commands, &%{command: &1, review: nil}),
           review: 0.5
         }, reply}
    end
  end

  ## Running approved commands

  @doc """
  Runs an approved plan's commands in order, stopping at the first failure.
  Events: `{:cmd_start, i, command}`, `{:cmd_os_pid, pid}`, `{:cmd_output, text}`,
  `{:cmd_exit, i, status}`, then `{:cmds_done, [%{command:, status:, output:}]}`
  and `{:cmds_checked, probability}`.

  Exit codes aren't enough (create-vite exits 0 after "Operation cancelled"), so
  the Decider also judges from the output whether the commands did what was asked.
  """
  @spec execute(map(), (term() -> any())) :: :ok
  def execute(plan, notify) do
    results =
      plan.commands
      |> Enum.with_index()
      |> Enum.reduce_while([], fn {%{command: c}, i}, acc ->
        notify.({:cmd_start, i, c})

        case Shell.run(plan.dir, c, &notify.({:cmd_output, &1}),
               on_start: &notify.({:cmd_os_pid, &1})
             ) do
          {:ok, status, output} ->
            notify.({:cmd_exit, i, status})
            result = %{command: c, status: status, output: output}
            if status == 0, do: {:cont, [result | acc]}, else: {:halt, [result | acc]}

          {:error, reason} ->
            notify.({:cmd_exit, i, reason})
            {:halt, [%{command: c, status: reason, output: ""} | acc]}
        end
      end)
      |> Enum.reverse()

    notify.({:cmds_done, results})
    follow(plan.dir, results, notify)
    check? = Application.get_env(:tiny_axe, :check_command_outcome, true)
    notify.({:cmds_checked, if(check?, do: outcome(plan.request, results))})
    :ok
  end

  # The location follows the commands: to the folder they ran in, or, if the last
  # one succeeded and began `cd x && …`, into x (so after
  # `cd web && npm install`, "start the dev server" means in web/).
  defp follow(dir, results, notify) do
    from = Location.current()

    to =
      with %{status: 0, command: c} <- List.last(results),
           [_, sub] <- Regex.run(~r/\A\s*cd\s+("[^"]+"|'[^']+'|\S+)\s*&&/, c),
           abs = Path.expand(String.trim(sub, "\"") |> String.trim("'"), dir),
           true <- File.dir?(abs) do
        abs
      else
        _ -> dir
      end

    if to != from do
      Location.set(to)
      notify.({:moved, %{from: Ops.show(from), to: Ops.show(to), confidence: nil}})
    end
  end

  defp outcome(request, results) do
    ran =
      Enum.map_join(results, "\n\n", fn r ->
        tail = r.output |> String.split("\n") |> Enum.take(-30) |> Enum.join("\n")
        "$ #{r.command}\n(exit status: #{r.status})\n#{tail}"
      end)

    question = %{
      worked: %{
        type: :noul,
        instructions:
          "Judging by the commands' output (not just their exit status), did they do what " <>
            "the user asked?"
      }
    }

    case Decider.decide(%{request: request, commands_and_output: ran}, question) do
      {:ok, %{worked: %{noul: p}}} -> p
      _ -> nil
    end
  end

  ## What the model sees

  defp system_prompt do
    """
    You plan shell commands for tiny-axe. You don't run anything yourself: you reply \
    with JSON, the user approves the commands, and tiny-axe runs them.

    Reply with JSON:
    - "commands": the commands, in order. Each runs with sh -c in the current folder, \
    which tiny-axe tracks for you: don't cd to other places with absolute or ~ paths; \
    use `cd sub && …` to work in a subfolder of it.
    - "reply": one or two sentences for the user saying what the commands will do once \
    approved. If the request is unclear, ask here and leave "commands" empty.

    How commands run:
    - In a sandbox: only the current folder and what's inside it can be changed; the network works.
    - Nothing answers questions, so use flags that skip them, e.g. \
    `npm create vite@latest my-app -- --template react`, `--yes`, `-y`.
    - Each command starts in the current folder; use `cd sub && …` within one command \
    to work in a subfolder a previous command made.
    - No sudo. Global installs (npm -g, pip --user) don't persist; install into the project.
    - Scaffolders (npm create vite, create-next-app, mix new, cargo new) refuse a folder \
    that isn't empty, and here they give up silently. Unless the current folder is empty, scaffold into \
    a new subfolder, e.g. `npm create vite@latest web -- --template react`, then \
    `cd web && npm install`.
    - Only the commands the user asked for, or that are needed for it.
    """
  end

  defp first_message(history, prompt) do
    recent =
      history
      |> Enum.take(-4)
      |> Enum.map_join("\n", &"#{&1.role}: #{String.slice(&1.content, 0, 500)}")

    here = Location.current()

    [
      recent != "" && "Conversation so far:\n#{recent}",
      "Request: #{prompt}",
      "The current folder is #{Ops.show(here)}. What's in it:\n#{folder_listing(here)}",
      "Map of the home folder (two levels, hidden entries left out):\n#{Organizer.home_map()}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n\n")
  end

  defp folder_listing(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.take(60)
        |> Enum.map_join(
          "\n",
          &("  " <> &1 <> if(File.dir?(Path.join(dir, &1)), do: "/", else: ""))
        )

      _ ->
        "  (can't list)"
    end
  end

  defp summary(reply, plan) do
    commands = Enum.map_join(plan.commands, "\n", &"$ #{&1.command}")

    "#{reply}\n\n**Commands** (waiting for your approval, in #{Ops.show(plan.dir)}):\n\n```console\n#{commands}\n```"
  end

  defp user(content), do: %{role: "user", content: content}
  defp pct(p), do: "#{round(p * 100)}%"
end
