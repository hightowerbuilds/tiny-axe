defmodule TinyAxe.Capabilities do
  @moduledoc """
  What tiny-axe can and can't do with the shell, in plain words, for every
  model that needs to know: the Commander that plans commands, the answer
  route, the organizer and the router, and the agent with its `shell_run`
  tool (`TinyAxe.Agent.ShellTool`).

  It's generated from the lists and settings the code itself uses (the
  read-only list in `TinyAxe.Shell.ReadOnly`, what `TinyAxe.Shell` hides and
  keeps, the refusals in `TinyAxe.Commander.Validation`, `:command_timeout`),
  so it can't drift from what actually happens.
  """

  alias TinyAxe.Commander.Validation
  alias TinyAxe.Shell
  alias TinyAxe.Shell.ReadOnly

  # Shown as examples of what only looks; each must be on the list.
  @examples ~w(ls cat head tail wc grep rg find tree du df free ps pgrep lsof ss uname uptime
               which jq diff)

  @doc """
  The full description, for prompts that plan or talk about commands; with
  `:agent`, for the agent, which runs them itself with `shell_run`.
  """
  @spec shell(:planner | :agent) :: String.t()
  def shell(who \\ :planner) do
    {root, packages} = Validation.refused()

    """
    #{opening(who)}
    - Commands that only look run straight away, without asking: #{examples()}, git for \
    reading (#{git_reads()}), and `--version` of common programs. A command line only \
    looks when every command in it is on that list, joined by |, &&, || or ;, with no \
    redirection into a file and no $(…) or backticks. These run with the whole computer \
    read-only, and #{if who == :agent, do: "you get", else: "tiny-axe then reads"} their \
    output#{if who == :agent, do: "", else: " to answer"}.
    - Anything else (installing, building, testing, making, moving or deleting files, \
    git commit or push, stopping a process) is shown to the user first and runs only \
    if they approve. Approved commands can change the folder they run in; they can't \
    run in the home folder itself or a hidden folder, and other changes in the home \
    folder vanish when they end, except installs into #{installs()}, which persist.
    - Never: #{Enum.join(root, ", ")}, or system package managers \
    (#{packages |> Enum.filter(&(&1 in ~w(apt pacman dnf zypper apk))) |> Enum.join(", ")}, …): \
    the user runs those themselves.
    - Hidden from every command: #{hidden()}. Environment variables that look like \
    secrets (tokens, keys, passwords) are removed.
    - Processes: commands see the user's running processes (ps, pgrep) but not inside \
    them, so which program holds a port or a file isn't visible (lsof and ss -p show \
    nothing for them). kill, pkill and killall need approval, and never target \
    tiny-axe's own processes.
    - The network works. Nothing can answer a prompt (stdin is empty, CI=true), so \
    commands need flags that skip questions. A command is stopped after #{minutes()}, \
    and what it leaves running in the background stops when it ends.
    """
    |> String.trim()
  end

  defp opening(:planner) do
    """
    How tiny-axe runs shell commands (this is how it works; tell the user accurately):
    - tiny-axe runs commands when the user asks for something to be run or checked on \
    their computer: its command planner writes them, and each runs with `sh -c` as the \
    user, in a bubblewrap sandbox, in the current folder or a subfolder of it.\
    """
  end

  defp opening(:agent) do
    """
    You can run shell commands yourself with shell_run (this is how it works; tell the \
    user accurately):
    - Use it when the request needs something run or checked on the user's computer \
    (disk space, processes, versions, git, files' contents, installs, builds, tests). \
    Each command runs with `sh -c` as the user, in a bubblewrap sandbox, in the current \
    folder or the folder you give as cwd, and you get its exit status and output. Each \
    call starts afresh: a `cd` lasts only for that command line. Prefer one command line \
    that does what's needed over many small calls.\
    """
  end

  @doc "One paragraph, for a list of what tiny-axe can do."
  @spec summary() :: String.t()
  def summary do
    "It runs shell commands when the user asks for one to be run or something checked " <>
      "on their computer (disk space, processes, versions, git status, installs, builds, " <>
      "tests): commands that only look (#{Enum.join(Enum.take(examples_list(), 8), ", ")}, " <>
      "git status/log/diff, `--version`) run straight away in a read-only sandbox and " <>
      "tiny-axe answers from their output; anything else is shown for approval first and " <>
      "runs sandboxed, able to change only its folder (installs into #{installs(4)}, … " <>
      "persist). " <>
      "Never sudo or system package managers; secrets (keys, credentials, browser " <>
      "profiles, tiny-axe's own settings) are hidden from commands; each is stopped after " <>
      "#{minutes()}."
  end

  @doc "One paragraph on changing the desktop's look (`TinyAxe.Appearance`)."
  @spec appearance() :: String.t()
  def appearance do
    "It changes how the desktop and terminal look when asked: the theme, background, " <>
      "font and text size; the terminal's (Ghostty's) font size, padding, opacity, cursor " <>
      "and tabs; display scaling, brightness and night light; window gaps, borders, " <>
      "rounded corners, dimming, blur, animations and tiling layout; the bar. Those run " <>
      "without asking, and `/look undo` puts the last change back; `/look` lists the " <>
      "settings as they are now."
  end

  @doc """
  The user's tiny-axe account and website, for every model that talks with
  them (the answer route and the agent), so "the site", "my page" or "my
  username" mean something; "" while there's no account. From
  `TinyAxe.Account`, so it's the real one.
  """
  @spec account() :: String.t()
  def account do
    case TinyAxe.Account.current() do
      %{username: name, site: site} ->
        "The user's tiny-axe account is #{name}, on tiny-axe's website #{site}: " <>
          "\"the site\", \"the website\", \"my page\" or \"lobsterattack\" mean this. tiny-axe " <>
          "sends every chat there, searchable, for the user (and anyone they let in) to see " <>
          "after signing in. Their username (#{name}) isn't secret; " <>
          "their password is, and only they ever type it. To show them the site, open it in their " <>
          "own browser, already signed in (`/site`, or site_open for an agent; no password is " <>
          "needed), or give them the link. Never type into the site's sign-in form."

      nil ->
        ""
    end
  end

  @doc "The router's question: does the request want a command run?"
  @spec command_question() :: String.t()
  def command_question do
    "Does the user want tiny-axe to run a shell command for them, or to find out " <>
      "something about their computer that a command would show: disk space or folder " <>
      "sizes, memory or CPU, running processes or ports, system information, which " <>
      "version of a program is installed, git status, log, diff or branches; or to " <>
      "install packages, scaffold a project (e.g. Vite), or run build, test or dev tools? " <>
      "No if they only want to know which command to use, or ask what's in a folder or " <>
      "where a file is (the file organiser answers those)."
  end

  defp examples_list do
    %{any: any, flags: flags} = ReadOnly.commands()
    Enum.filter(@examples, &(&1 in any or &1 in flags))
  end

  defp examples, do: examples_list() |> Enum.map_join(", ", &"`#{&1}`")

  defp git_reads do
    git = ReadOnly.commands().git

    (Enum.filter(~w(status log diff show branch blame), &(&1 in git)) ++
       ["remote -v", "tag --list"])
    |> Enum.join(", ")
  end

  defp installs(limit \\ nil) do
    home = System.user_home!()

    Shell.install_folders()
    |> Enum.map(fn {path, _} ->
      if path == System.get_env("MIX_HOME"),
        do: "$MIX_HOME",
        else: String.replace_prefix(path, home, "~")
    end)
    |> then(&if(limit, do: Enum.take(&1, limit), else: &1))
    |> Enum.join(", ")
  end

  defp hidden do
    kinds =
      Shell.secret_places()
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()

    names = %{
      "keys" => "SSH and GPG keys, password stores and keyrings",
      "credentials" => "cloud, git and package-registry credentials",
      "browser profiles" => "browser profiles",
      "shell histories" => "shell histories",
      "tiny-axe's own settings, state and purchases" =>
        "tiny-axe's own settings, state, purchases and card data",
      "session sockets" => "the desktop session's sockets (keyring, SSH and GPG agents, D-Bus)"
    }

    kinds |> Enum.map(&Map.get(names, &1, &1)) |> Enum.join("; ")
  end

  defp minutes do
    ms = Application.get_env(:tiny_axe, :command_timeout, 600_000)

    case div(ms, 60_000) do
      0 -> "#{div(ms, 1000)} seconds"
      1 -> "1 minute"
      n -> "#{n} minutes"
    end
  end
end
