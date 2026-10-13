defmodule TinyAxe.TUI.Explained do
  @moduledoc """
  The Explained tab: what tiny-axe can do and how to reach each part, in one
  place, because there are a lot of them. Plain text kept here; it's wrapped
  to the panel's width so it scrolls like the other panels. `/help` (or
  `/explained`) opens it.
  """

  import TinyAxe.TUI.Presentation, only: [styled: 1, styled: 2, styled: 3]

  # {heading, [{name, what it does}]}
  @sections [
    {"Getting around",
     [
       {"Tabs",
        "Chat, Wallet, Gemma Search, Tokens, Remote and Explained along the top. Click one, or press F1–F5 for the first five. /help opens this one."},
       {"Chats",
        "Inside Chat, the second row holds your conversations. + or /new starts one, alt+←/→ or ctrl+o switches, alt+1…9 picks one, /chat close closes the one on screen. Work keeps going in chats you're not looking at."},
       {"Keys",
        "enter sends · alt+enter new line · esc cancels the chat on screen · pgup/pgdn scroll · ctrl+y copies the newest code block · ctrl+k compacts · ctrl+t sidebar · ctrl+l clears the chat · ctrl+c quits."},
       {"Questions",
        "Anything that needs your yes pops up wherever you are, with a coloured banner: green only reads, yellow changes something or leaves the machine, red spends money or can't be undone. d shows the details. Questions from other chats say which chat asked."}
     ]},
    {"Asking and answering",
     [
       {"How a request goes",
        "Jev (or the local model) decides what kind of request it is, Gemma answers, code gets compiled and tested in a sandbox, and the answer is checked before you see it. /route on shows that decision above each answer."},
       {"Files in a request",
        "Mention @path to give the model a file or folder; otherwise the decider picks the project files a request is about."},
       {"The web",
        "When a request needs it, tiny-axe searches the web and reads pages, and answers cite their sources."},
       {"Where you are",
        "Like a shell: cd <folder> and pwd at the prompt. Requests that name a folder (\"in my tiny-app repo\") go there. The title shows 📍 and the folder."},
       {"Bigger model",
        "When the local model falls short, tiny-axe can ask Claude Haiku 5.5 on your subscription. It asks you first, and stops at 90% of your usage windows."},
       {"Context",
        "ctx 58% in the status bar is how full the model's memory is. At half, older turns are compacted into a summary in the sidebar."}
     ]},
    {"Files and edits",
     [
       {"Code edits",
        "Ask for changes and each file shows as a diff: y accept · n skip · esc skip the rest. ctrl+z undoes the last accepted set."},
       {"File tasks",
        "\"Move my screenshots into Pictures/2026\", \"write notes.md summarising @talk.txt\". You see the whole plan first and nothing happens until y. Deleting means the Trash, never gone for good. ctrl+z undoes the last plan, even after a restart."}
     ]},
    {"Commands",
     [
       {"Running commands",
        "\"Run the tests\", \"how much disk space do I have?\". Commands that only look run at once, read-only. Anything else shows first and runs only on y, in a sandbox where only that folder (and tool installs) can change. Keys, credentials and browser profiles are hidden from every command."}
     ]},
    {"Your desktop",
     [
       {"Look and sound",
        "\"Make the terminal font bigger\", \"switch to Tokyo Night\", \"volume to 30\", \"mute my mic\", \"turn bluetooth off\". Gemma picks from a fixed list and code checks every value. Risky ones (bluetooth, wifi, default apps, power) ask first."},
       {"Actions",
        "\"Take a screenshot of a region\", \"open obsidian\", \"go to github.com\", \"remind me in 20 minutes…\", \"reboot\"."},
       {"Packages and services",
        "\"Install htop\", \"uninstall vlc\", \"update the system\", \"restart the bluetooth service\". Through the root helper (mix tiny_axe.os_setup sets it up). A snapper snapshot comes first, and each one asks."},
       {"Anything else",
        "Keybindings, window rules, startup apps: Haiku does it with commands outside the sandbox, each one asked. ~/.config is snapshotted around it."},
       {"Undo", "/look lists the settings now; /look undo puts the last desktop change back."}
     ]},
    {"Agents, tools and Chrome",
     [
       {"Agents",
        "Requests that need tools go to an agent (Haiku by default) whose every tool call goes through tiny-axe's gate: reads run, anything that sends or changes something asks you. It can split a job across up to 4 sub-agents. Type tools to see what's connected."},
       {"Your Chrome",
        "/chrome on lets the agent use your own Chrome, signed in to your shops (with the Claude in Chrome extension). It reads freely, asks before acting on a site you haven't allowed, and never places an order without you."},
       {"Dead ends",
        "Browser paths that failed are remembered per site for 30 days, so the agent doesn't repeat them."}
     ]},
    {"Buying",
     [
       {"Wallet",
        "The Wallet tab (or /credit-card) adds a card: its number goes only into tiny-axe's vault and your keyring, never to a model. Each card can have a purpose, allowed shops, limits and a PIN."},
       {"Limits",
        "Every order is checked against what you asked for, the per-order and daily caps (shown in the Wallet tab), the shop and the card's rules. A failed check can't be approved."},
       {"Placing an order",
        "tiny-axe holds the \"Place order\" click, reads the page, and shows you the total. You type the exact total to buy, then it clicks once, re-checking that nothing changed, and keeps the receipt."},
       {"Leash",
        "/leash on, for this session: browser actions run without asking, and orders whose checks all pass go through, with a receipt line. Commands and card PINs still ask. /leash off puts the questions back."}
     ]},
    {"From your phone",
     [
       {"Remote chat",
        "/remote on (or the Remote tab) lets you chat with this tiny-axe from the site's Chat tab while it's open. Those messages go to their own 🌐 chat here."},
       {"Approvals",
        "What the 🌐 chat needs a yes for (purchases, tool calls, sending to Claude, sandboxed commands) shows as a card on the Chat tab. You approve with your approval PIN, plus the exact total for a purchase."},
       {"Approval PIN",
        "/remote pin sets it here. The page sends only a one-time proof made from it, and tiny-axe checks it; the site never has the PIN. Three wrong tries switch approvals off. /remote approvals on|off."},
       {"Never from the phone",
        "Desktop and OS changes, a card's PIN or CVC, file plans and edits. A card nobody answers in 9 minutes is a no."}
     ]},
    {"Memory, history and the site",
     [
       {"History",
        "Every chat is kept on disk, with card numbers and keys removed. /history lists them, /history N reopens one."},
       {"Gemma Search",
        "The Gemma Search tab (or /memory) searches everything you've said, on this machine only: words, exact text, or a question Gemma answers with quotes. /memory review on lets Gemma read your history in the background to find things better."},
       {"The site",
        "/account sets up your account on the website, /site opens your chat archive there. Syncing chats up is off unless you turn it on."},
       {"Tokens",
        "The Tokens tab (or /token) shows how much Haiku, Jev and Gemma have used: this session, today, 7 days, and Claude's usage windows."}
     ]},
    {"Slash commands",
     [
       {"Chats", "/new · /chats · /chat N · /chat close · /history · /history N"},
       {"Look up", "/memory … · /token · /site · /account · tools · pwd · cd <folder>"},
       {"Desktop", "/look · /look undo"},
       {"Buying",
        "/credit-card · /credit-card list · /credit-card forget NAME · /leash on|off · /chrome on|off"},
       {"Remote", "/remote · /remote on|off · /remote pin · /remote approvals on|off"},
       {"Display", "/route on|off · /help"}
     ]}
  ]

  @doc "The tab's lines, wrapped to `width` columns."
  def lines(width) do
    width = max(width, 30)

    intro =
      [styled("What tiny-axe can do", :cyan, [:bold])] ++
        Enum.map(
          wrap("Each part, what it's for, and how to reach it. ↑/↓ or page keys scroll.", width),
          &styled(&1, :dark_gray)
        ) ++ [styled("")]

    intro ++
      Enum.flat_map(@sections, fn {heading, items} ->
        [styled(heading, :yellow, [:bold])] ++
          Enum.flat_map(items, &item(&1, width)) ++ [styled("")]
      end)
  end

  defp item({name, text}, width) do
    [styled("  " <> name, nil, [:bold])] ++
      Enum.map(wrap(text, width - 4), &styled("    " <> &1))
  end

  defp wrap(text, width) do
    text
    |> String.split(" ")
    |> Enum.reduce([], fn word, acc ->
      case acc do
        [line | rest] when line != "" ->
          if String.length(line) + 1 + String.length(word) <= width,
            do: [line <> " " <> word | rest],
            else: [word | acc]

        _ ->
          [word | acc]
      end
    end)
    |> Enum.reverse()
  end
end
