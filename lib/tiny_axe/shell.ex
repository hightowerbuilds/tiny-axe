defmodule TinyAxe.Shell do
  @moduledoc """
  Runs an approved shell command inside a bubblewrap sandbox:

    * only the working folder can be changed; the home folder is overlaid, so
      a command can write there (caches, config) but the writes vanish when it
      ends, and the rest of the system is read-only
    * the network works, so package managers can download
    * stdin is empty, so a command that asks a question gets no answer instead
      of hanging, and `CI=true` tells most tools not to ask
    * it's killed after `:command_timeout` (10 minutes by default), or when the
      caller dies

  Output is streamed to `on_output` with terminal colour codes removed. With
  `on_start: fun`, `fun` gets the sandbox's OS pid, so a caller can kill it.
  """

  @max_tail 20_000

  @spec available?() :: boolean()
  def available?, do: System.find_executable("bwrap") != nil

  @doc """
  Runs `command` with `sh -c` in `dir`. Returns `{:ok, exit_status, output}`
  (the last #{@max_tail} characters) or `{:error, reason}`.
  """
  @spec run(String.t(), String.t(), (String.t() -> any()), keyword()) ::
          {:ok, non_neg_integer(), String.t()} | {:error, term()}
  def run(dir, command, on_output \\ fn _ -> :ok end, opts \\ []) do
    timeout =
      Keyword.get(opts, :timeout, Application.get_env(:tiny_axe, :command_timeout, 600_000))

    with bwrap when bwrap != nil <- System.find_executable("bwrap"),
         true <- File.dir?(dir) || {:error, :no_such_folder} do
      port =
        Port.open({:spawn_executable, bwrap}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, args(dir, command)},
          {:env, env()}
        ])

      with fun when is_function(fun, 1) <- Keyword.get(opts, :on_start),
           {:os_pid, pid} <- Port.info(port, :os_pid),
           do: fun.(pid)

      deadline = System.monotonic_time(:millisecond) + timeout
      collect(port, on_output, [], deadline)
    else
      nil -> {:error, :bwrap_not_installed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp args(dir, command) do
    home = System.user_home!()

    ~w(--ro-bind / / --dev /dev --proc /proc --tmpfs /tmp) ++
      ["--overlay-src", home, "--tmp-overlay", home] ++
      ["--bind", dir, dir, "--chdir", dir] ++
      ~w(--unshare-all --share-net --die-with-parent --new-session) ++
      ["sh", "-c", "exec < /dev/null\n" <> command]
  end

  defp env do
    [
      {~c"CI", ~c"true"},
      {~c"NO_COLOR", ~c"1"},
      {~c"TERM", ~c"dumb"},
      {~c"npm_config_yes", ~c"true"}
    ]
  end

  defp collect(port, on_output, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        text = strip_ansi(data)
        on_output.(text)
        collect(port, on_output, keep_tail([acc | text]), deadline)

      {^port, {:exit_status, status}} ->
        {:ok, status, acc |> IO.iodata_to_binary() |> String.trim_trailing()}
    after
      remaining ->
        kill(port)
        {:error, :timeout}
    end
  end

  # bwrap takes the sandboxed command down with it (--die-with-parent is set
  # up from inside, so killing bwrap is enough).
  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      nil ->
        :ok
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
