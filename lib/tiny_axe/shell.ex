defmodule TinyAxe.Shell do
  @moduledoc """
  Runs a shell command inside a bubblewrap sandbox, in one of two modes:

    * `:read_only` (the default), for commands `TinyAxe.Shell.ReadOnly` says
      only look, which run without asking: the whole filesystem is read-only
      apart from an empty scratch `/tmp`, and the command has its own process
      namespace, so it sees your processes (`/proc` is the real one) but can't
      signal any of them
    * `:approved`, for commands the user said yes to: the working folder can
      be changed; the home folder is overlaid, so other writes there vanish
      when the command ends, except in the install folders
      (`install_folders/0`: `~/.cargo`, `~/.local/bin`, …), which keep what's
      installed; the command shares the process namespace, so `kill` reaches
      your processes (`TinyAxe.Shell.Processes.guard/2` keeps tiny-axe's own
      out of reach), and anything it leaves running is stopped when it ends

  In both:

    * secrets are hidden (`hidden_paths/0`): an empty folder or file is
      mounted over SSH and GPG keys, password stores and keyrings, cloud and
      package-registry credentials, browser profiles, shell histories, the
      session's sockets (keyring, agents, D-Bus), and tiny-axe's own settings,
      state, purchases and browser profile; environment variables that
      look like secrets are removed (`secret_env?/1`)
    * commands run in a user namespace, so they can list your processes but
      not look inside them (open files, environment): `lsof` and `ss -p` show
      only the sandbox's own
    * the network works, so package managers can download
    * stdin is empty, so a command that asks a question gets no answer instead
      of hanging, and `CI=true` tells most tools not to ask
    * it's killed after `:command_timeout` (10 minutes by default), or when the
      caller dies

  Output is streamed to `on_output` with terminal colour codes removed. With
  `on_start: fun`, `fun` gets the sandbox's OS pid, so a caller can stop it
  with `stop/1`.

  The same user runs inside, so the sandbox keeps commands to their folder and
  away from secrets by accident or a model's mistake; it isn't a wall against
  a command written to get out (it has the network, for one).
  """

  alias TinyAxe.Shell.Processes

  @max_tail 20_000
  @marker "\u0001tiny-axe-session "

  @type mode :: :read_only | :approved

  @spec available?() :: boolean()
  def available?, do: System.find_executable("bwrap") != nil

  @doc """
  Runs `command` with `sh -c` in `dir`. Returns `{:ok, exit_status, output}`
  (the last #{@max_tail} characters) or `{:error, reason}`.

  Options: `mode:` (`:read_only`, the default, or `:approved`), `timeout:`
  (ms), `on_start:`.
  """
  @spec run(String.t(), String.t(), (String.t() -> any()), keyword()) ::
          {:ok, non_neg_integer(), String.t()} | {:error, term()}
  def run(dir, command, on_output \\ fn _ -> :ok end, opts \\ []) do
    mode = Keyword.get(opts, :mode, :read_only)

    timeout =
      Keyword.get(opts, :timeout, Application.get_env(:tiny_axe, :command_timeout, 600_000))

    with bwrap when bwrap != nil <- System.find_executable("bwrap"),
         true <- mode in [:read_only, :approved] || {:error, :unknown_mode},
         true <- File.dir?(dir) || {:error, :no_such_folder} do
      port =
        Port.open({:spawn_executable, bwrap}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, args(mode, dir, command)},
          {:env, env(mode)}
        ])

      with fun when is_function(fun, 1) <- Keyword.get(opts, :on_start),
           {:os_pid, pid} <- Port.info(port, :os_pid),
           do: fun.(pid)

      deadline = System.monotonic_time(:millisecond) + timeout
      # Approved commands say their session first (see args/3), so what they
      # leave running can be stopped; read-only ones end with their process
      # namespace.
      session = if mode == :approved, do: :waiting, else: nil
      collect(port, on_output, %{acc: [], session: session, head: ""}, deadline)
    else
      nil -> {:error, :bwrap_not_installed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops a running sandbox by its OS pid (from `on_start`), and everything the
  command started. tiny-axe itself is never touched.
  """
  @spec stop(integer()) :: :ok
  def stop(os_pid) when is_integer(os_pid), do: Processes.kill_tree(os_pid)

  ## What the sandbox hides

  @doc """
  Where secrets usually live, as `{path, kind}`: `path` is absolute (home and
  XDG folders expanded), whether or not it exists here.
  """
  @spec secret_places() :: [{String.t(), String.t()}]
  def secret_places do
    home = System.user_home!()
    config = xdg("XDG_CONFIG_HOME", ".config")
    data = xdg("XDG_DATA_HOME", ".local/share")
    state = xdg("XDG_STATE_HOME", ".local/state")
    at = &Path.join(home, &1)
    under = fn dir, names, kind -> Enum.map(names, &{Path.join(dir, &1), kind}) end
    browser = Application.get_env(:tiny_axe, :browser, [])[:profile]

    tiny_axe =
      [
        Path.join(config, "tiny-axe"),
        Path.join(data, "tiny-axe"),
        Path.join(state, "tiny-axe"),
        TinyAxe.Ops.Journal.state_dir(),
        TinyAxe.Purchases.config_path(),
        TinyAxe.MCP.config_path(),
        browser
      ]
      |> Enum.filter(& &1)
      |> Enum.map(&{Path.expand(&1), "tiny-axe's own settings, state and purchases"})

    under.(home, ~w(.ssh .gnupg .password-store .erlang.cookie .ollama/id_ed25519), "keys") ++
      [{Path.join(data, "keyrings"), "keys"}] ++
      under.(
        home,
        ~w(.aws .azure .kube .docker/config.json .netrc .git-credentials .npmrc .pypirc
           .cargo/credentials .cargo/credentials.toml .hex/hex.config .vault-token .pgpass
           .my.cnf .s3cfg .terraform.d/credentials.tfrc.json .claude .claude.json .codex),
        "credentials"
      ) ++
      under.(config, ~w(gcloud gh hub op rclone Bitwarden 1Password), "credentials") ++
      under.(
        config,
        ~w(google-chrome chromium BraveSoftware vivaldi microsoft-edge),
        "browser profiles"
      ) ++
      [{at.(".mozilla"), "browser profiles"}, {at.(".thunderbird"), "browser profiles"}] ++
      under.(
        home,
        ~w(.bash_history .zsh_history .python_history .node_repl_history .psql_history
           .mysql_history .lesshst),
        "shell histories"
      ) ++
      [{Path.join(data, "fish/fish_history"), "shell histories"}] ++
      tiny_axe ++ [{runtime_dir(), "session sockets"}]
  end

  @doc """
  The secret places that exist here, as `{:dir | :file, real_path}`, outermost
  only (a hidden folder hides what's in it). Paths under `/tmp` are left out:
  the sandbox's `/tmp` starts empty anyway.
  """
  @spec hidden_paths() :: [{:dir | :file, String.t()}]
  def hidden_paths do
    found =
      for {path, _kind} <- secret_places(),
          real = real_path(path),
          not String.starts_with?(real <> "/", "/tmp/"),
          {:ok, %{type: type}} <- [File.stat(real)],
          type in [:directory, :regular],
          uniq: true,
          do: {if(type == :directory, do: :dir, else: :file), real}

    dirs = for {:dir, d} <- found, do: d

    found
    |> Enum.reject(fn {_, p} -> Enum.any?(dirs, &String.starts_with?(p, &1 <> "/")) end)
    |> Enum.sort_by(fn {_, p} -> p end)
  end

  @doc """
  The install folders approved commands may change, so what they install
  persists, as `{path, programs}`: a missing folder is made when the command
  names one of `programs`.
  """
  @spec install_folders() :: [{String.t(), [String.t()]}]
  def install_folders do
    home = System.user_home!()

    [
      {".cargo", ~w(cargo rustup)},
      {".rustup", ~w(rustup cargo rustc)},
      {".local/bin", ~w(pip pip3 pipx uv uvx)},
      {".local/lib", ~w(pip pip3 python python3)},
      {".local/share/mise", ~w(mise)},
      {".local/share/pipx", ~w(pipx)},
      {".local/share/uv", ~w(uv uvx)},
      {".npm-global", []},
      {"go", ~w(go)},
      {".bun", ~w(bun)},
      {".deno", ~w(deno)}
    ]
    |> Enum.map(fn {rel, programs} -> {Path.join(home, rel), programs} end)
    |> Kernel.++([{System.get_env("MIX_HOME") || Path.join(home, ".mix"), ~w(mix)}])
  end

  # The install folders for this command: those that exist, and any it needs
  # that don't yet (made now, so there's something to bind).
  defp writable_installs(command) do
    words = command |> String.split(~r/[^\w.+-]+/) |> MapSet.new()

    for {path, programs} <- install_folders(),
        File.dir?(path) or
          (Enum.any?(programs, &MapSet.member?(words, &1)) and File.mkdir_p(path) == :ok),
        real = real_path(path),
        File.dir?(real),
        do: real
  end

  ## The environment

  @secret_name ~r/TOKEN|SECRET|KEY|PASS|CREDENTIAL|AUTH|COOKIE|PRIVATE|AGENT|SESSION_BUS/
  @secret_prefixes ~w(ANTHROPIC_ OPENAI_ TYPESAFE_ AWS_ GH_ GITHUB_ AZURE_ GOOGLE_ GCLOUD_
                      CLOUDSDK_ HF_ HUGGING CLAUDE CODEX_ RELEASE_ BASH_FUNC_)

  @doc """
  Whether an environment variable is kept from commands: names containing
  TOKEN, SECRET, KEY, PASS, CREDENTIAL, AUTH, COOKIE, PRIVATE, AGENT or
  SESSION_BUS, or starting with a provider's prefix (ANTHROPIC_, OPENAI_,
  TYPESAFE_, AWS_, GH_, GITHUB_, …).

      iex> TinyAxe.Shell.secret_env?("GITHUB_TOKEN")
      true
      iex> TinyAxe.Shell.secret_env?("PATH")
      false
  """
  @spec secret_env?(String.t()) :: boolean()
  def secret_env?(name) do
    name = String.upcase(name)
    name =~ @secret_name or Enum.any?(@secret_prefixes, &String.starts_with?(name, &1))
  end

  @doc false
  def env(mode) do
    common = [
      {"CI", "true"},
      {"NO_COLOR", "1"},
      {"TERM", "dumb"},
      {"npm_config_yes", "true"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"PAGER", "cat"},
      {"GIT_PAGER", "cat"}
    ]

    # Read-only git: no index refresh, no fsmonitor hook, no external diff.
    read_only = [
      {"GIT_OPTIONAL_LOCKS", "0"},
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "core.fsmonitor"},
      {"GIT_CONFIG_VALUE_0", "false"},
      {"GIT_EXTERNAL_DIFF", false},
      {"RIPGREP_CONFIG_PATH", false}
    ]

    set = if mode == :read_only, do: common ++ read_only, else: common
    names = Enum.map(set, &elem(&1, 0))

    removed =
      for {name, _} <- System.get_env(), secret_env?(name), name not in names, do: {name, false}

    Enum.map(removed ++ set, fn {k, v} -> {String.to_charlist(k), v && String.to_charlist(v)} end)
  end

  ## bwrap

  @doc false
  def args(mode, dir, command) do
    home = System.user_home!()
    dir = Path.expand(dir)

    {mounts, namespaces, script} =
      case mode do
        :read_only ->
          # The working folder is bound again in case it's under /tmp. When the
          # command ends, its process namespace ends, and with it anything left.
          {["--ro-bind", dir, dir], ~w(--unshare-pid), "exec < /dev/null\n" <> command}

        :approved ->
          installs = Enum.flat_map(writable_installs(command), &["--bind", &1, &1])

          {["--overlay-src", home, "--tmp-overlay", home] ++ installs ++ ["--bind", dir, dir], [],
           approved_script(command)}
      end

    hidden =
      Enum.flat_map(hidden_paths(), fn
        {:dir, path} -> ["--tmpfs", path]
        {:file, path} -> ["--ro-bind", empty_file(), path]
      end)

    ~w(--ro-bind / / --dev /dev --tmpfs /tmp) ++
      mounts ++
      hidden ++
      ["--chdir", dir] ++
      namespaces ++
      ~w(--unshare-user-try --unshare-ipc --unshare-uts --unshare-cgroup-try --die-with-parent
         --new-session) ++
      ["sh", "-c", script]
  end

  # The shell says its session first (the sandbox shares the process
  # namespace, so tiny-axe tracks it), runs the command in a subshell, then
  # stops whatever the command left running in the session before it exits:
  # a background child would otherwise keep the output open, and keep running.
  defp approved_script(command) do
    """
    printf '#{@marker}%s\\n' "$$"
    exec < /dev/null
    (
    #{command}
    )
    tiny_axe_status=$?
    for tiny_axe_pid in $(pgrep -s $$ 2>/dev/null); do
      [ "$tiny_axe_pid" = "$$" ] || kill -KILL "$tiny_axe_pid" 2>/dev/null
    done
    exit $tiny_axe_status
    """
  end

  # An empty, read-only file to mount over secret files, kept in tiny-axe's
  # state folder (hidden itself; bwrap reads mount sources from outside).
  defp empty_file do
    path = Path.join(TinyAxe.Ops.Journal.state_dir(), "sandbox-empty")

    unless File.regular?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "")
      File.chmod(path, 0o444)
    end

    path
  end

  defp xdg(var, default) do
    case System.get_env(var) do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> Path.join(System.user_home!(), default)
    end
  end

  defp runtime_dir do
    with nil <- System.get_env("XDG_RUNTIME_DIR"),
         {:ok, status} <- File.read("/proc/self/status"),
         [_, uid] <- Regex.run(~r/^Uid:\s+(\d+)/m, status) do
      "/run/user/#{uid}"
    else
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> "/run/user/#{File.stat!(System.user_home!()).uid}"
    end
  end

  @doc false
  # The path with every symlink in it followed (missing parts kept as given).
  def real_path(path, depth \\ 0) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn part, acc ->
      next = Path.join(acc, part)

      case :file.read_link_all(String.to_charlist(next)) do
        {:ok, target} when depth < 20 ->
          real_path(Path.expand(to_string(target), acc), depth + 1)

        _ ->
          next
      end
    end)
  end

  ## Output

  defp collect(port, on_output, st, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        {text, st} = session_header(data, st)
        text = strip_ansi(text)
        if text != "", do: on_output.(text)
        collect(port, on_output, %{st | acc: keep_tail([st.acc | text])}, deadline)

      {^port, {:exit_status, status}} ->
        if is_integer(st.session), do: Processes.kill_session(st.session)
        {:ok, status, st.acc |> IO.iodata_to_binary() |> String.trim_trailing()}
    after
      remaining ->
        stop_port(port)
        if is_integer(st.session), do: Processes.kill_session(st.session)
        {:error, :timeout}
    end
  end

  # An approved command's first line is its session id, not output.
  defp session_header(data, %{session: :waiting, head: head} = st) do
    head = head <> data

    cond do
      String.starts_with?(head, @marker) and String.contains?(head, "\n") ->
        [line, rest] = String.split(head, "\n", parts: 2)

        session =
          case Integer.parse(String.replace_prefix(line, @marker, "")) do
            {sid, ""} -> sid
            _ -> nil
          end

        {rest, %{st | session: session, head: ""}}

      String.starts_with?(@marker, head) or String.starts_with?(head, @marker) ->
        {"", %{st | head: head}}

      true ->
        # Something else came first (bwrap's own error): no session to track.
        {head, %{st | session: nil, head: ""}}
    end
  end

  defp session_header(data, st), do: {data, st}

  defp stop_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> stop(pid)
      nil -> :ok
    end

    Port.close(port)
  catch
    :error, _ -> :ok
  end

  defp keep_tail(iodata) do
    binary = IO.iodata_to_binary(iodata)
    size = byte_size(binary)
    if size > @max_tail, do: binary_part(binary, size - @max_tail, @max_tail), else: binary
  end

  defp strip_ansi(text),
    do: String.replace(text, ~r/\e\[[0-9;?]*[ -\/]*[@-~]|\e\][^\a]*\a|\r(?!\n)/, "")
end
