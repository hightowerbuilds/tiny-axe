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
  ones (so "now run it" can be resolved), and where tiny-axe is.
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
      conversation_summary: summary
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  def today do
    NaiveDateTime.local_now() |> NaiveDateTime.to_date() |> Calendar.strftime("%A, %B %-d, %Y")
  end
end
