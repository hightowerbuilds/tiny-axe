defmodule TinyAxe.TUI.MemoryChat do
  @moduledoc "Local memory commands and conversations, isolated from remote agent workflows."
  alias TinyAxe.{History, Memory}
  alias TinyAxe.TUI.{Chats, Run}
  import TinyAxe.TUI.Conversation, only: [add_meta: 2]

  @help "Local memory · /memory search words · /memory search \"exact phrase\" · /memory search --literal \"C++\" · /memory ask question · /memory next · /memory open N · /memory status · /memory review on|off|retry · /memory rebuild · /new returns to ordinary chat"

  def ensure_local(%{local_only: true} = state), do: state

  def ensure_local(state) do
    {state, id} = Chats.open_aside(state, %{local_only: true})

    state
    |> Chats.switch(id)
    |> add_meta(
      "Local memory: Gemma only. This conversation stays on this machine. /new starts an ordinary chat."
    )
  end

  def submit(state) do
    prompt = state.input |> ExRatatui.textarea_get_value() |> String.trim()

    if prompt =~ ~r/\A\/memory(?:\s|\z)/u do
      ExRatatui.textarea_set_value(state.input, "")
      state = ensure_local(state)
      if state.run, do: {:noreply, state}, else: {:noreply, command(state, prompt)}
    end
  end

  def command(state, "/memory"), do: add_meta(state, @help)

  def command(state, "/memory search " <> text) do
    case parse_search(text) do
      {:ok, query, mode} -> search(state, query, mode, 0)
      {:error, why} -> add_meta(state, why)
    end
  end

  def command(state, "/memory ask " <> question), do: ask(state, question)

  def command(
        %{memory_results: %{query: query, mode: mode, offset: offset, limit: limit, total: total}} =
          state,
        "/memory next"
      ) do
    if offset + limit < total,
      do: search(state, query, mode, offset + limit),
      else: add_meta(state, "end of results")
  end

  def command(state, "/memory open " <> number) do
    with {n, ""} when n > 0 <- Integer.parse(number),
         %{hits: hits} <- state.memory_results,
         %{} = hit <- Enum.at(hits, n - 1),
         {:ok, source} <- Memory.read(hit, radius: 1) do
      entries =
        Enum.map_join(source.entries, "\n\n", fn {e, i} ->
          "Entry #{i + 1} · #{e["kind"]}\n#{e["text"]}"
        end)

      add_meta(
        state,
        "Source: #{hit.title} · chat updated #{TinyAxe.Clock.pacific(hit.updated)}\n\n" <>
          entries
      )
    else
      {:error, :stale_source} ->
        add_meta(state, "That chat changed. Search again to refresh its source reference.")

      _ ->
        add_meta(
          state,
          "Source unavailable. Use /memory open N with a number on the current result page."
        )
    end
  end

  def command(state, "/memory status"),
    do: job(state, "/memory status", fn -> {:status, Memory.status()} end)

  def command(state, "/memory rebuild"),
    do: job(state, "/memory rebuild", fn -> {:status, Memory.rebuild()} end)

  def command(state, "/memory review " <> choice) when choice in ["on", "off", "retry"] do
    job(state, "/memory review " <> choice, fn ->
      result =
        if choice == "retry", do: Memory.retry_reviews(), else: Memory.review(choice == "on")

      if choice == "off", do: Memory.Review.pause(), else: Memory.Review.wake()
      {:status, result}
    end)
  end

  def command(state, _), do: add_meta(state, @help)

  def parse_search("--literal " <> text) do
    text = String.trim(text)

    text =
      if String.starts_with?(text, "\"") and String.ends_with?(text, "\"") and
           String.length(text) >= 2,
         do: String.slice(text, 1, String.length(text) - 2),
         else: text

    if text == "", do: {:error, "enter literal text"}, else: {:ok, text, :literal}
  end

  def parse_search(text), do: {:ok, String.trim(text), :words}

  def ask(state, question) do
    question = TinyAxe.Tools.Redact.secrets(question)
    id = state.saved_as
    job(state, question, fn -> {:answer, Memory.Recall.ask(question, exclude: id)} end)
  end

  defp search(state, query, mode, offset) do
    query = TinyAxe.Tools.Redact.secrets(query)
    id = state.saved_as

    job(state, "/memory search " <> query, fn ->
      {:search, Memory.search(query, mode: mode, offset: offset, exclude: id)}
    end)
  end

  defp job(state, prompt, fun) do
    # Save the local-only marker before any retrieved content can be recorded.
    History.save([state])
    History.sync()
    state = Run.start(state, fn notify -> notify.({:memory_result, fun.()}) end)

    %{
      state
      | pending_prompt: prompt,
        transcript: state.transcript ++ [{:user, prompt}],
        scroll: :bottom,
        status: "local memory…"
    }
  end

  def event(state, {kind, {:ok, result}}) do
    state = %{state | run: nil, pending_prompt: nil, status: "local memory · Gemma only"}

    case kind do
      :status ->
        add_meta(
          state,
          coverage(result) <>
            " · model: #{Memory.Model.name()} (local only)" <> review_status(result)
        )

      :search ->
        show_results(state, result)

      :answer ->
        state = %{state | transcript: state.transcript ++ [{:assistant, result.answer}]}
        show_results(state, Map.merge(result, %{total: length(result.hits), offset: 0, limit: 8}))
    end
  end

  def event(state, {_, {:error, why}}), do: Run.fail(state, to_string(why))

  defp show_results(state, result) do
    state = %{state | memory_results: result}

    label =
      if Map.has_key?(result, :query),
        do: "#{result.total} matching entries",
        else: "#{length(result.hits)} evidence passages"

    state =
      add_meta(
        state,
        label <> " · " <> coverage(result.coverage) <> " · /memory open N · /memory next"
      )

    result.hits
    |> Enum.with_index(1)
    |> Enum.reduce(state, fn {hit, n}, s ->
      add_meta(
        s,
        "#{n} · #{hit.title} · #{hit.kind} · entry #{hit.position + 1} · chat updated #{TinyAxe.Clock.pacific(hit.updated)}" <>
          if(Map.has_key?(hit, :generated_note),
            do: " · found via generated Gemma note; original quote below",
            else: ""
          ) <>
          "\n#{hit.excerpt}"
      )
    end)
  end

  defp review_status(%{review: r}) do
    "\nGemma review #{if(r.enabled, do: "on", else: "off")} · #{r.ready}/#{r.segments} prepared passages reviewed · " <>
      "#{r.unprepared_entries} entries awaiting preparation · #{r.failed} failed passages · " <>
      "/memory review on|off|retry. Pausing keeps existing notes. Foreground tasks interrupt review."
  end

  defp review_status(_), do: ""

  defp coverage(c) do
    base = "#{c.chats}/#{c.total} chats indexed, #{c.entries} entries"

    if c.failures == [],
      do: base,
      else: base <> " · INCOMPLETE: unreadable chats #{Enum.join(c.failures, ", ")}"
  end
end
