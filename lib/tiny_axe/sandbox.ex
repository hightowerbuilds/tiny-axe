defmodule TinyAxe.Sandbox do
  @moduledoc """
  Runs a command under bubblewrap: read-only root filesystem, `/home` and `/tmp`
  replaced with empty tmpfs, no network or IPC, and only `workdir` writable
  (mounted at `/tmp/work`). The Erlang/Elixir installs the VM is running from are
  re-exposed read-only so `elixir` works inside.
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

  defp beam_roots do
    erlang_root = List.to_string(:code.root_dir())

    elixir_root =
      :elixir |> :code.lib_dir() |> List.to_string() |> Path.join("../..") |> Path.expand()

    {erlang_root, elixir_root}
  end
end
