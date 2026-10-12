defmodule TinyAxe.TUI.ChatHistory do
  @moduledoc """
  `/history`: the chats kept on disk (`TinyAxe.History`), from this launch
  and earlier ones.

    * `/history` lists the 20 most recent, numbered, newest first
    * `/history words` lists those that have the words
    * `/history N` reopens chat N of the last list: in the chat on screen if
      nothing's been asked there yet, else as a new chat (`/new`), with its
      transcript and context; or shows it, if it's open already

  A reopened chat goes on in the same history. Every chat is on the website
  too (your page of tiny-axe's website, under Chats; `/site`).
  """

  alias TinyAxe.History
  alias TinyAxe.TUI.Chats
  import TinyAxe.TUI.Conversation, only: [add_meta: 2]

  @shown 20

  @doc "Handles `/history` typed at the prompt; nil for anything else."
  def submit(state) do
    prompt = state.input |> ExRatatui.textarea_get_value() |> String.trim()

    case Regex.run(~r/\A\/history(?:\s+(.*))?\z/s, prompt) do
      nil ->
        nil

      match ->
        ExRatatui.textarea_set_value(state.input, "")
        arg = match |> Enum.at(1, "") |> String.trim()

        state =
          case Integer.parse(arg) do
            {n, ""} -> reopen(state, n)
            _ -> list(state, arg)
          end

        {:noreply, state}
    end
  end

  defp list(state, query) do
    chats = History.list(query: query, limit: @shown)

    state =
      if Enum.any?(chats, & &1.local_only),
        do: TinyAxe.TUI.MemoryChat.ensure_local(state),
        else: state

    cond do
      chats == [] and query == "" ->
        add_meta(state, "no chats kept yet: each chat is kept once you've asked something")

      chats == [] ->
        add_meta(state, "no kept chat has “#{query}”")

      true ->
        which = if query == "", do: "recent chats", else: "chats with “#{query}”"

        state =
          add_meta(
            state,
            "#{which}, newest first · /history N reopens one · every chat: /site"
          )

        state =
          chats
          |> Enum.with_index(1)
          |> Enum.reduce(state, fn {chat, n}, acc -> add_meta(acc, line(acc, chat, n)) end)

        %{state | history_shown: Enum.map(chats, & &1.id)}
    end
  end

  defp line(state, chat, n) do
    open =
      case Chats.kept_as(state, chat.id) do
        nil -> ""
        id -> " ◂ open as chat #{Chats.position(state, id)}"
      end

    "#{n} · #{describe(chat)}#{open}"
  end

  @doc "A kept chat in one line: when, its title, how long, where."
  def describe(chat) do
    where = if chat.folder, do: " · #{chat.folder}", else: ""

    "#{when_(chat.updated)} · #{chat.title} · #{chat.messages} message#{if chat.messages == 1, do: "", else: "s"}#{where}"
  end

  defp reopen(state, n) do
    case n >= 1 && Enum.at(state.history_shown, n - 1) do
      id when is_binary(id) -> open(state, id)
      _ -> add_meta(state, "no chat #{n} in the last list: /history lists them")
    end
  end

  @doc """
  Reopens a kept chat by its id (as `/history N` does), or shows it if it's
  open already.
  """
  def open(state, id) do
    case Chats.kept_as(state, id) do
      nil ->
        case History.load(id) do
          {:ok, kept} ->
            state
            |> Chats.reopen(kept)
            |> add_meta(
              "reopened “#{kept.title}” from #{when_(kept.started)}; it goes on in the same history"
            )

          {:error, _reason} ->
            add_meta(state, "couldn't read that chat from the history")
        end

      open ->
        Chats.switch(state, open)
    end
  end

  # When, in local time: "Oct 11 15:30".
  defp when_(iso) when is_binary(iso) do
    case NaiveDateTime.from_iso8601(iso) do
      {:ok, naive} ->
        {{y, m, d}, {h, min, _}} =
          :calendar.universal_time_to_local_time(NaiveDateTime.to_erl(naive))

        Calendar.strftime(NaiveDateTime.new!(y, m, d, h, min, 0), "%b %-d %H:%M")

      _ ->
        "?"
    end
  end

  defp when_(_), do: "?"
end
