defmodule TinyAxe.Shell.Processes do
  @moduledoc """
  The process table (from `/proc`), for two jobs:

    * stopping a sandbox and everything it started (`kill_tree/1`,
      `kill_session/1`): approved commands share the PID namespace, so a
      command's children outlive it unless they're stopped
    * keeping commands from stopping tiny-axe itself (`guard/2`): `kill`,
      `pkill`, `killall`, `fuser -k` and `… | xargs kill` are checked against
      tiny-axe's own process, everything it started, and the processes it runs
      under (the terminal included)

  The guard works out targets cheaply: numbers on the line, `pgrep` for a
  `pkill` pattern, `fuser` without `-k`, process names for `killall`, and, for
  `kill $(…)` or `… | xargs kill`, the inner command's output when that
  command is read-only (run in the read-only sandbox). Targets it can't work
  out (variables, scripts, a non-read-only inner command) aren't checked; those
  commands still need the user's approval.
  """

  alias TinyAxe.Shell
  alias TinyAxe.Shell.ReadOnly

  @type entry :: %{ppid: integer(), pgrp: integer(), session: integer(), comm: String.t()}

  @doc "Every process: pid => ppid, process group, session and name."
  @spec table() :: %{integer() => entry()}
  def table do
    case File.ls("/proc") do
      {:ok, names} ->
        for name <- names,
            pid = parse_int(name),
            pid != nil,
            entry = stat(pid),
            entry != nil,
            into: %{},
            do: {pid, entry}

      _ ->
        %{}
    end
  end

  defp stat(pid) do
    with {:ok, text} <- File.read("/proc/#{pid}/stat"),
         [_, comm, rest] <- Regex.run(~r/\A\d+ \((.*)\) (.*)\z/s, text),
         [_state, ppid, pgrp, session | _] <- String.split(rest, " ") do
      %{
        ppid: String.to_integer(ppid),
        pgrp: String.to_integer(pgrp),
        session: String.to_integer(session),
        comm: comm
      }
    else
      _ -> nil
    end
  end

  @doc "`pid` and every process below it."
  @spec descendants(map(), integer()) :: MapSet.t()
  def descendants(table, pid) do
    children = Enum.group_by(table, fn {_pid, e} -> e.ppid end, fn {pid, _} -> pid end)
    walk([pid], children, MapSet.new())
  end

  defp walk([], _children, seen), do: seen

  defp walk([pid | rest], children, seen) do
    if MapSet.member?(seen, pid),
      do: walk(rest, children, seen),
      else: walk(Map.get(children, pid, []) ++ rest, children, MapSet.put(seen, pid))
  end

  defp ancestors(table, pid, acc \\ []) do
    case table[pid] do
      %{ppid: ppid} when ppid > 1 -> ancestors(table, ppid, [ppid | acc])
      _ -> acc
    end
  end

  @doc """
  tiny-axe's own OS process, everything below it, and the processes it runs
  under up to (not including) the init or `systemd` process: stopping any of
  these stops tiny-axe.
  """
  @spec protected(map()) :: MapSet.t()
  def protected(table \\ table()) do
    me = String.to_integer(System.pid())

    above =
      table
      |> ancestors(me)
      |> Enum.reject(&(table[&1].comm in ["systemd", "init"]))

    table |> descendants(me) |> MapSet.union(MapSet.new(above))
  end

  ## Stopping a sandbox

  @doc """
  Kills `os_pid` (a running bwrap), everything below it, and every process in
  a session one of those started (`--new-session`), so a command's background
  children go too. tiny-axe itself is never killed.
  """
  @spec kill_tree(integer()) :: :ok
  def kill_tree(os_pid) do
    table = table()
    tree = descendants(table, os_pid)

    sessions =
      for {pid, %{session: sid}} <- table,
          MapSet.member?(tree, pid),
          sid == pid,
          into: MapSet.new(),
          do: sid

    in_sessions = for {pid, %{session: sid}} <- table, MapSet.member?(sessions, sid), do: pid
    kill(MapSet.to_list(tree) ++ in_sessions)
  end

  @doc "Kills every process left in session `sid` (a sandbox's shell, now finished)."
  @spec kill_session(integer()) :: :ok
  def kill_session(sid) when is_integer(sid) and sid > 1 do
    kill(for {pid, %{session: ^sid}} <- table(), do: pid)
  end

  def kill_session(_sid), do: :ok

  defp kill(pids) do
    me = String.to_integer(System.pid())

    case pids |> Enum.uniq() |> Enum.reject(&(&1 in [me, 0, 1])) do
      [] ->
        :ok

      pids ->
        System.cmd("kill", ["-KILL" | Enum.map(pids, &Integer.to_string/1)],
          stderr_to_stdout: true
        )

        :ok
    end
  end

  ## The guard

  @wrappers ~w(xargs timeout nohup env exec setsid nice ionice time command builtin)

  @doc """
  `:ok`, or `{:error, problem}` when `command` would signal tiny-axe's own
  processes (see the module doc for what it can tell). `dir` is where an
  inner read-only command would run.
  """
  @spec guard(String.t(), String.t()) :: :ok | {:error, String.t()}
  def guard(command, dir) do
    case ReadOnly.parse(command) do
      {:ok, simples} ->
        simples
        |> Enum.with_index()
        |> Enum.find_value(:ok, fn {simple, i} ->
          case check(simple, Enum.take(simples, i), dir, command) do
            :ok -> nil
            error -> error
          end
        end)

      {:error, _} ->
        # Can't read it as words; catch the obvious.
        if command =~ ~r/\b(kill|pkill|killall|fuser)\b/ and
             command =~ ~r/\bbeam|tiny.?axe|\s-1\b/,
           do: {:error, refusal(command)},
           else: :ok
    end
  end

  defp check(%{words: words} = simple, before, dir, command) do
    case words |> Enum.map(& &1.text) |> killer() do
      nil ->
        :ok

      {name, at} ->
        args = Enum.drop(words, at + 1)
        targets = targets(name, args, simple, before, dir)
        verdict(targets, String.trim(command))
    end
  end

  # Where kill/pkill/killall/fuser is the command, or run by a wrapper
  # (`xargs kill`, `timeout 5 pkill …`).
  defp killer([name | _]) when name in ~w(kill pkill killall fuser), do: {name, 0}

  defp killer([wrapper | rest]) when wrapper in @wrappers do
    case Enum.find_index(rest, &(&1 in ~w(kill pkill killall))) do
      nil -> nil
      i -> {Enum.at(rest, i), i + 1}
    end
  end

  defp killer(_), do: nil

  defp verdict(:unknown, _shown), do: :ok

  defp verdict(pids, shown) do
    table = table()
    protected = protected(table)

    hit =
      Enum.find(pids, fn
        -1 -> true
        pid when pid > 0 -> MapSet.member?(protected, pid)
        group when group < -1 -> Enum.any?(protected, &(table[&1] && table[&1].pgrp == -group))
        _ -> false
      end)

    case hit do
      nil -> :ok
      -1 -> {:error, "`#{shown}` would signal every one of your processes, tiny-axe included."}
      pid -> {:error, refusal(shown, pid, table)}
    end
  end

  defp refusal(shown),
    do: "`#{shown}` could stop tiny-axe itself; leave tiny-axe's own processes alone."

  defp refusal(shown, pid, table) do
    name = if table[abs(pid)], do: " (#{table[abs(pid)].comm})", else: ""

    "`#{shown}` would stop process #{abs(pid)}#{name}, which tiny-axe needs (tiny-axe itself, " <>
      "something it started, or what it runs in); leave those alone."
  end

  ## Working out targets

  defp targets("kill", args, simple, before, dir) do
    # The first option is the signal (-9, -KILL, -s KILL); the rest are targets.
    args =
      case args do
        [%{text: t}, _ | rest] when t in ["-s", "-n", "--signal"] -> rest
        [%{text: t} | _] when t in ["-l", "-L", "--list", "--table"] -> []
        [%{text: "--"} | rest] -> rest
        [%{text: "-" <> _} | rest] -> rest
        args -> args
      end

    args = Enum.drop_while(args, &(&1.text == "--"))

    cond do
      from_stdin?(simple, args) -> pipeline_pids(before, dir)
      true -> word_pids(args, dir)
    end
  end

  defp targets("pkill", args, _simple, _before, _dir) do
    if Enum.any?(args, &(&1.expansions != [])) do
      :unknown
    else
      args
      |> Enum.map(& &1.text)
      |> Enum.reject(
        &(&1 =~ ~r/\A-(\d+|SIG[A-Z0-9+-]+|[A-Z][A-Z0-9+-]*)\z/ or &1 in ["-e", "--echo"])
      )
      |> drop_signal_option()
      |> pgrep()
    end
  end

  defp targets("killall", args, _simple, _before, _dir) do
    texts = Enum.map(args, & &1.text)
    regex? = Enum.any?(texts, &(&1 in ["-r", "--regexp"]))
    names = operands(texts, ~w(-s --signal -u --user -o --older-than -y --younger-than))
    table = table()

    pids =
      for {pid, e} <- table, name <- names, killall_match?(e.comm, name, regex?), do: pid

    if Enum.any?(args, &(&1.expansions != [])), do: :unknown, else: pids
  end

  defp targets("fuser", args, _simple, _before, _dir) do
    texts = Enum.map(args, & &1.text)

    kills? =
      Enum.any?(
        texts,
        &(&1 == "--kill" or (&1 =~ ~r/\A-[a-zA-Z]+\z/ and String.contains?(&1, "k")))
      )

    cond do
      not kills? ->
        []

      Enum.any?(args, &(&1.expansions != [])) ->
        :unknown

      System.find_executable("fuser") == nil ->
        :unknown

      true ->
        texts
        |> Enum.map(&String.replace(&1, ~r/\A(-[a-zA-Z]*)k/, "\\1"))
        |> Enum.reject(&(&1 in ["-", "--kill"]))
        |> fuser()
    end
  end

  # `xargs kill`: no targets of its own, so they come down the pipe.
  defp from_stdin?(%{words: [%{text: "xargs"} | _]}, _args), do: true
  defp from_stdin?(_simple, _args), do: false

  defp word_pids(args, dir) do
    Enum.reduce_while(args, [], fn
      %{expansions: [], text: text}, acc ->
        case Integer.parse(text) do
          {n, ""} -> {:cont, [n | acc]}
          _ -> {:cont, acc}
        end

      %{expansions: expansions}, acc ->
        case inner_pids(expansions, dir) do
          :unknown -> {:halt, :unknown}
          pids -> {:cont, pids ++ acc}
        end
    end)
  end

  defp inner_pids(expansions, dir) do
    Enum.reduce_while(expansions, [], fn
      {:subst, inner}, acc ->
        case run_read_only(inner, dir) do
          :unknown -> {:halt, :unknown}
          pids -> {:cont, pids ++ acc}
        end

      _other, _acc ->
        {:halt, :unknown}
    end)
  end

  # The commands piped into this one, if they're a read-only pipeline.
  defp pipeline_pids(before, dir) do
    stage =
      before
      |> Enum.reverse()
      |> Enum.reduce_while([], fn simple, acc ->
        if simple.joined_by == "|", do: {:cont, [simple | acc]}, else: {:halt, [simple | acc]}
      end)

    if stage == [] or Enum.any?(stage, fn s -> Enum.any?(s.words, &(&1.expansions != [])) end) do
      :unknown
    else
      stage
      |> Enum.map_join(" | ", fn s -> Enum.map_join(s.words, " ", &quote_word(&1.text)) end)
      |> run_read_only(dir)
    end
  end

  defp run_read_only(line, dir) do
    with {:read_only, _} <- ReadOnly.classify(line),
         true <- Shell.available?() and File.dir?(dir),
         {:ok, _status, output} <-
           Shell.run(dir, line, fn _ -> :ok end, mode: :read_only, timeout: 15_000) do
      ints(output)
    else
      _ -> :unknown
    end
  end

  defp pgrep(args) do
    case System.find_executable("pgrep") do
      nil ->
        :unknown

      pgrep ->
        case System.cmd(pgrep, args, stderr_to_stdout: true) do
          {out, 0} -> ints(out)
          {_out, 1} -> []
          _ -> :unknown
        end
    end
  end

  defp fuser(args) do
    {out, _} = System.cmd("fuser", args, stderr_to_stdout: false)
    ints(out)
  rescue
    _ -> :unknown
  end

  defp drop_signal_option(["--signal", _ | rest]), do: rest
  defp drop_signal_option(["--signal=" <> _ | rest]), do: rest
  defp drop_signal_option(args), do: args

  defp killall_match?(comm, name, true) do
    case Regex.compile(name) do
      {:ok, re} -> Regex.match?(re, comm)
      _ -> true
    end
  end

  defp killall_match?(comm, name, false),
    do: comm == name or (String.length(name) > 15 and String.starts_with?(name, comm))

  defp operands(args, value_flags) do
    {operands, _} =
      Enum.reduce(args, {[], false}, fn arg, {acc, skip?} ->
        cond do
          skip? -> {acc, false}
          arg in value_flags -> {acc, true}
          String.starts_with?(arg, "-") -> {acc, false}
          true -> {[arg | acc], false}
        end
      end)

    operands
  end

  # Process ids in a command's output (fuser adds letters: 1234c).
  defp ints(text) do
    ~r/\b(\d+)[a-zA-Z]?\b/ |> Regex.scan(text) |> Enum.map(fn [_, n] -> String.to_integer(n) end)
  end

  defp parse_int(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp quote_word(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"
end
