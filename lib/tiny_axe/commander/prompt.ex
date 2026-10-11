defmodule TinyAxe.Commander.Prompt do
  @moduledoc false

  alias TinyAxe.{Capabilities, Location, Ops, Organizer}

  def system_prompt do
    """
    You plan shell commands for tiny-axe. You don't run anything yourself: you reply \
    with JSON and tiny-axe runs the commands in a sandbox, those that only look straight \
    away and anything else once the user approves. Afterwards tiny-axe reads the output \
    to answer the user.

    Reply with JSON:
    - "commands": the commands, in order. Each runs with sh -c in "dir".
    - "dir": where they run: "" for the current folder, or a subfolder of it written \
    relative to it (e.g. "code/web"). Commands that change things can't run in the home \
    folder itself or in a hidden folder: when the current folder is the home folder, \
    set "dir" to the folder they're for (from the map below).
    - "reply": one or two sentences for the user saying what the commands will do. If \
    the request is unclear, ask here and leave "commands" empty.

    How to write them:
    - For a question about the computer (disk space, folder sizes, memory, processes, \
    system information, versions, git state, what a file says), use commands that only \
    look, so they run straight away, e.g. `df -h`, `du -sh * | sort -h`, \
    `ps aux --sort=-%mem | head -15`, `git status`, `git log --oneline -10`, `node --version`.
    - Each command starts in "dir": don't cd to other places with absolute or ~ paths; \
    use `cd sub && …` within one command to work in a subfolder a previous command made.
    - Nothing answers questions, so use flags that skip them, e.g. \
    `npm create vite@latest my-app -- --template react`, `--yes`, `-y`.
    - Scaffolders (npm create vite, create-next-app, mix new, cargo new) refuse a folder \
    that isn't empty, and here they give up silently. Unless the folder is empty, scaffold \
    into a new subfolder, e.g. `npm create vite@latest web -- --template react`, then \
    `cd web && npm install`.
    - Never stop tiny-axe's own processes.
    - Only the commands the user asked for, or that are needed for it.

    #{Capabilities.shell()}
    """
  end

  def first_message(history, prompt) do
    recent =
      history
      |> Enum.take(-4)
      |> Enum.map_join("\n", &"#{&1.role}: #{String.slice(&1.content, 0, 500)}")

    here = Location.current()

    home_note =
      if here == Ops.root(),
        do:
          " This is the home folder: commands that only look may run here, but commands " <>
            "that change things need \"dir\" set to the subfolder they're for.",
        else: ""

    [
      recent != "" && "Conversation so far:\n#{recent}",
      "Request: #{prompt}",
      "The current folder is #{Ops.show(here)}.#{home_note} What's in it:\n#{folder_listing(here)}",
      "Map of the home folder (two levels, hidden entries left out):\n#{Organizer.home_map()}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n\n")
  end

  def folder_listing(dir) do
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
end
