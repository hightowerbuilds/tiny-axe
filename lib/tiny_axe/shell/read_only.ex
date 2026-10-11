defmodule TinyAxe.Shell.ReadOnly do
  @moduledoc """
  Decides whether a command line only looks: if so, tiny-axe runs it without
  asking (`TinyAxe.Shell`'s `:read_only` mode, where nothing can be written
  anyway). Anything that doesn't parse cleanly, or uses anything not on the
  list, is not read-only, and asks first.

  A line is read-only when:

    * it parses with `parse/1` (quotes and escapes; commands joined only by
      `|`, `&&`, `||`, `;` or newlines; no subshells, background `&`,
      here-documents or process substitution)
    * no word expands at run time: no `$VAR`, `$(…)` or backticks
    * no redirection writes a file: only `2>&1`-style copies, `> /dev/null`,
      and `< file` (reading) are allowed
    * no command starts with a variable assignment (`FOO=1 cmd`)
    * every command is on the list (`commands/0`), by its bare name, with its
      subcommands and flags allowed (no `find -exec`, `sort -o`, `git -c`, …);
      a command with forbidden flags also may not use unquoted globs or
      braces, which could expand to such a flag

  Long options are refused by prefix too (`--out` for `--output`), since GNU
  and git accept abbreviations. When in doubt, the answer is "changes".
  """

  @typedoc "A word: its literal text, and any run-time expansions in it."
  @type word :: %{text: String.t(), expansions: [term()], glob?: boolean(), quoted?: boolean()}
  @type simple :: %{
          words: [word()],
          redirects: [{String.t(), String.t() | nil, word() | nil}],
          joined_by: String.t() | nil,
          background?: boolean()
        }

  ## The list

  # Commands that only read, whatever their flags.
  @any ~w(ls cat head wc stat du df free uptime uname whoami id groups which type pwd echo
          printf cut tr jq diff cmp comm basename dirname realpath readlink nproc lscpu lsblk
          findmnt lsusb lspci ps pgrep lsof netstat nl rev tac column fold fmt paste join
          expand unexpand seq md5sum sha1sum sha256sum sha512sum b2sum cksum numfmt printenv
          locale arch cal getent grep egrep fgrep od hexdump strings whereis w who vmstat
          true false locate plocate)

  # Commands that only read unless given one of these flags (short letters,
  # long options by prefix, whole single-dash words).
  @flags %{
    "tail" => {"fF", ~w(--follow --retry), []},
    "sort" => {"o", ~w(--output --compress-program), []},
    "date" => {"s", ~w(--set), []},
    "file" => {"C", ~w(--compile), []},
    "tree" => {"oR", ~w(--output), []},
    "fd" => {"xX", ~w(--exec --exec-batch), []},
    "fdfind" => {"xX", ~w(--exec --exec-batch), []},
    "rg" => {"", ~w(--pre --hostname-bin), []},
    "ss" => {"KDN", ~w(--kill --diag --net), []},
    "journalctl" =>
      {"f", ~w(--follow --vacuum-size --vacuum-time --vacuum-files --rotate --flush --sync
          --relinquish-var --smart-relinquish-var --setup-keys --update-catalog --cursor-file),
       []},
    "find" => {"", [], ~w(-exec -execdir -ok -okdir -delete -fprint -fprint0 -fprintf -fls)}
  }

  # `X --version` and the like, for common tools: the only argument allowed.
  @versions %{
    "node" => ~w(--version -v),
    "npm" => ~w(--version -v),
    "npx" => ~w(--version),
    "pnpm" => ~w(--version -v),
    "yarn" => ~w(--version -v),
    "bun" => ~w(--version),
    "deno" => ~w(--version),
    "python" => ~w(--version -V),
    "python3" => ~w(--version -V),
    "pip" => ~w(--version -V),
    "pip3" => ~w(--version -V),
    "pipx" => ~w(--version),
    "uv" => ~w(--version),
    "poetry" => ~w(--version),
    "ruby" => ~w(--version -v),
    "gem" => ~w(--version),
    "bundle" => ~w(--version),
    "cargo" => ~w(--version -V),
    "rustc" => ~w(--version -V),
    "rustup" => ~w(--version -V),
    "go" => ~w(version),
    "elixir" => ~w(--version -v),
    "mix" => ~w(--version -v),
    "gcc" => ~w(--version),
    "g++" => ~w(--version),
    "cc" => ~w(--version),
    "clang" => ~w(--version),
    "make" => ~w(--version),
    "cmake" => ~w(--version),
    "ninja" => ~w(--version),
    "java" => ~w(--version -version),
    "javac" => ~w(--version -version),
    "gh" => ~w(--version),
    "bwrap" => ~w(--version),
    "curl" => ~w(--version),
    "wget" => ~w(--version),
    "ssh" => ~w(-V),
    "tmux" => ~w(-V),
    "bash" => ~w(--version),
    "zsh" => ~w(--version),
    "fish" => ~w(--version),
    "nvim" => ~w(--version),
    "vim" => ~w(--version),
    "zig" => ~w(version),
    "perl" => ~w(--version -v),
    "php" => ~w(--version -v),
    "psql" => ~w(--version),
    "sqlite3" => ~w(--version),
    "ffmpeg" => ~w(-version),
    "ffprobe" => ~w(-version),
    "tar" => ~w(--version),
    "gzip" => ~w(--version),
    "kubectl" => ~w(version),
    "terraform" => ~w(version --version)
  }

  # Commands with their own rules (below).
  @special ~w(git ip sed cd command env hostname nvidia-smi ollama docker podman mise uniq)

  @git_globals ~w(--no-pager --no-optional-locks --literal-pathspecs --glob-pathspecs
                  --noglob-pathspecs --icase-pathspecs --no-replace-objects --bare)
  @git_valued ~w(-C --git-dir --work-tree)
  @git_deny ~w(--output --ext-diff --textconv --open-files-in-pager --exec --upload-pack
               --receive-pack --filters)
  @git_plain ~w(status log diff show shortlog whatchanged blame annotate describe rev-parse
                rev-list ls-files ls-tree cat-file show-ref for-each-ref merge-base name-rev
                count-objects grep version diff-tree diff-files diff-index check-ignore
                check-attr)

  @doc "The commands that can be read-only, by name, for describing them."
  @spec commands() :: %{atom() => [String.t()]}
  def commands do
    %{
      any: @any,
      flags: @flags |> Map.keys() |> Enum.sort(),
      special: @special,
      versions: @versions |> Map.keys() |> Enum.sort(),
      git: @git_plain ++ ~w(branch tag remote stash reflog worktree submodule config)
    }
  end

  ## Classifying

  @doc """
  `{:read_only, commands}` (each command as its words) when every command in
  `line` only looks, else `{:changes, reason}` saying what isn't.

      iex> TinyAxe.Shell.ReadOnly.classify("git status && df -h")
      {:read_only, [["git", "status"], ["df", "-h"]]}

      iex> TinyAxe.Shell.ReadOnly.classify("ls > out.txt")
      {:changes, "writes to a file (> out.txt)"}
  """
  @spec classify(String.t()) :: {:read_only, [[String.t()]]} | {:changes, String.t()}
  def classify(line) when is_binary(line) do
    with {:ok, commands} <- parse(line),
         :ok <- nonempty(commands),
         :ok <- each(commands, &check_command/1) do
      {:read_only, Enum.map(commands, fn c -> Enum.map(c.words, & &1.text) end)}
    else
      {:error, reason} -> {:changes, reason}
    end
  end

  @doc "Whether every line in `lines` is read-only (and there is at least one)."
  @spec all?([String.t()]) :: boolean()
  def all?([]), do: false
  def all?(lines), do: Enum.all?(lines, &match?({:read_only, _}, classify(&1)))

  defp nonempty([]), do: {:error, "is empty"}
  defp nonempty(_), do: :ok

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp check_command(%{background?: true}), do: {:error, "runs something in the background (&)"}

  defp check_command(%{words: words, redirects: redirects}) do
    with :ok <- each(redirects, &check_redirect/1),
         :ok <- each(words, &literal/1),
         [name | args] <- words,
         :ok <- not_assignment(name.text) do
      check_name(name, Enum.map(args, & &1.text), Enum.any?(args, & &1.glob?))
    else
      [] -> {:error, "has a redirection without a command"}
      error -> error
    end
  end

  defp literal(%{expansions: []}), do: :ok

  defp literal(_word), do: {:error, "uses $… or `…`, which expand when it runs"}

  # Copies between file descriptors (`2>&1`; but `>&file` writes a file),
  # discarding into /dev/null, and reading a file.
  defp check_redirect({op, _fd, %{text: text, expansions: []}}) when op in [">&", "<&"] do
    if text =~ ~r/\A(\d+|-)\z/, do: :ok, else: {:error, "writes to a file (#{op}#{text})"}
  end

  defp check_redirect({op, _fd, %{text: "/dev/null", expansions: []}})
       when op in [">", ">>", "&>", "&>>"],
       do: :ok

  defp check_redirect({"<", _fd, %{text: text, glob?: false, expansions: []}}) when text != "",
    do: :ok

  defp check_redirect({op, _fd, target}) when op in [">", ">>", ">|", "&>", "&>>"],
    do: {:error, "writes to a file (#{op} #{target && target.text})"}

  defp check_redirect({op, _fd, _target}), do: {:error, "uses the #{op} redirection"}

  defp not_assignment(name) do
    if name =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*=/,
      do: {:error, "sets a variable for a command (#{name})"},
      else: :ok
  end

  defp check_name(%{text: name, quoted?: _}, args, glob?) do
    cond do
      String.contains?(name, "/") ->
        {:error, "runs a program by its path (#{name}), not by name"}

      name in @any ->
        :ok

      Map.has_key?(@flags, name) ->
        if glob?,
          do: {:error, "#{name} with a wildcard or braces, which could expand to a flag"},
          else: denied_flags(name, args, @flags[name])

      name in @special ->
        if glob? and name not in ~w(cd),
          do: {:error, "#{name} with a wildcard or braces, which could expand to a flag"},
          else: special(name, args)

      Map.has_key?(@versions, name) ->
        if match?([_], args) and hd(args) in @versions[name],
          do: :ok,
          else:
            {:error,
             "#{name} can run code (only `#{name} #{hd(@versions[name])}` runs without asking)"}

      true ->
        {:error, "#{name} isn't on the list of commands that only look"}
    end
  end

  defp denied_flags(name, args, {short, long, words}) do
    case Enum.find(args, &denied?(&1, short, long, words)) do
      nil -> :ok
      flag -> {:error, "#{name} #{flag} can change things"}
    end
  end

  # Every argument is checked, wherever it is: one that looks like a value
  # (or comes after `--`) might be read as a flag by the program.
  defp denied?(arg, short, long, words) do
    cond do
      arg in words ->
        true

      String.starts_with?(arg, "--") ->
        name = arg |> String.split("=", parts: 2) |> hd()
        byte_size(name) > 2 and Enum.any?(long, &String.starts_with?(&1, name))

      String.starts_with?(arg, "-") and byte_size(arg) > 1 ->
        arg |> String.slice(1..-1//1) |> String.graphemes() |> Enum.any?(&(&1 in letters(short)))

      true ->
        false
    end
  end

  defp letters(short), do: String.graphemes(short)

  ## Commands with their own rules

  defp special("cd", args) do
    if length(Enum.reject(args, &(&1 in ["-P", "-L"]))) <= 1,
      do: :ok,
      else: {:error, "cd with more than one folder"}
  end

  defp special("command", [flag | _]) when flag in ["-v", "-V"], do: :ok
  defp special("command", _), do: {:error, "command runs a program; only `command -v` looks"}

  defp special("env", []), do: :ok
  defp special("env", _), do: {:error, "env with arguments runs a program; bare `env` only looks"}

  defp special("hostname", args) do
    ok = ~w(-f -s -i -I -d -A -a --fqdn --short --ip-address --all-ip-addresses --domain --long)
    if Enum.all?(args, &(&1 in ok)), do: :ok, else: {:error, "hostname with that can set it"}
  end

  defp special("uniq", args) do
    with :ok <- denied_flags("uniq", args, {"", [], []}) do
      operands = operands(args, ~w(-f -s -w))

      if length(operands) <= 1,
        do: :ok,
        else: {:error, "uniq with two files writes the second"}
    end
  end

  defp special("nvidia-smi", args) do
    ok? = fn arg ->
      arg in ~w(-q --query -L --list-gpus -x --xml-format -i -d --id --display) or
        String.match?(arg, ~r/\A--(query-gpu|query-compute-apps|format|id|display)=/) or
        (String.match?(arg, ~r/\A[A-Za-z0-9_.,=:]+\z/) and not String.starts_with?(arg, "-"))
    end

    if Enum.all?(args, ok?),
      do: :ok,
      else: {:error, "nvidia-smi with those flags can change GPU settings"}
  end

  defp special("ollama", [sub | _]) when sub in ~w(list ls ps show --version -v), do: :ok
  defp special("ollama", _), do: {:error, "ollama only looks with list, ps or show"}

  defp special(name, [sub | rest]) when name in ~w(docker podman) do
    cond do
      sub in ~w(--version version info) and rest == [] -> :ok
      sub in ~w(ps images) -> denied_flags(name, rest, {"", [], []})
      true -> {:error, "#{name} only looks with ps, images, info or version"}
    end
  end

  defp special("mise", [sub | _]) when sub in ~w(ls list current which where version --version),
    do: :ok

  defp special("mise", _), do: {:error, "mise only looks with ls, current, which or version"}
  defp special("git", args), do: git(args)
  defp special("ip", args), do: ip(args)
  defp special("sed", args), do: sed(args)
  defp special(name, _), do: {:error, "#{name} with those arguments can change things"}

  # Non-flag arguments, skipping the values of `value_flags`.
  defp operands(args, value_flags) do
    {operands, _} =
      Enum.reduce(args, {[], false}, fn arg, {acc, skip?} ->
        cond do
          skip? -> {acc, false}
          arg in value_flags -> {acc, true}
          String.starts_with?(arg, "-") and arg != "-" -> {acc, false}
          true -> {[arg | acc], false}
        end
      end)

    Enum.reverse(operands)
  end

  ## git

  defp git(args) do
    case git_globals(args) do
      {:ok, []} ->
        {:error, "git with no subcommand"}

      {:ok, [version]} when version in ["--version", "-v"] ->
        :ok

      {:ok, [sub | rest]} ->
        short = if sub == "grep", do: "O", else: ""

        with :ok <- denied_flags("git #{sub}", rest, {short, @git_deny, []}),
             do: git_sub(sub, rest)

      {:error, _} = error ->
        error
    end
  end

  defp git_globals([flag, _value | rest]) when flag in @git_valued, do: git_globals(rest)
  defp git_globals([flag | rest]) when flag in @git_globals, do: git_globals(rest)

  defp git_globals([flag | rest]) when flag in ["-P"], do: git_globals(rest)

  defp git_globals(["--" <> _ = flag | rest]) do
    if Enum.any?(@git_valued, &String.starts_with?(flag, &1 <> "=")),
      do: git_globals(rest),
      else: git_global_error(flag, rest)
  end

  defp git_globals(["-" <> _ = flag | rest]), do: git_global_error(flag, rest)
  defp git_globals(args), do: {:ok, args}

  defp git_global_error(flag, rest) when flag in ["--version", "-v"] and rest == [],
    do: {:ok, [flag]}

  defp git_global_error(flag, _rest), do: {:error, "git #{flag} can change how git runs"}

  defp git_sub(sub, _rest) when sub in @git_plain, do: :ok

  defp git_sub("branch", args),
    do: list_only("branch", args, "arvli", ~w(--all --remotes --verbose --list --show-current
        --color --no-color --column --no-column --ignore-case --omit-empty --no-abbrev
        --sort --format --abbrev --merged --no-merged --contains --no-contains --points-at))

  defp git_sub("tag", args),
    do: list_only("tag", args, "lni0123456789", ~w(--list --sort --format --contains --no-contains
        --merged --no-merged --points-at --column --no-column --color --ignore-case --omit-empty))

  defp git_sub("remote", args) do
    case args do
      [] -> :ok
      [sub | _] when sub in ["get-url", "show"] -> :ok
      _ -> if Enum.all?(args, &(&1 in ["-v", "--verbose"])), do: :ok, else: git_no("remote")
    end
  end

  defp git_sub("stash", [sub | _]) when sub in ["list", "show"], do: :ok
  defp git_sub("worktree", ["list" | _]), do: :ok
  defp git_sub("submodule", []), do: :ok
  defp git_sub("submodule", ["status" | _]), do: :ok

  defp git_sub("reflog", args) do
    case args do
      [] -> :ok
      ["-" <> _ | _] -> :ok
      [sub | _] when sub in ["show", "exists"] -> :ok
      _ -> git_no("reflog")
    end
  end

  defp git_sub("config", args) do
    reads = ~w(--get --get-all --get-regexp --get-urlmatch --list -l --get-color --get-colorbool)
    writes = ~w(--add --unset --unset-all --replace-all --edit -e --rename-section
                --remove-section set unset rename-section remove-section edit)
    first = Enum.find(args, &(not String.starts_with?(&1, "-")))

    cond do
      Enum.any?(args, &(&1 in writes)) -> git_no("config")
      Enum.any?(args, &(&1 in reads)) or first in ["get", "list"] -> :ok
      true -> git_no("config")
    end
  end

  defp git_sub(sub, _), do: git_no(sub)

  defp git_no(sub),
    do: {:error, "git #{sub} can change things (only reading git commands run without asking)"}

  # `git branch` / `git tag` list with these options; names after them make or
  # delete one, unless the options say to list (--list, --contains, …).
  defp list_only(sub, args, short_ok, long_ok) do
    lists = ~w(-l --list --contains --no-contains --merged --no-merged --points-at)

    flag_ok? = fn arg ->
      if String.starts_with?(arg, "--") do
        name = arg |> String.split("=", parts: 2) |> hd()
        name in long_ok
      else
        arg
        |> String.slice(1..-1//1)
        |> String.graphemes()
        |> Enum.all?(&(&1 in letters(short_ok)))
      end
    end

    {flags, names} = Enum.split_with(args, &String.starts_with?(&1, "-"))
    listing? = Enum.any?(flags, &(String.split(&1, "=", parts: 2) |> hd() |> Kernel.in(lists)))

    cond do
      not Enum.all?(flags, flag_ok?) -> git_no(sub)
      names != [] and not listing? -> git_no(sub)
      true -> :ok
    end
  end

  ## ip

  @ip_options ~w(-4 -6 -s -stats -statistics -d -details -br -brief -c -color -j -json -p
                 -pretty -o -oneline -h -human -human-readable -iec -t -timestamp)
  @ip_objects ~w(a ad addr address r ro rou route l li link n ne neigh neighbor neighbour ru
                 rule m maddr netconf)
  @ip_reads ~w(show sho sh s list lst ls l get)

  defp ip(args) do
    {options, rest} = Enum.split_while(args, &String.starts_with?(&1, "-"))

    cond do
      not Enum.all?(options, &(&1 in @ip_options or String.starts_with?(&1, "-color="))) ->
        {:error, "ip with those options can change things"}

      match?([_ | _], rest) and hd(rest) not in @ip_objects ->
        {:error, "ip #{hd(rest)} isn't one that only looks"}

      match?([_, action | _] when action not in @ip_reads, rest) ->
        {:error, "ip #{Enum.at(rest, 0)} #{Enum.at(rest, 1)} can change things"}

      true ->
        :ok
    end
  end

  ## sed: printing only, never -i, w, e or r

  defp sed(args), do: sed_opts(args, [], [])

  defp sed_opts([], scripts, files), do: sed_scripts(scripts, files)

  defp sed_opts(["--expression=" <> script | rest], scripts, files),
    do: sed_opts(rest, [script | scripts], files)

  defp sed_opts(["--" <> _ = long | rest], scripts, files) do
    if long in ~w(--quiet --silent --regexp-extended --separate --unbuffered --null-data --posix --debug),
      do: sed_opts(rest, scripts, files),
      else: {:error, "sed #{long} can change files"}
  end

  defp sed_opts(["-" <> cluster = flag | rest], scripts, files) when cluster != "" do
    {letters, script} =
      case String.split(cluster, "e", parts: 2) do
        [letters, ""] -> {letters, :next}
        [letters, script] -> {letters, script}
        [letters] -> {letters, nil}
      end

    cond do
      not Enum.all?(String.graphemes(letters), &(&1 in ~w(n E r s u z))) ->
        {:error, "sed #{flag} can change files"}

      script == :next ->
        case rest do
          [s | rest] -> sed_opts(rest, [s | scripts], files)
          [] -> {:error, "sed -e without a script"}
        end

      is_binary(script) ->
        sed_opts(rest, [script | scripts], files)

      true ->
        sed_opts(rest, scripts, files)
    end
  end

  defp sed_opts([arg | rest], scripts, files), do: sed_opts(rest, scripts, [arg | files])

  defp sed_scripts([], []), do: {:error, "sed without a script"}

  defp sed_scripts([], files) do
    [script | _] = Enum.reverse(files)
    sed_script(script)
  end

  defp sed_scripts(scripts, _files), do: each(scripts, &sed_script/1)

  defp sed_script(script) do
    if safe_sed?(script),
      do: :ok,
      else: {:error, "sed script #{inspect(script)} isn't plain printing or substitution"}
  end

  @doc false
  # Addresses, then p P d D q Q = l n N g G h H x z or s/…/…/flags or y/…/…/,
  # separated by ; or newlines. Anything else (w, e, r, a, i, c, labels) is refused.
  def safe_sed?(script), do: sed_cmds(String.trim_leading(script, " "))

  defp sed_cmds(""), do: true
  defp sed_cmds(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?;], do: sed_cmds(rest)

  defp sed_cmds(script) do
    with {:ok, rest} <- sed_address(script),
         {:ok, rest} <- sed_maybe_range(rest),
         rest = rest |> String.trim_leading() |> String.trim_leading("!") |> String.trim_leading(),
         {:ok, rest} <- sed_command(rest) do
      sed_after(String.trim_leading(rest, " "))
    else
      _ -> false
    end
  end

  defp sed_after(""), do: true
  defp sed_after(<<c, rest::binary>>) when c in [?;, ?\n], do: sed_cmds(rest)
  defp sed_after(_), do: false

  defp sed_maybe_range("," <> rest) do
    case sed_address(rest) do
      {:ok, ^rest} -> :error
      other -> other
    end
  end

  defp sed_maybe_range(rest), do: {:ok, rest}

  defp sed_address("$" <> rest), do: {:ok, rest}

  defp sed_address("/" <> rest) do
    with {:ok, _re, rest} <- sed_delimited(rest, "/"),
         do: {:ok, String.replace_prefix(rest, "I", "")}
  end

  defp sed_address(script) do
    case Regex.run(~r/\A(\d+)(~\d+)?/, script) do
      [m | _] -> {:ok, binary_part(script, byte_size(m), byte_size(script) - byte_size(m))}
      nil -> {:ok, script}
    end
  end

  defp sed_command(<<c, rest::binary>>) when c in ~c"pPdDqQ=lnNgGhHxz", do: {:ok, rest}

  defp sed_command(<<c, d::utf8, rest::binary>>)
       when c in [?s, ?y] and d not in [?\n, ?\\, ?\s] do
    d = <<d::utf8>>

    with {:ok, _re, rest} <- sed_delimited(rest, d),
         {:ok, _to, rest} <- sed_delimited(rest, d) do
      if c == ?s do
        [flags] = Regex.run(~r/\A[gpiImM0-9]*/, rest)
        {:ok, binary_part(rest, byte_size(flags), byte_size(rest) - byte_size(flags))}
      else
        {:ok, rest}
      end
    end
  end

  defp sed_command(_), do: :error

  # Up to the next unescaped delimiter.
  defp sed_delimited(text, d, acc \\ "")
  defp sed_delimited("", _d, _acc), do: :error

  defp sed_delimited(<<?\\, c::utf8, rest::binary>>, d, acc),
    do: sed_delimited(rest, d, acc <> <<?\\, c::utf8>>)

  defp sed_delimited(<<c::utf8, rest::binary>>, d, acc) do
    if <<c::utf8>> == d, do: {:ok, acc, rest}, else: sed_delimited(rest, d, acc <> <<c::utf8>>)
  end

  ## Parsing

  @doc """
  Splits a command line into simple commands, the way `sh` would: quotes and
  escapes resolved, `$…` and backticks noted as expansions, redirections
  separated out. `{:error, reason}` for anything outside that (subshells,
  here-documents, process substitution, unclosed quotes).
  """
  @spec parse(String.t()) :: {:ok, [simple()]} | {:error, String.t()}
  def parse(line) do
    with {:ok, tokens} <- lex(line, [], nil), do: group(tokens)
  end

  defp group(tokens), do: group(tokens, [], new_simple(nil))

  defp group([], done, current) do
    cond do
      empty?(current) and current.joined_by in [nil, ";"] -> {:ok, Enum.reverse(done)}
      empty?(current) -> {:error, "ends with #{current.joined_by}"}
      true -> {:ok, Enum.reverse([finish(current) | done])}
    end
  end

  defp group([{:word, w} | rest], done, current),
    do: group(rest, done, %{current | words: [w | current.words]})

  defp group([{:redirect, op, fd} | rest], done, current) do
    case rest do
      [{:word, target} | rest] ->
        group(rest, done, %{current | redirects: [{op, fd, target} | current.redirects]})

      _ ->
        {:error, "a redirection without a target"}
    end
  end

  defp group([{:op, "&"} | rest], done, current) do
    if empty?(current),
      do: {:error, "a stray &"},
      else: group(rest, [%{finish(current) | background?: true} | done], new_simple(";"))
  end

  defp group([{:op, op} | rest], done, current) when op in ["|", "&&", "||", ";"] do
    cond do
      not empty?(current) -> group(rest, [finish(current) | done], new_simple(op))
      op == ";" and current.joined_by in [nil, ";"] -> group(rest, done, current)
      true -> {:error, "a stray #{op}"}
    end
  end

  defp group([{:op, op} | _], _done, _current) when op in ["(", ")"],
    do: {:error, "runs a subshell or group ( … )"}

  defp group([{:op, op} | _], _done, _current), do: {:error, "uses #{op}"}

  defp new_simple(joined_by),
    do: %{words: [], redirects: [], joined_by: joined_by, background?: false}

  defp empty?(simple), do: simple.words == [] and simple.redirects == []

  defp finish(simple),
    do: %{simple | words: Enum.reverse(simple.words), redirects: Enum.reverse(simple.redirects)}

  ## Lexing

  # `w` is the word being read, or nil between words.
  defp lex(<<>>, tokens, w), do: {:ok, Enum.reverse(push(tokens, w))}
  defp lex(<<?\\, ?\n, rest::binary>>, tokens, w), do: lex(rest, tokens, w)

  defp lex(<<?\\, c::utf8, rest::binary>>, tokens, w),
    do: lex(rest, tokens, add(w, <<c::utf8>>, true))

  defp lex(<<?\\>>, _tokens, _w), do: {:error, "ends with a backslash"}

  defp lex(<<c, rest::binary>>, tokens, w) when c in [?\s, ?\t],
    do: lex(rest, push(tokens, w), nil)

  defp lex(<<?\n, rest::binary>>, tokens, w),
    do: lex(rest, [{:op, ";"} | push(tokens, w)], nil)

  defp lex(<<?#, rest::binary>>, tokens, nil) do
    case :binary.split(rest, "\n") do
      [_comment, rest] -> lex(rest, [{:op, ";"} | tokens], nil)
      [_comment] -> lex("", tokens, nil)
    end
  end

  defp lex(<<?', rest::binary>>, tokens, w) do
    case :binary.split(rest, "'") do
      [text, rest] -> lex(rest, tokens, add(w || new_word(), text, true))
      [_] -> {:error, "has an unclosed quote"}
    end
  end

  defp lex(<<?", rest::binary>>, tokens, w) do
    with {:ok, w, rest} <- dquote(rest, w || new_word()), do: lex(rest, tokens, w)
  end

  defp lex(<<?$, rest::binary>>, tokens, w) do
    with {:ok, w, rest} <- dollar(rest, w || new_word()), do: lex(rest, tokens, w)
  end

  defp lex(<<?`, rest::binary>>, tokens, w) do
    with {:ok, inner, rest} <- backtick(rest, ""),
         do: lex(rest, tokens, expansion(w || new_word(), {:subst, inner}))
  end

  defp lex(<<"&&", rest::binary>>, tokens, w), do: lex(rest, [{:op, "&&"} | push(tokens, w)], nil)
  defp lex(<<"||", rest::binary>>, tokens, w), do: lex(rest, [{:op, "||"} | push(tokens, w)], nil)
  defp lex(<<";;", _::binary>>, _tokens, _w), do: {:error, "uses ;; (a case statement)"}

  # `a |& b` is `a 2>&1 | b`.
  defp lex(<<"|&", rest::binary>>, tokens, w) do
    one = {:word, %{new_word() | text: "1"}}
    lex(rest, [{:op, "|"}, one, {:redirect, ">&", "2"} | push(tokens, w)], nil)
  end

  defp lex(<<"&>>", rest::binary>>, tokens, w),
    do: lex(rest, [{:redirect, "&>>", nil} | push(tokens, w)], nil)

  defp lex(<<"&>", rest::binary>>, tokens, w),
    do: lex(rest, [{:redirect, "&>", nil} | push(tokens, w)], nil)

  defp lex(<<c, rest::binary>>, tokens, w) when c in [?|, ?&, ?;, ?(, ?)],
    do: lex(rest, [{:op, <<c>>} | push(tokens, w)], nil)

  defp lex(<<c, _::binary>> = text, tokens, w) when c in [?<, ?>] do
    {fd, tokens} =
      case w do
        %{text: digits, expansions: [], quoted?: false} when digits != "" ->
          if digits =~ ~r/\A\d+\z/, do: {digits, tokens}, else: {nil, push(tokens, w)}

        _ ->
          {nil, push(tokens, w)}
      end

    case redirect_op(text) do
      {:ok, op, rest} -> lex(rest, [{:redirect, op, fd} | tokens], nil)
      {:error, _} = error -> error
    end
  end

  defp lex(<<c::utf8, rest::binary>>, tokens, w) do
    glob? = c in ~c"*?[{"
    w = add(w, <<c::utf8>>, false)
    lex(rest, tokens, if(glob?, do: %{w | glob?: true}, else: w))
  end

  defp lex(_bad, _tokens, _w), do: {:error, "isn't valid text"}

  defp redirect_op(text) do
    case text do
      "<<<" <> _ -> {:error, "uses a here-string (<<<)"}
      "<<" <> _ -> {:error, "uses a here-document (<<)"}
      "<(" <> _ -> {:error, "uses process substitution <(…)"}
      ">(" <> _ -> {:error, "uses process substitution >(…)"}
      "<>" <> rest -> {:ok, "<>", rest}
      "<&" <> rest -> {:ok, "<&", rest}
      "<" <> rest -> {:ok, "<", rest}
      ">>" <> rest -> {:ok, ">>", rest}
      ">|" <> rest -> {:ok, ">|", rest}
      ">&" <> rest -> {:ok, ">&", rest}
      ">" <> rest -> {:ok, ">", rest}
    end
  end

  # Inside double quotes: \ escapes only $ ` " \ and newline; $ and ` expand.
  defp dquote(<<?", rest::binary>>, w), do: {:ok, %{w | quoted?: true}, rest}
  defp dquote(<<?\\, ?\n, rest::binary>>, w), do: dquote(rest, w)

  defp dquote(<<?\\, c, rest::binary>>, w) when c in [?$, ?`, ?", ?\\],
    do: dquote(rest, add(w, <<c>>, true))

  defp dquote(<<?$, rest::binary>>, w) do
    with {:ok, w, rest} <- dollar(rest, w), do: dquote(rest, w)
  end

  defp dquote(<<?`, rest::binary>>, w) do
    with {:ok, inner, rest} <- backtick(rest, ""),
         do: dquote(rest, expansion(w, {:subst, inner}))
  end

  defp dquote(<<c::utf8, rest::binary>>, w), do: dquote(rest, add(w, <<c::utf8>>, true))
  defp dquote(<<>>, _w), do: {:error, "has an unclosed quote"}
  defp dquote(_bad, _w), do: {:error, "isn't valid text"}

  # After a $: $((…)), $(…), ${…}, $name, $1, $?, $'…', $"…", or a plain $.
  defp dollar(<<"((", rest::binary>>, w) do
    with {:ok, inner, rest} <- balanced(rest, 2, ""),
         do: {:ok, expansion(w, {:arith, inner}), rest}
  end

  defp dollar(<<?(, rest::binary>>, w) do
    with {:ok, inner, rest} <- balanced(rest, 1, ""),
         do: {:ok, expansion(w, {:subst, inner}), rest}
  end

  defp dollar(<<?{, rest::binary>>, w) do
    case :binary.split(rest, "}") do
      [inner, rest] -> {:ok, expansion(w, {:var, inner}), rest}
      [_] -> {:error, "has an unclosed ${"}
    end
  end

  defp dollar(<<?', rest::binary>>, w) do
    case Regex.run(~r/\A((?:[^'\\]|\\.)*)'/s, rest) do
      [m, inner] ->
        {:ok, expansion(w, {:ansi, inner}),
         binary_part(rest, byte_size(m), byte_size(rest) - byte_size(m))}

      nil ->
        {:error, "has an unclosed quote"}
    end
  end

  defp dollar(<<?", _::binary>> = rest, w), do: {:ok, expansion(w, {:var, "\""}), rest}

  defp dollar(text, w) do
    case Regex.run(~r/\A([A-Za-z_][A-Za-z0-9_]*|[0-9?$!#@*-])/, text) do
      [m, name] ->
        {:ok, expansion(w, {:var, name}),
         binary_part(text, byte_size(m), byte_size(text) - byte_size(m))}

      nil ->
        {:ok, add(w, "$", false), text}
    end
  end

  # Up to the closing parentheses (`depth` of them), skipping quoted text.
  defp balanced(<<>>, _depth, _acc), do: {:error, "has an unclosed $("}
  defp balanced(<<?), rest::binary>>, 1, acc), do: {:ok, acc, rest}

  defp balanced(<<"))", rest::binary>>, 2, acc), do: {:ok, acc, rest}
  defp balanced(<<?), rest::binary>>, depth, acc), do: balanced(rest, depth - 1, acc <> ")")
  defp balanced(<<?(, rest::binary>>, depth, acc), do: balanced(rest, depth + 1, acc <> "(")

  defp balanced(<<?\\, c::utf8, rest::binary>>, depth, acc),
    do: balanced(rest, depth, acc <> <<?\\, c::utf8>>)

  defp balanced(<<q, rest::binary>>, depth, acc) when q in [?', ?"] do
    case :binary.split(rest, <<q>>) do
      [inner, rest] -> balanced(rest, depth, acc <> <<q>> <> inner <> <<q>>)
      [_] -> {:error, "has an unclosed quote"}
    end
  end

  defp balanced(<<c::utf8, rest::binary>>, depth, acc),
    do: balanced(rest, depth, acc <> <<c::utf8>>)

  defp balanced(_bad, _depth, _acc), do: {:error, "isn't valid text"}

  defp backtick(<<>>, _acc), do: {:error, "has an unclosed backtick"}
  defp backtick(<<?`, rest::binary>>, acc), do: {:ok, acc, rest}
  defp backtick(<<?\\, c::utf8, rest::binary>>, acc), do: backtick(rest, acc <> <<c::utf8>>)
  defp backtick(<<c::utf8, rest::binary>>, acc), do: backtick(rest, acc <> <<c::utf8>>)
  defp backtick(_bad, _acc), do: {:error, "isn't valid text"}

  defp new_word, do: %{text: "", expansions: [], glob?: false, quoted?: false}

  defp add(nil, text, quoted?), do: add(new_word(), text, quoted?)

  defp add(w, text, quoted?),
    do: %{w | text: w.text <> text, quoted?: w.quoted? or quoted?}

  defp expansion(w, exp), do: %{w | expansions: w.expansions ++ [exp]}

  defp push(tokens, nil), do: tokens
  defp push(tokens, w), do: [{:word, w} | tokens]
end
