defmodule TinyAxe.Sandbox do
  @moduledoc """
  Runs a command under bubblewrap: read-only root filesystem, `/home` and `/tmp`
  replaced with empty tmpfs, no network or IPC, and only `workdir` writable
  (mounted at `/tmp/work`). An Erlang and Elixir install is re-exposed read-only
  so `elixir` works inside: the ones on the PATH, or else the ones the VM runs
  from. (An installed release runs from its own trimmed runtime, which has no
  `elixir` command, so its launcher puts a full install on the PATH.)
  """

  @spec available?() :: boolean()
  def available?, do: System.find_executable("bwrap") != nil

  @doc "Runs `argv` in the sandbox. Returns `{output, exit_status}`; 124 means timeout."
  @spec cmd([String.t()], Path.t(), keyword()) :: {String.t(), non_neg_integer()}
  def cmd(argv, workdir, opts \\ []) do
    timeout_s = Keyword.get(opts, :timeout_s, 30)
    {erlang_root, elixir_root} = beam_roots()

    args =
      ~w(--ro-bind / / --tmpfs /home --tmpfs /tmp --dev /dev --proc /proc) ++
        ["--ro-bind", erlang_root, erlang_root, "--ro-bind", elixir_root, elixir_root] ++
        ["--bind", workdir, "/tmp/work", "--chdir", "/tmp/work"] ++
        ~w(--unshare-all --die-with-parent --new-session --clearenv) ++
        ["--setenv", "HOME", "/tmp/work", "--setenv", "LANG", "C.UTF-8"] ++
        [
          "--setenv",
          "PATH",
          Enum.join(
            [Path.join(elixir_root, "bin"), Path.join(erlang_root, "bin"), "/usr/bin", "/bin"],
            ":"
          )
        ] ++
        ["timeout", "--kill-after=5", Integer.to_string(timeout_s) | argv]

    System.cmd("bwrap", args, stderr_to_stdout: true)
  end

  @doc false
  def beam_roots do
    erlang_root = install_root("erl") || List.to_string(:code.root_dir())

    elixir_root =
      install_root("elixir") ||
        :elixir |> :code.lib_dir() |> List.to_string() |> Path.join("../..") |> Path.expand()

    {erlang_root, elixir_root}
  end

  # The install an executable on the PATH belongs to (`<root>/bin/<name>`).
  # Skipped: mise's shims (they need mise and its config, which the sandbox
  # doesn't have), and a release's own runtime, whose `erl` needs the release's
  # boot files (the release puts it first on the PATH).
  defp install_root(name) do
    release = System.get_env("RELEASE_ROOT")

    System.get_env("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.map(&Path.join(&1, name))
    |> Enum.reject(
      &(String.contains?(&1, "/shims/") or (release && String.starts_with?(&1, release <> "/")))
    )
    |> Enum.find_value(fn path ->
      with true <- File.regular?(path),
           bin = path |> resolve_links() |> Path.dirname(),
           "bin" <- Path.basename(bin),
           root = install_dir(Path.dirname(bin)),
           true <- File.regular?(Path.join([root, "bin", name])) do
        root
      else
        _ -> nil
      end
    end)
  end

  # A running VM puts its `erts-*/bin` first on the PATH; that `erl` needs the
  # boot files of the install around it, so the root is the folder above.
  defp install_dir(dir) do
    if String.starts_with?(Path.basename(dir), "erts-"), do: Path.dirname(dir), else: dir
  end

  defp resolve_links(path) do
    case File.read_link(path) do
      {:ok, target} -> target |> Path.expand(Path.dirname(path)) |> resolve_links()
      {:error, _} -> path
    end
  end
end
