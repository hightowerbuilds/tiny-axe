defmodule TinyAxe.Desktop.Settings do
  @moduledoc """
  Every desktop setting and action tiny-axe can use, as data: what it is,
  what values it takes, how to read it now and how to set it. This module
  holds the appearance ones; `TinyAxe.Desktop.System` the rest (sound,
  devices, default apps, actions). Models never write
  a command: they name a setting from this list and a value, and code checks
  the value (against the computer's own lists where there is one, such as
  `omarchy theme list`), sets it, and reads it back.

  Value kinds:

    * `{:choice, fun}`: one of the names `fun.()` returns (read from the
      computer each time)
    * `{:enum, names}`: one of a fixed list
    * `{:int, min, max}` / `{:float, min, max}`: a number in range; `+2` or
      `-2` is relative to the current value
    * `:image`: an image file that exists
    * `{:or, [words], kind}`: one of the words, or a value of `kind`
    * `:action`: no value, it just happens (undone by doing it again)

  Where they come from: Omarchy's own commands (theme, background, font,
  text size, bar, night light, idle, display scaling and brightness),
  Ghostty's config (the default terminal: font size, padding, opacity,
  cursor, tabs) and Hyprland options set in tiny-axe's block of
  `~/.config/hypr/looknfeel.lua` (gaps, borders, rounding, dimming, blur,
  animations, layout, the tab bar on grouped windows).
  """

  alias TinyAxe.Desktop.{ConfigFiles, Runner}

  @type setting :: %{
          id: String.t(),
          group: String.t(),
          summary: String.t(),
          kind: term(),
          current: (-> String.t() | nil),
          apply: (String.t() -> :ok | {:error, String.t()}),
          file: (-> String.t()) | nil
        }

  @doc "All settings, in the order they're shown."
  @spec all() :: [setting()]
  def all do
    omarchy() ++ ghostty() ++ hyprland() ++ TinyAxe.Desktop.System.all()
  end

  @doc "The setting with this id, or nil."
  @spec get(String.t()) :: setting() | nil
  def get(id), do: Enum.find(all(), &(&1.id == id))

  @doc "Setting ids, for the model's JSON schema."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(all(), & &1.id)

  ## What names a setting

  # Words a request uses when it names a setting outright: every group must
  # match (any phrase in it, at the start of a word, so "gap" matches
  # "gaps"). A change to a setting the request names needs no review
  # (`TinyAxe.Desktop`). "tab bar" is read as one word first, so the
  # desktop bar's "bar" doesn't match it.
  @names %{
    "theme" => [["theme", "colour scheme", "color scheme", "colours", "colors"]],
    "background" => [["background", "wallpaper", "bg"]],
    "font" => [["font", "typeface"]],
    "text_size" => [
      ["text", "font"],
      ["everywhere", "everything", "system", "desktop", "whole", "all apps", "global", "overall"]
    ],
    "display_scale" => [["scale", "scaling", "zoom", "hidpi", "dpi"]],
    "brightness" => [["bright", "dimmer", "darker screen"]],
    "nightlight" => [["night light", "nightlight", "night mode", "blue light"]],
    "idle_lock" => [["idle", "lock", "screensaver", "stay awake", "awake"]],
    "do_not_disturb" => [["disturb", "dnd", "silence", "notification"]],
    "bar" => [
      ["bar", "waybar", "panel"],
      ["show", "hide", "hidden", "visible", "on", "off", "back"]
    ],
    "bar_position" => [
      ["bar", "panel"],
      ["top", "bottom", "left", "right", "edge", "side", "position"]
    ],
    "bar_transparent" => [
      ["bar", "panel"],
      ["transparen", "see-through", "see through", "opaque", "solid"]
    ],
    "terminal_font_size" => [
      ["terminal", "ghostty", "console"],
      ["font", "text", "size", "bigger", "smaller", "larger"]
    ],
    "terminal_padding" => [["terminal", "ghostty"], ["padding", "margin", "space", "spacing"]],
    "terminal_opacity" => [
      ["terminal", "ghostty"],
      ["opac", "transparen", "see-through", "see through", "translucent"]
    ],
    "terminal_cursor" => [["cursor", "caret"]],
    "terminal_cursor_blink" => [["blink"]],
    "terminal_tab_bar" => [["tab"], ["terminal", "ghostty", "show", "hide", "always", "never"]],
    "terminal_tab_position" => [["tab"], ["terminal", "ghostty", "top", "bottom"]],
    "window_gaps_inner" => [["gap", "space between windows", "spacing between windows"]],
    "window_gaps_outer" => [
      ["gap", "space between windows", "spacing between windows", "screen edge"]
    ],
    "window_border" => [["border"]],
    "window_rounding" => [["round", "corner", "radius"]],
    "window_layout" => [["layout", "tiling", "dwindle", "master", "scrolling"]],
    "window_dim_inactive" => [["dim"], ["inactive", "unfocused", "window"]],
    "window_inactive_opacity" => [
      ["inactive", "unfocused", "other window"],
      ["opac", "transparen", "see-through", "see through", "translucent", "fade"]
    ],
    "window_blur" => [["blur"]],
    "animations" => [["animation", "animate", "motion"]],
    "window_tab_bar" => [["group", "tabbed"], ["tab"]],
    "volume" => [["volume", "louder", "quieter", "softer"]],
    "sound_muted" => [
      ["mute", "unmute", "silent"],
      ["sound", "speaker", "audio", "volume", "mute"]
    ],
    "mic_muted" => [["mic", "microphone"]],
    "audio_output" => [["speaker", "headphone", "headset", "output", "hdmi", "sound through"]],
    "bluetooth" => [["bluetooth"]],
    "power_profile" => [
      ["power profile", "performance", "power saver", "power-saver", "balanced", "battery saver"]
    ],
    "default_browser" => [["default"], ["browser"]],
    "default_editor" => [["default"], ["editor"]],
    "default_terminal" => [["default"], ["terminal"]],
    "touchpad" => [["touchpad", "trackpad"]],
    "screenshot" => [["screenshot", "screen shot", "capture the screen"]],
    "screen_recording" => [["record"], ["screen"]],
    "restart" => [["restart", "reload", "reset"]],
    "restart_network" => [["restart", "reset"], ["wifi", "wi-fi", "bluetooth"]],
    "launch_app" => [["open", "launch", "start", "run"]],
    "open_url" => [["open", "go to", "visit", "browse"], [".", "http", "website", "site", "page"]],
    "reminder" => [["remind"]],
    "install_package" => [["install"]],
    "remove_package" => [["remove", "uninstall"]],
    "system_update" => [["update", "upgrade"], ["system", "package", "everything", "computer"]],
    "system_service" => [["service", "daemon"]],
    "power" => [
      [
        "lock",
        "log out",
        "logout",
        "sign out",
        "reboot",
        "restart the computer",
        "shut down",
        "shutdown",
        "power off"
      ]
    ]
  }

  # Words that mean the request is about something else, even if it names
  # the setting: "bind super+b to open brave" is a keybinding, not opening Brave.
  @setup [
    "bind",
    "shortcut",
    "hotkey",
    "keybind",
    "key combo",
    "workspace",
    "always open",
    "startup",
    "at login",
    "autostart",
    "on boot",
    "window rule"
  ]
  @not_named %{
    "launch_app" => @setup,
    "open_url" => @setup,
    "restart" => ["computer", "machine", "pc", "laptop"]
  }

  @doc """
  Whether the request is about a keybinding, workspaces or what starts at
  login: no desktop item does those, so the agent takes it straight away.

      iex> TinyAxe.Desktop.Settings.setup_request?("make firefox always open on workspace 2")
      true
      iex> TinyAxe.Desktop.Settings.setup_request?("open firefox")
      false
  """
  @spec setup_request?(String.t()) :: boolean()
  def setup_request?(request) do
    text = String.downcase(request)
    Enum.any?(@setup, &Regex.match?(~r/\b#{Regex.escape(&1)}/, text))
  end

  @doc """
  Whether the request names this change's setting outright: its words
  (above), or, for a list read from the computer, the value itself
  ("switch to Tokyo Night" names the theme).

      iex> TinyAxe.Desktop.Settings.named?("terminal_tab_position", "bottom", {:enum, ~w(top bottom)}, "put the terminal tabs at the bottom")
      true
      iex> TinyAxe.Desktop.Settings.named?("bar_position", "bottom", {:enum, ~w(top bottom)}, "terminal tab bar at the bottom")
      false
  """
  @spec named?(String.t(), String.t(), term(), String.t()) :: boolean()
  def named?(id, value, kind, request) do
    text = request |> String.downcase() |> String.replace(~r/\btab\s+bar/, "tabbar")
    groups = Map.get(@names, id, [])

    by_words =
      groups != [] and
        Enum.all?(groups, fn phrases ->
          Enum.any?(phrases, &Regex.match?(~r/\b#{Regex.escape(&1)}/, text))
        end)

    excluded =
      Enum.any?(Map.get(@not_named, id, []), &Regex.match?(~r/\b#{Regex.escape(&1)}/, text))

    not excluded and
      (by_words or (match?({:choice, _}, kind) and String.contains?(squash(text), squash(value))))
  end

  defp squash(text), do: text |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "")

  ## Omarchy

  defp omarchy do
    [
      %{
        id: "theme",
        group: "desktop",
        summary: "the colour theme for the whole desktop (windows, bar, terminal, editor)",
        kind: {:choice, fn -> lines(["theme", "list"]) end},
        current: fn -> out(["theme", "current"]) end,
        apply: &omarchy(["theme", "set", &1])
      },
      %{
        id: "background",
        group: "desktop",
        summary:
          "the desktop background image: \"next\" for the theme's next one, or an image file",
        kind: {:or, ["next"], :image},
        current: &background/0,
        apply: fn
          "next" -> omarchy(["theme", "bg", "next"])
          path -> omarchy(["theme", "bg", "set", path])
        end
      },
      %{
        id: "font",
        group: "desktop",
        summary: "the monospace font used by the terminal, bar and editors",
        kind: {:choice, fn -> lines(["font", "list"]) end},
        current: fn -> out(["font", "current"]) end,
        apply: &omarchy(["font", "set", &1])
      },
      %{
        id: "text_size",
        group: "desktop",
        summary:
          "text size everywhere at once (bar, apps and terminals), in px; 12 is the default",
        kind: {:or, ["reset"], {:int, 9, 20}},
        max_jump: 4,
        current: fn ->
          with text when is_binary(text) <- out(["display", "text", "size"]),
               [_, n] <- Regex.run(~r/text size:\s*(\d+)/, text),
               do: n
        end,
        apply: &omarchy(["display", "text", "size", &1])
      },
      %{
        id: "display_scale",
        group: "display",
        summary:
          "scaling of the focused monitor (1 = none, 2 = double); \"up\" or \"down\" steps",
        kind: {:or, ["up", "down"], {:float, 0.5, 3.0}},
        current: fn -> out(["hyprland", "monitor", "scaling"]) end,
        apply: &omarchy(["hyprland", "monitor", "scaling", &1])
      },
      %{
        id: "brightness",
        group: "display",
        summary: "brightness of the focused display, in percent",
        kind: {:int, 1, 100},
        current: fn -> out(["brightness", "display"]) end,
        apply: &omarchy(["brightness", "display", "#{&1}%"])
      },
      %{
        id: "nightlight",
        group: "display",
        summary: "night light (warmer screen colours)",
        kind: {:enum, ~w(on off)},
        current: fn -> json_flag(["toggle", "nightlight", "--status"]) end,
        apply: fn want ->
          flip(want, json_flag(["toggle", "nightlight", "--status"]), ["toggle", "nightlight"])
        end
      },
      %{
        id: "idle_lock",
        group: "display",
        summary: "locking and the screensaver when idle (off keeps the computer awake)",
        kind: {:enum, ~w(on off)},
        current: fn -> json_flag(["toggle", "idle", "status"]) end,
        apply: fn
          "on" -> omarchy(["toggle", "idle", "allow-idle"])
          "off" -> omarchy(["toggle", "idle", "stay-awake"])
        end
      },
      %{
        id: "do_not_disturb",
        group: "desktop",
        summary: "switches notification do-not-disturb (silencing) on or off",
        kind: :action,
        current: fn -> nil end,
        apply: fn _ -> omarchy(["toggle", "notification", "silencing"]) end
      },
      %{
        id: "bar",
        group: "bar",
        summary: "whether the top bar is shown",
        kind: {:enum, ~w(on off)},
        current: fn ->
          case Runner.cmd("omarchy", ["toggle", "enabled", "bar-off"]) do
            {:error, _} -> nil
            {_, 0} -> "off"
            {_, _} -> "on"
          end
        end,
        apply: &omarchy(["toggle", "bar", &1])
      },
      %{
        id: "bar_position",
        group: "bar",
        summary: "which edge of the screen the bar sits on",
        kind: {:enum, ~w(top bottom left right)},
        current: fn -> shell_json(["bar", "position"]) end,
        apply: &omarchy(["bar", "position", &1])
      },
      %{
        id: "bar_transparent",
        group: "bar",
        summary: "whether the bar is see-through",
        kind: {:enum, ~w(on off)},
        current: fn ->
          case shell_json(["bar", "transparent"]) do
            "true" -> "on"
            "false" -> "off"
            other -> other
          end
        end,
        apply: &omarchy(["bar", "transparent", if(&1 == "on", do: "true", else: "false")])
      }
    ]
  end

  ## Ghostty (the default terminal)

  defp ghostty do
    [
      ghostty_setting("terminal_font_size", "font size in the terminal, in points", {:int, 6, 40},
        key: "font-size",
        max_jump: 4
      ),
      ghostty_setting(
        "terminal_padding",
        "space between the terminal's edge and its text, in pixels",
        {:int, 0, 64},
        key: "window-padding-x",
        also: ["window-padding-y"]
      ),
      ghostty_setting(
        "terminal_opacity",
        "how opaque the terminal background is (1 = solid, 0.8 = a little see-through); new windows",
        {:float, 0.3, 1.0},
        key: "background-opacity",
        default: "1"
      ),
      ghostty_setting(
        "terminal_cursor",
        "the terminal cursor's shape",
        {:enum, ~w(block bar underline block_hollow)},
        key: "cursor-style",
        default: "block"
      ),
      ghostty_setting(
        "terminal_cursor_blink",
        "whether the terminal cursor blinks",
        {:enum, ~w(on off)},
        key: "cursor-style-blink",
        default: "off",
        map: %{"on" => "true", "off" => "false"}
      ),
      ghostty_setting(
        "terminal_tab_bar",
        "when the terminal shows its tab bar: always, auto (with 2+ tabs) or never",
        {:enum, ~w(always auto never)},
        key: "window-show-tab-bar",
        default: "auto"
      ),
      ghostty_setting(
        "terminal_tab_position",
        "where the terminal's tabs sit: top or bottom",
        {:enum, ~w(top bottom)},
        key: "gtk-tabs-location",
        default: "top"
      )
    ]
  end

  defp ghostty_setting(id, summary, kind, opts) do
    key = Keyword.fetch!(opts, :key)
    map = Keyword.get(opts, :map, %{})
    back = Map.new(map, fn {k, v} -> {v, k} end)

    %{
      id: id,
      group: "terminal",
      summary: summary,
      kind: kind,
      max_jump: Keyword.get(opts, :max_jump),
      current: fn ->
        case ConfigFiles.ghostty_get(key) || Keyword.get(opts, :default) do
          nil -> nil
          v -> Map.get(back, v, v)
        end
      end,
      apply: fn value ->
        v = Map.get(map, value, value)
        pairs = Enum.map([key | Keyword.get(opts, :also, [])], &{&1, v})
        ConfigFiles.ghostty_set(pairs)
      end,
      file: &ConfigFiles.ghostty_path/0
    }
  end

  ## Hyprland (windows)

  defp hyprland do
    [
      hypr(
        "window_gaps_inner",
        "space between windows, in pixels",
        {:int, 0, 40},
        "general.gaps_in"
      ),
      hypr(
        "window_gaps_outer",
        "space between windows and the screen edge, in pixels",
        {:int, 0, 80},
        "general.gaps_out"
      ),
      hypr(
        "window_border",
        "window border width, in pixels",
        {:int, 0, 10},
        "general.border_size"
      ),
      hypr(
        "window_rounding",
        "how round window corners are, in pixels",
        {:int, 0, 30},
        "decoration.rounding"
      ),
      hypr(
        "window_layout",
        "how windows tile: dwindle (split in halves), master (one big, a stack beside it) " <>
          "or scrolling (side by side columns that scroll)",
        {:enum, ~w(dwindle master scrolling)},
        "general.layout"
      ),
      hypr(
        "window_dim_inactive",
        "dim the windows that aren't focused",
        {:enum, ~w(on off)},
        "decoration.dim_inactive"
      ),
      hypr(
        "window_inactive_opacity",
        "opacity of windows that aren't focused (1 = solid)",
        {:float, 0.5, 1.0},
        "decoration.inactive_opacity"
      ),
      hypr(
        "window_blur",
        "blur behind see-through windows",
        {:enum, ~w(on off)},
        "decoration.blur.enabled"
      ),
      hypr("animations", "window animations", {:enum, ~w(on off)}, "animations.enabled"),
      hypr(
        "window_tab_bar",
        "the tab bar on grouped (tabbed) windows; super+G groups windows into tabs",
        {:enum, ~w(on off)},
        "group.groupbar.enabled"
      )
    ]
  end

  defp hypr(id, summary, kind, option) do
    %{
      id: id,
      group: "windows",
      summary: summary,
      kind: kind,
      current: fn -> hypr_option(option, kind) end,
      apply: fn value -> ConfigFiles.hypr_set(%{option => hypr_value(value, kind)}) end,
      file: &ConfigFiles.hypr_path/0
    }
  end

  defp hypr_value(v, {:enum, ~w(on off)}), do: v == "on"
  defp hypr_value(v, {:int, _, _}), do: String.to_integer(v)
  defp hypr_value(v, {:float, _, _}), do: elem(Float.parse(v), 0)
  defp hypr_value(v, _), do: v

  defp hypr_option(option, kind) do
    name = String.replace(option, ".", ":")

    with {:ok, text} <- Runner.ok("hyprctl", ["getoption", name, "-j"]),
         {:ok, map} <- JSON.decode(text) do
      cond do
        is_boolean(map["bool"]) -> on_off(map["bool"])
        is_integer(map["int"]) and kind == {:enum, ~w(on off)} -> on_off(map["int"] != 0)
        is_integer(map["int"]) -> Integer.to_string(map["int"])
        is_number(map["float"]) -> format_float(map["float"])
        is_binary(map["css"]) -> map["css"] |> String.split() |> List.first()
        is_binary(map["str"]) -> map["str"]
        true -> nil
      end
    else
      _ -> nil
    end
  end

  ## Helpers

  defp omarchy(args) do
    case Runner.ok("omarchy", args) do
      {:ok, _} -> :ok
      {:error, why} -> {:error, why}
    end
  end

  defp out(args) do
    case Runner.ok("omarchy", args) do
      {:ok, text} -> text
      {:error, _} -> nil
    end
  end

  defp lines(args) do
    case out(args) do
      nil -> []
      text -> text |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp json_flag(args) do
    with text when is_binary(text) <- out(args),
         {:ok, %{"enabled" => enabled}} when is_boolean(enabled) <- JSON.decode(text),
         do: on_off(enabled),
         else: (_ -> nil)
  end

  # For commands that only toggle: run once if it isn't already as wanted.
  defp flip(want, now, args) do
    if now == want, do: :ok, else: omarchy(args)
  end

  defp background do
    link = Path.expand("~/.local/state/omarchy/current/background")

    case File.read_link(link) do
      {:ok, target} -> Path.expand(target, Path.dirname(link))
      _ -> nil
    end
  end

  defp shell_json(keys) do
    shell =
      Application.get_env(:tiny_axe, :desktop, [])[:omarchy_shell] ||
        "~/.config/omarchy/shell.json"

    with {:ok, text} <- File.read(Path.expand(shell)),
         {:ok, map} <- JSON.decode(text),
         v when not is_nil(v) <- get_in(map, keys) do
      to_string(v)
    else
      _ -> nil
    end
  end

  defp on_off(true), do: "on"
  defp on_off(false), do: "off"
  defp on_off(other), do: to_string(other)

  @doc false
  def format_float(f) when is_float(f) do
    f |> Float.round(2) |> :erlang.float_to_binary([:compact, decimals: 2])
  end

  def format_float(n) when is_integer(n), do: Integer.to_string(n)
end
