defmodule TinyAxe.TUI.Workspace do
  @moduledoc "Primary feature navigation, independent of conversation jobs and drafts."

  alias TinyAxe.TUI.{Chats, FeaturePanels, MemoryChat}

  @sections [:chat, :wallet, :search, :tokens, :remote]

  def select(%{section: section} = state, section), do: state

  def select(state, section) when section in @sections do
    state = FeaturePanels.leave(state, state.section)

    state =
      if state.section == :chat, do: %{state | chat_section: state.chats.active}, else: state

    state =
      case section do
        :chat -> restore_chat(state)
        :search -> restore_search(state)
        _ -> state
      end

    state |> Map.put(:section, section) |> FeaturePanels.enter(section)
  end

  def select(state, _section), do: state

  def open_chat(state, id) do
    state = state |> select(:chat) |> Chats.switch(id)
    %{state | chat_section: state.chats.active}
  end

  # /memory remains a shortcut to the same dedicated local workspace.
  def adopt_search(state, before) do
    state = FeaturePanels.leave(state, before.section)

    %{
      state
      | section: :search,
        search_chat: state.chats.active,
        chat_section:
          if(before.section == :chat, do: before.chats.active, else: before.chat_section)
    }
  end

  defp restore_chat(state) do
    id =
      if state.chat_section in state.chats.order,
        do: state.chat_section,
        else: hd(state.chats.order)

    Chats.switch(state, id)
  end

  defp restore_search(state) do
    case state.search_chat && Chats.get(state, state.search_chat) do
      %{local_only: true} ->
        Chats.switch(state, state.search_chat)

      _ ->
        state = MemoryChat.ensure_local(state)
        %{state | search_chat: state.chats.active}
    end
  end
end
