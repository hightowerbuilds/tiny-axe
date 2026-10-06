defmodule TinyAxe.Commander do
  @moduledoc """
  Turns a request like "install Vite with the React template in my tiny-app
  repo" into shell commands for the user to approve. Nothing runs here:
  approved commands are run by `execute/2`, one at a time, each in the
  `TinyAxe.Shell` sandbox where only the working folder can change.

  1. **Plan** — the model writes the commands, answering in a fixed JSON shape.
     They run in the current folder (`TinyAxe.Location`), which code tracks: the
     model never picks the folder, because given `~/code/app` a small model will
     "expand" it to a home folder that doesn't exist.
  2. **Check** — the folder must exist, be inside the home folder or project,
     not be the home folder itself, and not be hidden; `sudo` is refused.
     Problems go back to the model.
  3. **Review** — the Decider asks, per command, whether it's needed for what
     the user asked, and whether the commands together would do it. The plan's
     score is its weakest link; a doubtful plan goes back once with reasons.

  Events: `{:command_problems, [text]}`, `{:review, p}`, then
  `{:command_plan, %{request:, dir:, commands: [%{command:, review:}], review:}}`
  just before `:done`.
  """

  alias TinyAxe.{Escalation, Location, Model, Ollama, Ops}
  alias TinyAxe.Commander.{Prompt, Review}

  @max_rounds 4

  @schema %{
    type: "object",
    properties: %{
      commands: %{type: "array", items: %{type: "string"}},
      reply: %{type: "string"}
    },
    required: ["commands", "reply"]
  }

  @doc """
  Plans commands. If the local model can't make ones that pass the checks in
  #{@max_rounds} rounds, the escalation ladder (`TinyAxe.Escalation`) may try
  bigger models, each from the start; `opts[:remote]` says whether they may
  run off this machine.
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
      {:ok, plan, reply} ->
        notify.({:command_plan, plan})
        notify.({:done, summary(reply, plan)})

      {:reply, reply} ->
        notify.({:done, reply})

      {:error, reason} ->
        notify.({:error, reason})
    end

    :ok
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
      commands = answer |> Map.get("commands", []) |> List.wrap() |> Enum.map(&String.trim/1)
      commands = Enum.reject(commands, &(&1 == ""))
      reply = Map.get(answer, "reply", "")
      messages = messages ++ [%{role: "assistant", content: json}]

      if commands == [] do
        {:reply, reply}
      else
        case check(Location.current(), commands) do
          {:ok, dir} ->
            {reviewed_plan, feedback} = Review.assess(dir, commands, context, notify)

            if feedback && not reviewed? do
              plan(messages ++ [user(feedback)], context, notify, round + 1, true)
            else
              {:ok, reviewed_plan, reply}
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
