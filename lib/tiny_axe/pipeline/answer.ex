defmodule TinyAxe.Pipeline.Answer do
  @moduledoc """
  Generates, checks, and verifies answers, retaining the best attempt across escalation.
  """

  alias TinyAxe.{CodeCheck, Decider, Escalation, Files, Location, Model, Ops}
  alias TinyAxe.Pipeline.RequestContext

  @system_prompts %{
    code:
      "You are a careful programming assistant. Put all code in ONE fenced block with the " <>
        "language named, complete and compilable on its own. For Elixir and Python, include " <>
        "doctests that show correct behaviour: `iex>` examples in each public function's " <>
        "@doc for Elixir, `>>>` examples in docstrings for Python. They are run for you, so " <>
        "do not call `doctest` or add a test runner. After the block, add at most two " <>
        "sentences of explanation. Do not explain how to run it.",
    writing:
      "You are a skilled editor and writer. Reply with only the requested text, in the " <>
        "user's requested tone and length. No alternatives, preamble or list of changes " <>
        "unless asked.",
    question:
      "You are a knowledgeable assistant. Answer directly and concisely, then add detail if useful."
  }

  @false_claim_fix """
  Your answer says you ran, installed or executed something, or that you're about to. \
  You can't run commands. Rewrite it so the user runs them: give each command in a \
  code block, say where to run it, and what to expect. The user never saw your earlier \
  answer or this message, so don't mention either.
  """

  # The local model tries first. If it falls short, the escalation ladder
  # (TinyAxe.Escalation) tries bigger models, each starting afresh; if they
  # fall short too, the highest-rated attempt from any of them is the answer.
  def run(messages, request, notify, remote) do
    run = %{messages: messages, request: request, notify: notify, best: nil, last: nil, n: 0}

    case rung(run, nil, config(:max_attempts, 3)) do
      {:done, text, _run} ->
        notify.({:done, text})

      {:fell_short, why, run} ->
        escalated = fn choice, run ->
          case rung(%{run | messages: messages}, choice, config(:escalate_attempts, 2)) do
            {:done, text, _run} -> {:ok, text}
            {:fell_short, _why, run} -> {:fell_short, run}
            {:error, reason, run} -> {:error, reason, run}
          end
        end

        case Escalation.climb(why, remote, notify, run, escalated) do
          {:ok, text, choice} ->
            notify.({:answered_by, %{model: Model.label(choice)}})
            notify.({:done, text})

          {:none, run} ->
            finish(run)
        end

      {:error, reason, _run} ->
        notify.({:error, reason})
    end
  end

  # One model's attempts at the request (`use`: nil for the local model), at
  # most `max`. Returns `{:done, text, run}` for an answer to give,
  # `{:fell_short, why, run}` when none was good enough, or
  # `{:error, reason, run}`. `run` holds what every attempt shares: the
  # messages, `request` (the verifier's view of the task), `notify`, `n` (the
  # attempt number across all models), `last` (the latest attempt) and `best`
  # (the highest-rated verified attempt, from any model).
  defp rung(run, use, max, tried \\ 0, temperature \\ 0.4) do
    n = run.n + 1
    run = %{run | n: n}
    run.notify.({:attempt, n})

    with {:ok, text} <-
           Model.stream_chat(run.messages, &run.notify.({:delta, &1}),
             options: [temperature: temperature],
             use: use,
             on_usage: &run.notify.({:usage, &1}),
             on_trim: &run.notify.({:trimmed, &1})
           ) do
      run = %{run | last: %{text: text, n: n, use: use}}
      run.notify.({:stage, "checking code…"})
      check = CodeCheck.run(text)
      run.notify.({:check, check})
      last? = tried + 1 >= max

      case check do
        {:ran, %{status: :failed} = result} when last? ->
          {:fell_short,
           "the code still failed its check (#{result.summary}) after #{plural(tried + 1, "attempt")}",
           run}

        {:ran, %{status: :failed} = result} ->
          # Concrete feedback beats resampling, so keep temperature low.
          fix = [
            %{role: "assistant", content: text},
            %{role: "user", content: fix_prompt(result)}
          ]

          rung(%{run | messages: run.messages ++ fix}, use, max, tried + 1, 0.3)

        _ ->
          verify_and_judge(run, text, check, {use, max, tried, temperature})
      end
    else
      {:error, reason} -> {:error, reason, run}
    end
  end

  defp verify_and_judge(run, text, check, {use, _max, _tried, _temperature} = where) do
    run.notify.({:stage, "verifying…"})

    case verify(run.request, text, check) do
      {:ok, verdict} ->
        run.notify.({:verify, verdict})
        addresses = Decider.p(verdict, :addresses)
        claim = Decider.p(verdict, :false_claim) || 0.0

        if addresses == nil do
          # No verdict: say so and answer, rather than resample on nothing.
          run.notify.({:decider_unavailable, "verifying the answer"})
          {:done, text, run}
        else
          # An answer that claims to have done what it can't is only as good as its honesty.
          score = min(addresses, 1 - claim)
          run |> remember(text, score, use) |> judge(text, score, claim, where)
        end

      {:error, reason} ->
        {:error, reason, run}
    end
  end

  # Accept, report falling short, send back a false claim, or resample.
  defp judge(run, text, score, claim, {use, max, tried, temperature}) do
    cond do
      score >= config(:accept_threshold, 0.7) ->
        {:done, text, run}

      tried + 1 >= max ->
        {:fell_short,
         "no answer reached the verifier's threshold (the best scored #{round(run.best.score * 100)}/100)",
         run}

      claim >= config(:false_claim_threshold, 0.5) ->
        fix = [
          %{role: "assistant", content: text},
          %{role: "user", content: @false_claim_fix}
        ]

        rung(%{run | messages: run.messages ++ fix}, use, max, tried + 1, 0.3)

      true ->
        # No concrete feedback to give, so nudge sampling for a different answer.
        rung(run, use, max, tried + 1, min(temperature + 0.25, 1.1))
    end
  end

  defp remember(%{best: best} = run, text, score, use) do
    if best == nil or score > best.score,
      do: %{run | best: %{text: text, n: run.n, score: score, use: use}},
      else: run
  end

  # Out of attempts everywhere: answer with the highest-rated one, which may be
  # an earlier attempt, or else the last one.
  defp finish(%{best: %{} = best, last: last} = run) do
    if best.n != last.n,
      do: run.notify.({:chose, %{attempt: best.n, score: best.score, attempts: last.n}})

    if best.use, do: run.notify.({:answered_by, %{model: Model.label(best.use)}})
    run.notify.({:done, best.text})
  end

  defp finish(%{last: %{} = last} = run) do
    if last.use, do: run.notify.({:answered_by, %{model: Model.label(last.use)}})
    run.notify.({:done, last.text})
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"

  defp fix_prompt(%{language: lang, summary: summary, output: output}) do
    """
    I compiled and tested your #{lang} code in a sandbox. Result: #{summary}.

    ```
    #{output}
    ```

    Fix the problems and reply with the complete corrected answer in the same format.
    A failing doctest can be wrong itself: check each failing example against the
    user's request, and correct whichever one disagrees with it, the code or the
    expected value. Keep the doctests rather than deleting them. The user never saw your earlier answer or this message, so write
    as if answering for the first time: don't mention errors, fixes or earlier attempts.
    """
  end

  defp verify(request, response, check) do
    check_note =
      case check do
        {:ran, %{language: lang, summary: summary}} ->
          "#{lang} code was compiled and tested: #{summary}"

        {:skipped, reason} ->
          "not run (#{reason})"
      end

    state = Map.merge(request, %{response: response, automated_code_check: check_note})

    Decider.decide(state, %{
      addresses: %{
        type: :noul,
        instructions:
          "Does the response fully and correctly address the request, without errors or " <>
            "missing parts?"
      },
      # Small models say "I ran npm install" when nothing ran.
      false_claim: %{
        type: :noul,
        instructions:
          "Does the response claim that the assistant ran a command, installed software or " <>
            "did something on the computer (or is about to), rather than telling the user " <>
            "what to run?"
      }
    })
  end

  defp location_note do
    here = Location.current()

    "You're working in #{Ops.show(here)} (tiny-axe's current folder; relative paths mean " <>
      "this folder). What's in it:\n#{Location.listing(here, 30)}"
  end

  def system_prompt(kind) do
    "You are tiny-axe, an assistant running locally on the user's computer " <>
      "(model: #{config(:model, "unknown")}). Today is #{RequestContext.today()}. When a request needs " <>
      "current information, tiny-axe searches the web and gives you the results. It can " <>
      "also give you files from the user's project (#{Files.display(Files.root())}) and " <>
      "offer your changes to them for the user to approve. This answer can't run shell " <>
      "commands: give any command in a code block, and never say you ran, installed or " <>
      "executed anything. If the user wants a command run, tell them to ask tiny-axe to " <>
      "run it; it will show the command for approval and run it in a sandbox.\n\n" <>
      capabilities() <> "\n\n" <> location_note() <> "\n\n" <> @system_prompts[kind]
  end

  # What tiny-axe as a whole can do, so an answer about it is true (a small
  # model otherwise says "I'm an AI, I can't buy things").
  defp capabilities do
    buying =
      if TinyAxe.Purchases.enabled?(),
        do: "Purchases are ON",
        else: "Purchases are OFF (the user turns them on with `mix tiny_axe.purchases on`)"

    "What tiny-axe can do besides this answer: it can move, copy and write files " <>
      "(after approval, undoable with ctrl+z), and requests that need the web or connected " <>
      "tools go to an agent that uses tiny-axe's own browser and MCP servers, with the user " <>
      "approving anything that sends something. It can buy things for the user: #{buying}. " <>
      "When on, the agent goes through a shop to checkout, and tiny-axe shows the order and " <>
      "only buys after the user types the exact total, within their limits. Card details " <>
      "are never typed into this chat: the user stores the card in their system keyring " <>
      "(`secret-tool store --label=\"tiny-axe card\" service tiny-axe key card-1`, then " <>
      "`mix tiny_axe.purchases card add \"My card\" --keyring card-1`), and tiny-axe's code " <>
      "fills it in at checkout. No model, including you, ever sees it. A card saved at the " <>
      "shop works too. If the user asks about any of this, explain it accurately."
  end

  defp config(key, default), do: Application.get_env(:tiny_axe, key, default)
end
