defmodule TinyAxe.Model.CLI do
  @moduledoc """
  Runs a model's command-line tool (`claude -p`, `codex exec`) as a plain
  model, on the user's subscription, never an API key:

    * API-key variables are removed from its environment, so it can only use
      the account the user logged in with
    * it runs in an empty folder of its own, with the prompt on stdin (read
      from a file only this user can read, so a long prompt never meets the
      argument-length limit)
    * its output is read as JSON lines and handed, one event at a time, to the
      backend's `handle` function
    * it's killed, with anything it started, on a timeout (`:cli_timeout`),
      when `handle` says stop, or when the calling process dies (`esc` kills
      the request's task, and that has to reach the CLI too)

  An Erlang port's child already leads its own process group, so killing
  the group (`kill -- -pid`) takes its children with it.
  """

  # Any of these would let a CLI bill an API account instead of the subscription.
  @api_keys ~w(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN OPENAI_API_KEY CODEX_API_KEY)

  # Non-JSON output (warnings, errors) kept for the error message.
  @max_noise 20

  @type handle :: (map(), term() -> {:cont, term()} | {:stop, term()})

  @doc """
  Runs `exe` with `args`, the prompt on stdin, and folds its JSON events
  through `handle` starting from `acc`. Returns:

    * `{:exited, status, acc, noise}` when it finished (`noise`: its non-JSON lines)
    * `{:stopped, acc}` when `handle` stopped it
    * `{:error, :not_installed | :timeout}`
  """
  @spec run(String.t(), [String.t()], String.t(), handle(), term(), keyword()) ::
          {:exited, non_neg_integer(), term(), [String.t()]}
          | {:stopped, term()}
          | {:error, :not_installed | :timeout}
  def run(exe, args, prompt, handle, acc, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Application.get_env(:tiny_axe, :cli_timeout, 300_000))

    case System.find_executable(exe) do
      nil ->
        {:error, :not_installed}

      path ->
        dir = Path.join(System.tmp_dir!(), "tiny_axe_cli_#{System.unique_integer([:positive])}")
        work = Path.join(dir, "work")
        File.mkdir_p!(work)
        File.chmod!(dir, 0o700)
        prompt_file = Path.join(dir, "prompt")
        File.write!(prompt_file, prompt)
        File.chmod!(prompt_file, 0o600)

        try do
          port =
            Port.open({:spawn_executable, System.find_executable("sh")}, [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              {:cd, work},
              {:env, env()},
              {:args, ["-c", ~s(f=$1; shift; exec "$@" < "$f"), "sh", prompt_file, path | args]}
            ])

          {:os_pid, os_pid} = Port.info(port, :os_pid)
          reaper = reaper(self(), os_pid, dir)
          deadline = System.monotonic_time(:millisecond) + timeout

          result = collect(port, handle, {acc, "", []}, deadline)
          if not match?({:exited, _, _, _}, result), do: kill(os_pid)
          send(reaper, :done)
          result
        after
          File.rm_rf(dir)
        end
    end
  end

  defp env do
    Enum.map(@api_keys, &{String.to_charlist(&1), false}) ++ [{~c"NO_COLOR", ~c"1"}]
  end

  defp collect(port, handle, {acc, buffer, noise}, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        {lines, rest} = split_lines(buffer <> data)

        case fold(lines, handle, acc, noise) do
          {:cont, acc, noise} -> collect(port, handle, {acc, rest, noise}, deadline)
          {:stop, acc} -> close(port, {:stopped, acc})
        end

      {^port, {:exit_status, status}} ->
        # A last line without a newline still counts.
        case fold(Enum.reject([buffer], &(&1 == "")), handle, acc, noise) do
          {:cont, acc, noise} -> {:exited, status, acc, Enum.reverse(noise)}
          {:stop, acc} -> {:stopped, acc}
        end
    after
      remaining -> close(port, {:error, :timeout})
    end
  end

  defp fold(lines, handle, acc, noise) do
    Enum.reduce_while(lines, {:cont, acc, noise}, fn line, {:cont, acc, noise} ->
      case JSON.decode(line) do
        {:ok, %{} = event} ->
          case handle.(event, acc) do
            {:cont, acc} -> {:cont, {:cont, acc, noise}}
            {:stop, acc} -> {:halt, {:stop, acc}}
          end

        _ ->
          {:cont, {:cont, acc, Enum.take([line | noise], @max_noise)}}
      end
    end)
  end

  defp close(port, result) do
    Port.close(port)
    result
  catch
    :error, _ -> result
  end

  defp split_lines(buffer) do
    {complete, [rest]} = buffer |> String.split("\n") |> Enum.split(-1)
    {complete |> Enum.map(&String.trim_trailing(&1, "\r")) |> Enum.reject(&(&1 == "")), rest}
  end

  # Kills the CLI's process group if the caller dies first (e.g. `esc` killed
  # the request's task), since a dead port owner doesn't stop the program, and
  # removes the prompt, which the caller's cleanup never got to.
  defp reaper(owner, os_pid, dir) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        :done ->
          :ok

        {:DOWN, ^ref, :process, _, _} ->
          kill(os_pid)
          File.rm_rf(dir)
      end
    end)
  end

  @doc false
  def kill(os_pid) do
    group = "-#{os_pid}"
    System.cmd("kill", ["-TERM", "--", group], stderr_to_stdout: true)
    Process.sleep(200)
    System.cmd("kill", ["-KILL", "--", group], stderr_to_stdout: true)
    :ok
  end

  @doc """
  Turns chat messages into what a CLI takes: the system prompt, and one
  prompt holding the conversation, any attached material (later system
  messages: web pages, files) and the request, each labelled.
  """
  @spec transcript([map()]) :: {String.t() | nil, String.t()}
  def transcript(messages) do
    {system, rest} =
      case messages do
        [%{role: "system", content: s} | rest] -> {s, rest}
        rest -> {nil, rest}
      end

    {earlier, last} =
      case List.last(rest) do
        %{role: "user"} = last -> {Enum.drop(rest, -1), last}
        _ -> {rest, nil}
      end

    sections =
      Enum.map(earlier, fn
        %{role: "system", content: c} -> "[material]\n#{c}"
        %{role: role, content: c} -> "[#{role}]\n#{c}"
      end)

    prompt =
      case {sections, last} do
        {[], %{content: c}} ->
          c

        {_, nil} ->
          Enum.join(sections, "\n\n")

        {_, %{content: c}} ->
          "The conversation so far, oldest first:\n\n" <>
            Enum.join(sections, "\n\n") <> "\n\n---\n\nThe user's new message:\n\n" <> c
      end

    {system, prompt}
  end

  @doc """
  A JSON Schema made strict: every object says `additionalProperties: false`,
  which OpenAI's structured output requires.
  """
  @spec strict_schema(term()) :: term()
  def strict_schema(%{} = schema) do
    schema = Map.new(schema, fn {k, v} -> {k, strict_schema(v)} end)

    cond do
      schema[:type] in ["object", :object] -> Map.put_new(schema, :additionalProperties, false)
      schema["type"] == "object" -> Map.put_new(schema, "additionalProperties", false)
      true -> schema
    end
  end

  def strict_schema(list) when is_list(list), do: Enum.map(list, &strict_schema/1)
  def strict_schema(other), do: other
end
