defmodule TinyAxe.Desktop.System do
  @moduledoc """
  The desktop's other settings and its actions, in the same shape as the
  appearance settings (`TinyAxe.Desktop.Settings`):

    * settings, with a value read back and undo: volume, sound and mic mute,
      audio output, bluetooth, power profile, default browser, editor and
      terminal, touchpad (where there is one)
    * actions, which just happen and can't be undone: screenshot, screen
      recording, restarting a component, launching an app, opening a web
      page, a reminder, and lock, log out, reboot or shut down

  `risk: :ask` marks what waits for the user's y/n every time (the user's
  choice, 2026-10-12: wifi and bluetooth changes, config such as default
  apps, and anything else that isn't a low-risk look-and-feel change);
  the rest runs at once. Launching an app, opening a page, a screenshot and
  a reminder change nothing that lasts, so they count as low-risk.

  Apps are launched the way Omarchy's own keybindings do (`uwsm-app`), and
  pages open with `xdg-open`, both detached with `setsid -f`, so tiny-axe
  doesn't wait for them; every program gets its arguments as a list, never
  through a shell.
  """

  alias TinyAxe.Desktop.Runner

  @sink "@DEFAULT_AUDIO_SINK@"
  @source "@DEFAULT_AUDIO_SOURCE@"

  @doc "The settings and actions available on this computer."
  @spec all() :: [map()]
  def all do
    Enum.filter(settings() ++ actions(), fn item ->
      case item[:available] do
        nil -> true
        fun -> fun.()
      end
    end)
  end

  ## Settings

  defp settings do
    [
      %{
        id: "volume",
        group: "sound",
        summary: "speaker volume, in percent (louder or quieter is about 10)",
        kind: {:int, 0, 100},
        # Without a number in the request, a change this big is a guess.
        max_jump: 20,
        current: fn -> volume(@sink) |> elem(0) end,
        apply: &wpctl(["set-volume", @sink, "#{&1}%"])
      },
      %{
        id: "sound_muted",
        group: "sound",
        summary: "whether the speakers are muted",
        kind: {:enum, ~w(on off)},
        current: fn -> volume(@sink) |> elem(1) end,
        apply: &wpctl(["set-mute", @sink, if(&1 == "on", do: "1", else: "0")])
      },
      %{
        id: "mic_muted",
        group: "sound",
        summary: "whether the microphone is muted",
        kind: {:enum, ~w(on off)},
        current: fn -> volume(@source) |> elem(1) end,
        apply: &wpctl(["set-mute", @source, if(&1 == "on", do: "1", else: "0")])
      },
      %{
        id: "audio_output",
        group: "sound",
        summary: "which speakers or headphones sound plays through",
        kind: {:choice, fn -> Enum.map(sinks(), &elem(&1, 1)) end},
        current: fn ->
          with {:ok, name} <- Runner.ok("pactl", ["get-default-sink"]),
               {_, label} <- List.keyfind(sinks(), name, 0),
               do: label,
               else: (_ -> nil)
        end,
        apply: &set_output/1
      },
      %{
        id: "bluetooth",
        group: "devices",
        summary: "bluetooth on or off (remembered across restarts)",
        kind: {:enum, ~w(on off)},
        risk: :ask,
        current: fn ->
          case Runner.cmd("omarchy", ["bluetooth", "power", "is-on"]) do
            {:error, _} -> nil
            {_, 0} -> "on"
            {_, _} -> "off"
          end
        end,
        apply: &omarchy(["bluetooth", "power", &1])
      },
      %{
        id: "power_profile",
        group: "devices",
        summary: "the power profile: performance, balanced or power-saver",
        kind: {:choice, &power_profiles/0},
        current: fn -> out("powerprofilesctl", ["get"]) end,
        apply: &ok("powerprofilesctl", ["set", &1])
      },
      default_app("default_browser", "the browser links open in", "browser", browsers()),
      default_app("default_editor", "the editor Omarchy opens files in", "editor", editors()),
      default_app("default_terminal", "the terminal Omarchy opens", "terminal", terminals()),
      %{
        id: "touchpad",
        group: "devices",
        summary: "whether the touchpad works",
        kind: {:enum, ~w(on off)},
        available: fn -> match?({_, 0}, Runner.cmd("omarchy", ["hw", "touchpad"])) end,
        current: fn -> nil end,
        apply: &omarchy(["toggle", "touchpad", &1])
      }
    ]
  end

  # Only the choices that are installed here.
  defp default_app(id, summary, what, programs) do
    %{
      id: id,
      group: "apps",
      summary: summary,
      kind: {:choice, fn -> for {name, exe} <- programs, installed?(exe), do: name end},
      risk: :ask,
      current: fn -> out("omarchy", ["default", what]) end,
      apply: &omarchy(["default", what, &1])
    }
  end

  defp browsers do
    [
      {"chromium", {:desktop, "chromium.desktop"}},
      {"chrome", {:desktop, "google-chrome.desktop"}},
      {"brave", {:desktop, "brave-browser.desktop"}},
      {"brave-origin", {:desktop, "brave-origin.desktop"}},
      {"edge", {:desktop, "microsoft-edge.desktop"}},
      {"firefox", {:desktop, "firefox.desktop"}},
      {"zen", {:desktop, "zen.desktop"}}
    ]
  end

  defp editors do
    [
      {"code", "code"},
      {"cursor", "cursor"},
      {"zed", "zeditor"},
      {"sublime_text", "subl"},
      {"helix", "helix"},
      {"vim", "vim"},
      {"emacs", "emacs"},
      {"nvim", "nvim"}
    ]
  end

  defp terminals, do: Enum.map(~w(alacritty foot ghostty kitty), &{&1, &1})

  defp installed?({:desktop, id}), do: Enum.any?(app_dirs(), &File.exists?(Path.join(&1, id)))

  defp installed?(exe) when exe == "helix",
    do: System.find_executable("helix") != nil or System.find_executable("hx") != nil

  defp installed?(exe), do: System.find_executable(exe) != nil

  ## Actions

  defp actions do
    [
      %{
        id: "screenshot",
        group: "actions",
        summary:
          "take a screenshot: smart (pick a window or region), region, windows or fullscreen",
        kind: {:enum, ~w(smart region windows fullscreen)},
        undo: :none,
        apply: &omarchy(["capture", "screenshot", &1])
      },
      %{
        id: "screen_recording",
        group: "actions",
        summary: "start or stop recording the screen",
        kind: :action,
        risk: :ask,
        undo: :none,
        apply: fn _ -> omarchy(["capture", "screenrecording"]) end
      },
      %{
        id: "restart",
        group: "actions",
        summary: "restart or reload a part of the desktop that's misbehaving",
        kind: {:enum, ~w(audio shell terminal hyprctl hyprsunset xcompose btop tmux)},
        undo: :none,
        apply: &omarchy(["restart", &1])
      },
      %{
        id: "restart_network",
        group: "actions",
        summary: "unblock and restart wifi or bluetooth",
        kind: {:enum, ~w(wifi bluetooth)},
        risk: :ask,
        undo: :none,
        apply: &omarchy(["restart", &1])
      },
      %{
        id: "launch_app",
        group: "actions",
        summary: "open an installed app by its name",
        kind: {:lookup, fn -> Enum.map(apps(), &elem(&1, 0)) end},
        undo: :none,
        apply: fn name ->
          case List.keyfind(apps(), name, 0) do
            {_, id} -> detach(["uwsm-app", "--", id])
            nil -> {:error, "#{name} isn't an installed app"}
          end
        end
      },
      %{
        id: "open_url",
        group: "actions",
        summary: "open a web page in the default browser",
        kind: :url,
        undo: :none,
        apply: &detach(["xdg-open", &1])
      },
      %{
        id: "reminder",
        group: "actions",
        summary:
          "a desktop reminder: minutes from now, then the message (e.g. \"10 check the oven\")",
        kind: :reminder,
        undo: :none,
        apply: fn value ->
          [minutes | message] = String.split(value, " ", parts: 2)
          omarchy(["reminder", minutes | message])
        end
      },
      %{
        id: "power",
        group: "actions",
        summary: "lock the screen, log out, reboot or shut down",
        kind: {:enum, ~w(lock logout reboot shutdown)},
        risk: :ask,
        undo: :none,
        apply: &omarchy(["system", &1])
      }
    ]
  end

  @doc """
  Installed apps, as `{name, desktop_id}`: entries in the applications
  folders that are shown in menus (not `NoDisplay` or `Hidden`), the user's
  own first.
  """
  @spec apps() :: [{String.t(), String.t()}]
  def apps do
    for dir <- app_dirs(),
        {:ok, files} <- [File.ls(dir)],
        file <- Enum.sort(files),
        String.ends_with?(file, ".desktop"),
        file =~ ~r/^[\w.\-]+$/,
        {:ok, text} <- [File.read(Path.join(dir, file))],
        entry = desktop_entry(text),
        entry["Type"] == "Application",
        entry["NoDisplay"] != "true" and entry["Hidden"] != "true",
        is_binary(entry["Name"]),
        uniq: true,
        do: {entry["Name"], file}
  end

  # The [Desktop Entry] group's keys (later groups, such as actions, ignored).
  defp desktop_entry(text) do
    text
    |> String.split(~r/^\[/m)
    |> Enum.find("", &String.starts_with?(&1, "Desktop Entry]"))
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^([A-Za-z]+)=(.*)$/, String.trim(line)) do
        [_, k, v] -> [{k, String.trim(v)}]
        nil -> []
      end
    end)
    |> Map.new()
  end

  defp app_dirs do
    data = System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share")
    [Path.join(data, "applications"), "/usr/share/applications"]
  end

  ## Helpers

  # "Volume: 0.45 [MUTED]" → {"45", "on"}.
  defp volume(node) do
    case Runner.ok("wpctl", ["get-volume", node]) do
      {:ok, text} ->
        level =
          case Regex.run(~r/Volume:\s*([\d.]+)/, text) do
            [_, v] -> v |> Float.parse() |> elem(0) |> Kernel.*(100) |> round() |> to_string()
            nil -> nil
          end

        {level, if(text =~ "[MUTED]", do: "on", else: "off")}

      {:error, _} ->
        {nil, nil}
    end
  end

  # pactl's sinks as {name, description}.
  defp sinks do
    case Runner.ok("pactl", ["list", "sinks"]) do
      {:ok, text} ->
        names = Regex.scan(~r/^\s*Name:\s*(.+)$/m, text, capture: :all_but_first)
        labels = Regex.scan(~r/^\s*Description:\s*(.+)$/m, text, capture: :all_but_first)
        Enum.zip(List.flatten(names), List.flatten(labels))

      {:error, _} ->
        []
    end
  end

  # The new default, and what's playing moves to it.
  defp set_output(label) do
    case List.keyfind(sinks(), label, 1) do
      {name, _} ->
        with :ok <- ok("pactl", ["set-default-sink", name]) do
          case Runner.ok("pactl", ["list", "short", "sink-inputs"]) do
            {:ok, text} ->
              for [id | _] <- Enum.map(String.split(text, "\n", trim: true), &String.split/1),
                  do: Runner.cmd("pactl", ["move-sink-input", id, name])

            _ ->
              :ok
          end

          :ok
        end

      nil ->
        {:error, "#{label} isn't an audio output here"}
    end
  end

  defp power_profiles do
    case out("powerprofilesctl", ["list"]) do
      nil ->
        []

      text ->
        ~r/^\*?\s*([\w-]+):\s*$/m |> Regex.scan(text, capture: :all_but_first) |> List.flatten()
    end
  end

  defp detach(argv), do: ok("setsid", ["-f" | argv])

  defp wpctl(args), do: ok("wpctl", args)
  defp omarchy(args), do: ok("omarchy", args)

  defp ok(program, args) do
    case Runner.ok(program, args) do
      {:ok, _} -> :ok
      {:error, why} -> {:error, why}
    end
  end

  defp out(program, args) do
    case Runner.ok(program, args) do
      {:ok, text} -> text
      {:error, _} -> nil
    end
  end
end
