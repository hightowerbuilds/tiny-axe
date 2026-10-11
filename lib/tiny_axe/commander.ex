defmodule TinyAxe.Commander do
  @moduledoc """
  Turns a request like "install Vite with the React template in my tiny-app
  repo" or "how much disk space do I have?" into shell commands, and runs
  them in the `TinyAxe.Shell` sandbox.

  1. **Plan** — the model writes the commands, answering in a fixed JSON shape.
     They run in the current folder (`TinyAxe.Location`), which code tracks, or
     a subfolder of it the model names in `"dir"` (relative, checked to exist):
     given `~/code/app` a small model will "expand" it to a home folder that
     doesn't exist, so it never picks a folder outside the current one.
  2. **Check** (`Commander.Validation`) — commands that only look
     (`TinyAxe.Shell.ReadOnly`) may run in any existing folder; commands that
     change things not in the home folder itself, a hidden folder, or outside
     home and the project. `sudo`, system package managers, and commands that
     would stop tiny-axe's own processes are refused. Problems go back to the
     model.
  3. **Read-only plans run now**, without asking (in the `:read_only` sandbox);
     then the same model reads the output and answers the request.
  4. **Other plans are reviewed** — the Decider asks, per command, whether it's
     needed for what the user asked, and whether the commands together would
     do it. The plan's score is its weakest link; a doubtful plan goes back
     once with reasons. The user approves it before `execute/2` runs it.

  Events: `{:command_problems, [text]}`, `{:review, p}`, then
  `{:command_plan, %{request:, dir:, commands: [%{command:, review:}], review:,
  read_only:, use:}}`. A plan with `read_only: true` is running, not waiting:
  its command events (see `execute/2`) follow, then `{:attempt, 1}`,
  `{:delta, text}` and `:done` with the answer, led by the line saying what
  ran (`Commander.Execution.record/3`). Otherwise `:done` says what's waiting
  for approval.
  """

  alias TinyAxe.{Escalation, Location, Model, Ollama, Ops}
  alias TinyAxe.Commander.{Execution, Prompt, Review, Validation}
  alias TinyAxe.Shell.ReadOnly

  @max_rounds 4

  @schema %{
    type: "object",
    properties: %{
      commands: %{type: "array", items: %{type: "string"}},
      dir: %{type: "string"},
      reply: %{type: "string"}
    },
    required: ["commands", "reply"]
  }

  @doc """
  Plans commands, and runs them straight away if they only look. If the
  local model can't make ones that pass the checks in #{@max_rounds} rounds,
  the escalation ladder (`TinyAxe.Escalation`) may try bigger models, each
  from the start; `opts[:remote]` says whether they may run off this machine.
  """
  @spec run([Ollama.message()], String.t(), (term() -> any()), keyword()) :: :ok
  def run(history, prompt, notify, opts \\ []) do
    notify.({:stage, "planning commands…"})

    messages = [
      %{role: "system", content: Prompt.system_prompt()},
      %{role: "user", content: Prompt.first_message(history, prompt)}
    ]

    context = TinyAxe.Pipeline.context(history, prompt)

    result =
      case plan(messages, context, notify, 1, false) do
        {:gave_up, reply} ->
          why = "its commands still had problems after #{@max_rounds} tries"

          escalated = fn choice, acc ->
            case plan(messages, Map.put(context, :use, choice), notify, 1, false) do
              {:gave_up, _} -> {:fell_short, acc}
              {:error, reason} -> {:error, reason, acc}
              result -> {:ok, result}
            end
          end

          case Escalation.climb(why, Keyword.get(opts, :remote, :denied), notify, nil, escalated) do
            {:ok, result, choice} ->
              notify.({:answered_by, %{model: Model.label(choice)}})
              result

            {:none, _} ->
              {:reply, reply}
          end

        result ->
          result
      end

    case result do
      {:ok, %{read_only: true} = plan, reply} ->
        notify.({:command_plan, plan})
        run_now(plan, reply, notify)

      {:ok, plan, reply} ->
        notify.({:command_plan, plan})
        done(notify, summary(reply, plan))

      {:reply, reply} ->
        done(notify, reply)

      {:error, reason} ->
        notify.({:error, reason})
    end

    :ok
  end

  # The answer goes below the commands' output (the TUI places it from the
  # last {:attempt, _}).
  defp done(notify, text) do
    notify.({:attempt, 1})
    notify.({:done, text})
  end

  # Commands that only look: run them, then answer from what they printed.
  defp run_now(plan, reply, notify) do
    case Execution.run_read_only(plan, notify) do
      {:ok, results} ->
        notify.({:attempt, 1})
        record = Execution.record(plan, results, :read_only)

        body =
          case Execution.answer(plan, results, notify) do
            nil -> reply_or_empty(reply) <> Execution.tails(results)
            answer -> answer
          end

        notify.({:done, record <> "\n\n" <> body})

      {:refused, problems} ->
        done(
          notify,
          "I didn't run the commands; at the moment of running:\n\n" <>
            Enum.map_join(problems, "\n", &"- #{&1}")
        )
    end
  end

  defp reply_or_empty(reply) do
    if String.trim(reply) == "", do: "", else: String.trim(reply) <> "\n\n"
  end

  defp plan(messages, _context, _notify, round, _reviewed?) when round > @max_rounds do
    problems = List.last(messages).content |> String.split("\n\n") |> hd()

    {:gave_up,
     "I couldn't put together commands that work. The last attempt's problems:\n\n" <>
       problems <> "\n\nCould you say more precisely what you'd like?"}
  end

  defp plan(messages, context, notify, round, reviewed?) do
    with {:ok, %{"message" => %{"content" => json}}} <-
           Model.chat(messages, format: @schema, options: [temperature: 0.2], use: context[:use]),
         {:ok, answer} <- JSON.decode(json) do
      commands = answer |> Map.get("commands", []) |> List.wrap() |> Enum.map(&to_text/1)
      commands = Enum.reject(commands, &(&1 == ""))
      reply = to_text(Map.get(answer, "reply", ""))
      messages = messages ++ [%{role: "assistant", content: json}]

      if commands == [] do
        {:reply, reply}
      else
        case Validation.check_plan(Location.current(), to_text(answer["dir"]), commands) do
          {:ok, dir} ->
            if ReadOnly.all?(commands) do
              # Nothing to approve, so nothing to review: the output will say
              # whether they were the right commands.
              {:ok,
               %{
                 request: context.request,
                 dir: dir,
                 commands: Enum.map(commands, &%{command: &1, review: nil}),
                 review: nil,
                 read_only: true,
                 use: context[:use]
               }, reply}
            else
              {reviewed_plan, feedback} = Review.assess(dir, commands, context, notify)
              reviewed_plan = Map.merge(reviewed_plan, %{read_only: false, use: context[:use]})

              if feedback && not reviewed? do
                plan(messages ++ [user(feedback)], context, notify, round + 1, true)
              else
                {:ok, reviewed_plan, reply}
              end
            end

          {:error, problems} ->
            notify.({:command_problems, problems})

            fix =
              "tiny-axe can't run this as written:\n" <> Enum.map_join(problems, "\n", &"- #{&1}")

            plan(
              messages ++ [user(fix <> "\n\nReply with corrected JSON.")],
              context,
              notify,
              round + 1,
              reviewed?
            )
        end
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :bad_plan_json}
    end
  end

  defp to_text(value) when is_binary(value), do: String.trim(value)
  defp to_text(nil), do: ""
  defp to_text(value) when is_number(value) or is_atom(value), do: to_string(value)
  defp to_text(_value), do: ""

  @doc "Checks the working folder and commands without executing them."
  @spec check(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, [String.t()]}
  defdelegate check(dir, commands), to: TinyAxe.Commander.Validation

  @doc "Revalidates an approved plan and executes its commands in order."
  @spec execute(map(), (term() -> any())) :: :ok
  defdelegate execute(plan, notify), to: TinyAxe.Commander.Execution

  defp summary(reply, plan) do
    commands = Enum.map_join(plan.commands, "\n", &"$ #{&1.command}")

    "#{reply}\n\n**Commands** (waiting for your approval, in #{Ops.show(plan.dir)}):\n\n```console\n#{commands}\n```"
  end

  defp user(content), do: %{role: "user", content: content}
end
