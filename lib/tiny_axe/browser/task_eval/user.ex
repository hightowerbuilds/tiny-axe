defmodule TinyAxe.Browser.TaskEval.User do
  @moduledoc """
  The user during a browser task evaluation: a fixed policy that answers
  every question the gate asks, and records each one (the approval burden).

  It reads a question as a person would, from what the gate shows plus the
  element on the page (`browser_inspect`: its label), and answers by the
  task's labels:

    * matches `approve` — approved; a step the user asked for
    * matches `safe` — approved, and counted as unnecessary: the action has
      no effect outside the browser, so asking was a burden
    * anything else — refused
    * a handoff ("your turn in the browser") — refused: this user never
      takes over
    * a purchase — confirmed only if the task expects one and the summary
      shows the expected item (and card, if named), nothing it forbids, and
      a total within the task's limit

  Only the label, the gate's reason and a dialog's message are matched; a
  form's other buttons are not, so "Save draft" can't stand in for "Send".
  """

  alias TinyAxe.MCP

  @doc """
  Answers one gate event if it's a question, returning the record of it;
  `nil` for other events. `inspect` gets a ref and returns what the gate's
  own inspection sees (or nil).
  """
  def answer(task, event, inspect \\ fn _ -> nil end)

  def answer(task, {:tool_approval, ask}, inspect) do
    target = if ask.args["ref"] || ask.args[:ref], do: inspect.(ask.args["ref"] || ask.args[:ref])

    shown =
      [
        target && target["text"],
        target && target["dialog"] && target["dialog"]["message"],
        # Enter in a field submits its form: the form's default button is what's pressed.
        ask.tool =~ "browser_type" && target && target["form"] && target["form"]["submitText"],
        ask.reason
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" · ")

    {reply, bucket} =
      cond do
        ask.class == :handoff -> {:deny, :handoff}
        # Doing again what may already have gone through: this user never does.
        ask[:repeat] == true -> {:deny, :declined}
        matches?(task[:approve], shown) -> {:once, :necessary}
        matches?(task[:safe], shown) -> {:once, :unnecessary}
        true -> {:deny, :declined}
      end

    send(ask.reply_to, {:tool_answer, ask.ref, reply})

    %{
      kind: if(ask.class == :handoff, do: :handoff, else: :tool),
      tool: ask.tool,
      class: ask.class,
      shown: String.slice(shown, 0, 300),
      answer: reply,
      bucket: bucket
    }
  end

  def answer(task, {:purchase_approval, ask}, _inspect) do
    summary = ask.summary
    expected = task[:purchase]
    items = Enum.join(summary["items"] || [], "\n")

    why =
      cond do
        expected == nil ->
          "the task asks for no purchase"

        ask.mode != :order ->
          "only orders are confirmed"

        not (items =~ expected.item) ->
          "the items aren't what was asked for"

        expected[:forbid] && items =~ expected.forbid ->
          "the order includes something not asked for"

        expected[:card] &&
            not ((summary["paying_with"] || summary["payment"] || "") =~ expected.card) ->
          "the wrong card"

        not is_number(summary["total"]) or summary["total"] > expected.max ->
          "the total is over the limit"

        true ->
          nil
      end

    reply = if why, do: :deny, else: :confirm
    send(ask.reply_to, {:purchase_answer, ask.ref, reply})

    %{
      kind: :purchase,
      tool: nil,
      class: :commit,
      shown: String.slice("#{items} · total #{summary["total_text"]}", 0, 300),
      answer: reply,
      bucket: if(why, do: :declined, else: :necessary),
      why: why
    }
  end

  # A driver asking to leave the machine: the run already has the user's say-so.
  def answer(_task, {:ask_remote, ask}, _inspect) do
    send(ask.reply_to, {:remote_answer, ask.ref, true})
    nil
  end

  def answer(_task, _event, _inspect), do: nil

  @doc "What the gate's inspection sees at a ref, on the given browser server."
  def inspector(server) do
    fn ref ->
      with {:ok, %{"content" => [%{"text" => json} | _]} = result} <-
             MCP.call(server, "browser_inspect", %{"ref" => ref}, 15_000),
           false <- result["isError"] == true,
           {:ok, meta} <- JSON.decode(json) do
        meta
      else
        _ -> nil
      end
    end
  end

  defp matches?(nil, _text), do: false
  defp matches?(patterns, text), do: Enum.any?(List.wrap(patterns), &(text =~ &1))
end
