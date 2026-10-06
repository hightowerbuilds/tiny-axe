defmodule TinyAxe.Commander.Prompt do
  @moduledoc false

  alias TinyAxe.{Location, Ops, Organizer}

  def system_prompt do
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

  def first_message(history, prompt) do
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
