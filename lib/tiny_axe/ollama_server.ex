defmodule TinyAxe.OllamaServer do
  @moduledoc """
  Makes sure Ollama is running before tiny-axe needs it.

  If Ollama doesn't answer at `:ollama_url`, and that address is this machine,
  it's started: through the user's systemd service (`systemctl --user start
  ollama`) when one exists, so its settings apply, or else by running
  `ollama serve` in the background with the same address, logging to the state
  folder. Ollama keeps running after tiny-axe exits, as it would if the service
  had started it at login.

  An address on another machine is never started, only reported.
  """

  @wait_ms 30_000
  @poll_ms 250

  @type outcome ::
          {:ok, :already_running | {:started, how :: String.t(), ms :: non_neg_integer()}}
          | {:error, String.t()}

  @doc """
  Returns once Ollama answers, starting it if needed. `opts` lets tests swap
  the address (`:url`), how it's started (`:start`), and the wait (`:wait_ms`).
  """
  @spec ensure_running(keyword()) :: outcome()
  def ensure_running(opts \\ []) do
    url =
      Keyword.get(
        opts,
        :url,
        Application.get_env(:tiny_axe, :ollama_url, "http://localhost:11434")
      )

    cond do
      up?(url) ->
        {:ok, :already_running}

      not local?(url) ->
        {:error,
         "Ollama isn't answering at #{url}, and that isn't this machine, so tiny-axe won't start it"}

      true ->
        start = Keyword.get(opts, :start, &start/0)
        t0 = System.monotonic_time(:millisecond)

        with {:ok, how} <- start.(),
             :ok <- wait_until_up(url, Keyword.get(opts, :wait_ms, @wait_ms)) do
          {:ok, {:started, how, System.monotonic_time(:millisecond) - t0}}
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Whether Ollama answers at `url`."
  @spec up?(String.t()) :: boolean()
  def up?(url) do
    case isolated(
           fn -> Req.get(url <> "/api/version", receive_timeout: 1_000, retry: false) end,
           2_000
         ) do
      {:ok, %Req.Response{status: 200}} -> true
      _ -> false
    end
  end

  @doc "Whether `model` is downloaded, according to Ollama at `url`."
  @spec has_model?(String.t(), String.t()) :: boolean() | :unknown
  def has_model?(url, model) do
    case isolated(
           fn -> Req.get(url <> "/api/tags", receive_timeout: 3_000, retry: false) end,
           4_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"models" => models}}} ->
        names = Enum.map(models, & &1["name"])
        model in names or (model <> ":latest") in names

      _ ->
        :unknown
    end
  end

  # Each request runs in its own short-lived process. While Ollama is starting,
  # a request can time out and its reply arrive later; in a long-lived caller
  # that stray reply is received by the next request, which crashes (Finch
  # raised a CaseClauseError on it at startup). Here it dies with the process.
  defp isolated(fun, timeout) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :timeout}
    end
  end

  defp local?(url), do: URI.parse(url).host in ["localhost", "127.0.0.1", "::1", "[::1]"]

  defp start do
    cond do
      user_service?() ->
        case System.cmd("systemctl", ["--user", "start", "ollama"], stderr_to_stdout: true) do
          {_, 0} -> {:ok, "systemctl --user start ollama"}
          {out, _} -> start_process("the ollama service didn't start (#{String.trim(out)})")
        end

      true ->
        start_process(nil)
    end
  end

  defp user_service? do
    System.find_executable("systemctl") != nil and
      match?({_, 0}, System.cmd("systemctl", ["--user", "cat", "ollama"], stderr_to_stdout: true))
  end

  # `ollama serve` in its own session, so it outlives tiny-axe, with the
  # settings the service would have used.
  defp start_process(why_not_service) do
    case System.find_executable("ollama") do
      nil ->
        {:error,
         "Ollama isn't running and isn't installed (no `ollama` on the PATH)" <>
           if(why_not_service, do: "; #{why_not_service}", else: "")}

      exe ->
        dir = TinyAxe.Ops.Journal.state_dir()
        File.mkdir_p!(dir)
        log = Path.join(dir, "ollama.log")

        System.cmd(
          "sh",
          ["-c", ~s(setsid "$0" serve >> "$1" 2>&1 < /dev/null &), exe, log],
          env: [{"OLLAMA_HOST", "127.0.0.1:11434"}, {"OLLAMA_NUM_PARALLEL", "1"}]
        )

        {:ok, "ollama serve (log: #{TinyAxe.Ops.show(log)})"}
    end
  end

  defp wait_until_up(url, wait_ms) do
    deadline = System.monotonic_time(:millisecond) + wait_ms

    Stream.repeatedly(fn -> up?(url) end)
    |> Enum.find_value(fn up ->
      cond do
        up ->
          :ok

        System.monotonic_time(:millisecond) > deadline ->
          {:error, "Ollama was started but didn't answer within #{div(wait_ms, 1000)}s"}

        true ->
          Process.sleep(@poll_ms) && nil
      end
    end)
  end
end
