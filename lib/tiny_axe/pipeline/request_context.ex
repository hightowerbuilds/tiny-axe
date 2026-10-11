defmodule TinyAxe.Pipeline.RequestContext do
  @moduledoc """
  The conversation, location, and date shared by routing and verification.
  """

  alias TinyAxe.{Location, Ollama, Ops}

  def recent(history) do
    history
    |> Enum.filter(&(&1.role in ["user", "assistant"]))
    |> Enum.take(-4)
    |> Enum.map_join("\n", &"#{&1.role}: #{String.slice(&1.content, 0, 300)}")
  end

  @doc """
  What every decision about a request sees (routing, the verifier, plan and
  command reviews): the request, the recent turns and any summary of older
  ones (so "now run it" can be resolved), where tiny-axe is, and the commands
  it has run.
  """
  @spec build([Ollama.message()], String.t()) :: map()
  def build(history, prompt) do
    summary =
      Enum.find_value(history, fn
        %{role: "system", content: "Summary of the earlier conversation" <> _ = c} -> c
        _ -> nil
      end)

    [
      request: prompt,
      current_folder: Ops.show(Location.current()),
      recent_conversation: recent(history),
      conversation_summary: summary,
      commands_tiny_axe_ran: commands_ran(history)
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  @doc """
  The commands tiny-axe actually ran earlier in the conversation, one line per
  run (the "Ran in …" line that leads each run's record, from
  `TinyAxe.Commander.Execution.record/3`), the last five. A reply that refers
  to these isn't claiming something that didn't happen.
  """
  @spec commands_ran([Ollama.message()]) :: String.t()
  def commands_ran(history) do
    history
    |> Enum.filter(&(&1.role == "assistant"))
    |> Enum.flat_map(&Regex.scan(~r/^\*?(Ran in .+?)\*?$/m, &1.content, capture: :all_but_first))
    |> List.flatten()
    |> Enum.take(-5)
    |> Enum.join("\n")
  end

  def today do
    NaiveDateTime.local_now() |> NaiveDateTime.to_date() |> Calendar.strftime("%A, %B %-d, %Y")
  end
end
