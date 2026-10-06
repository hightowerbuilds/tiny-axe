defmodule TinyAxe.Organizer.Documents do
  @moduledoc """
  Prepares document contents for a file plan without saving them.
  Captures the original version before generation, includes the plan's source
  material, and keeps the stronger draft after at most one review-driven retry.
  The returned snapshot hash is checked again when the approved plan executes.
  """

  alias TinyAxe.{Decider, Files, Model, Ops}

  @doc "Attaches a checked draft and original-file snapshot to a write operation."
  @spec prepare(map(), String.t(), String.t(), [map()], (term() -> any())) :: map()
  def prepare(%{op: :write, path: path} = op, prompt, steps, web_context, notify) do
    notify.({:stage, "writing #{Ops.show(path)}…"})

    old =
      case Files.read(path, 20_000) do
        {:ok, text, false} -> text
        _ -> nil
      end

    content = generate(op, old, prompt, steps, web_context, notify, 0.5)
    check = check_document(op, prompt, content)
    if check == nil, do: notify.({:decider_unavailable, "checking #{Ops.show(path)}"})

    # Rewrite once when the check doubts it; without a check, keep the first draft.
    {content, check} =
      if is_number(check) and check < Decider.review_threshold() do
        retry = generate(op, old, prompt, steps, web_context, notify, 0.9)
        retry_check = check_document(op, prompt, retry)

        if is_number(retry_check) and retry_check > check,
          do: {retry, retry_check},
          else: {content, check}
      else
        {content, check}
      end

    notify.({:wrote, %{path: Ops.show(path), check: check}})

    op
    |> Map.merge(%{content: content, old: old, old_hash: old && Ops.hash(old), check: check})
  end

  def prepare(op, _prompt, _steps, _web_context, _notify), do: op

  defp generate(op, old, prompt, steps, web_context, notify, temperature) do
    markdown? = Path.extname(op.path) in [".md", ".markdown"]

    sources =
      op.sources
      |> Enum.map_join("\n\n", fn abs ->
        case Files.read(abs, 8_000) do
          {:ok, text, cut?} ->
            "===== #{Ops.show(abs)} =====\n#{text}#{if cut?, do: "\n(cut off)"}\n===== end ====="

          {:error, _} ->
            ""
        end
      end)

    ask =
      [
        "Write the complete contents of the file #{Ops.show(op.path)}.",
        "What it should contain: #{op.about}",
        "The user's request: #{prompt}",
        "This file is part of a plan that runs once the user approves it:\n#{steps}\n" <>
          "Describe files by where they will be after the plan, and name only real files.",
        old && "The file exists; revise it as asked. Its current contents:\n#{old}",
        sources != "" && "Source files:\n#{sources}",
        web_context != [] &&
          "Use the web search results you were given, and end with a \"Sources\" section linking them.",
        "Reply with only the file's contents#{if markdown?, do: ", in Markdown"}: no preamble, " <>
          "no code fence around the whole file."
      ]
      |> Enum.filter(& &1)
      |> Enum.join("\n\n")

    messages =
      [
        %{
          role: "system",
          content: "You are a skilled writer. Write clear, well-organised documents."
        }
      ] ++
        web_context ++ [user(ask)]

    notify.({:attempt, 1})

    case Model.stream_chat(messages, &notify.({:delta, &1}),
           options: [temperature: temperature],
           on_usage: &notify.({:usage, &1})
         ) do
      {:ok, text} -> text |> unfence() |> String.trim() |> Kernel.<>("\n")
      {:error, _} -> old || ""
    end
  end

  # Models sometimes wrap the whole file in a code fence anyway.
  defp unfence(text) do
    case Regex.run(~r/\A\s*```[\w-]*[^\n]*\n(.*)\n```\s*\z/s, text) do
      [_, inner] -> inner
      nil -> text
    end
  end

  defp check_document(op, prompt, content) do
    question = %{
      fits: %{
        type: :noul,
        instructions: "Is this document what was asked for, complete and well written?"
      }
    }

    %{asked: op.about, user_request: prompt, document: content}
    |> Decider.decide(question)
    |> Decider.p(:fits)
  end

  defp user(content), do: %{role: "user", content: content}
end
