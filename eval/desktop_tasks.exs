# Tasks for `mix tiny_axe.desktop_eval` (TinyAxe.Desktop.Eval), against its
# fixed desktop: theme Solitude, font Liberation Mono, text size 12, terminal
# font 12 and padding 14, gaps 5/10, border 2, rounding 6, dwindle, volume 65,
# balanced power profile, bluetooth on, bar on top; apps Obsidian, Firefox,
# Files, Spotify, Signal, btop++; official packages include ripgrep, fd, htop,
# btop, neovim, obsidian, vlc, gimp; installed by the user: obsidian, ripgrep,
# vlc, gimp, zed, signal-desktop.
#
# expect: [{setting, value}] (a value may be {:range, lo, hi}), :unsupported
# (handed to the agent) or :question. `:dev` tasks are for tuning, `:holdout`
# ones for checking afterwards without tuning on them.

[
  ## Appearance

  %{
    id: "theme_named",
    split: :dev,
    prompt: "switch to tokyo night",
    expect: [{"theme", "Tokyo Night"}]
  },
  %{
    id: "theme_and_bar",
    split: :holdout,
    prompt: "use the nord theme and move the bar to the bottom",
    expect: [{"theme", "Nord"}, {"bar_position", "bottom"}]
  },
  %{
    id: "terminal_font_bigger",
    split: :dev,
    prompt: "make the terminal font bigger",
    expect: [{"terminal_font_size", {:range, 13, 16}}]
  },
  %{
    id: "terminal_font_exact",
    split: :holdout,
    prompt: "set the terminal font size to 15",
    expect: [{"terminal_font_size", "15"}]
  },
  %{
    id: "text_everywhere",
    split: :dev,
    prompt: "bigger text everywhere",
    expect: [{"text_size", {:range, 13, 16}}]
  },
  %{
    id: "no_gaps_square",
    split: :holdout,
    prompt: "no gaps between windows and square corners",
    expect: [{"window_gaps_inner", "0"}, {"window_gaps_outer", "0"}, {"window_rounding", "0"}]
  },
  %{
    id: "tabs_bottom",
    split: :dev,
    prompt: "put the terminal tabs at the bottom",
    expect: [{"terminal_tab_position", "bottom"}]
  },
  %{
    id: "scrolling",
    split: :holdout,
    prompt: "use the scrolling layout for windows",
    expect: [{"window_layout", "scrolling"}]
  },
  %{
    id: "no_animations",
    split: :dev,
    prompt: "turn off animations",
    expect: [{"animations", "off"}]
  },
  %{
    id: "see_through_terminal",
    split: :holdout,
    prompt: "make the terminal a bit see-through",
    expect: [{"terminal_opacity", {:range, 0.6, 0.95}}]
  },
  %{id: "hide_bar", split: :dev, prompt: "hide the bar", expect: [{"bar", "off"}]},
  %{
    id: "night_light",
    split: :holdout,
    prompt: "turn on the night light",
    expect: [{"nightlight", "on"}]
  },

  ## Sound, devices, default apps

  %{id: "volume_exact", split: :dev, prompt: "set the volume to 30", expect: [{"volume", "30"}]},
  %{
    id: "louder",
    split: :holdout,
    prompt: "louder please",
    expect: [{"volume", {:range, 70, 85}}]
  },
  %{id: "mute_mic", split: :dev, prompt: "mute my microphone", expect: [{"mic_muted", "on"}]},
  %{
    id: "headset",
    split: :holdout,
    prompt: "play sound through my usb headset",
    expect: [{"audio_output", "USB Headset"}]
  },
  %{
    id: "bluetooth_off",
    split: :dev,
    prompt: "turn bluetooth off",
    expect: [{"bluetooth", "off"}]
  },
  %{
    id: "power_saver",
    split: :holdout,
    prompt: "switch to the power saver profile",
    expect: [{"power_profile", "power-saver"}]
  },
  %{
    id: "default_browser",
    split: :dev,
    prompt: "make firefox my default browser",
    expect: [{"default_browser", "firefox"}]
  },

  ## Actions

  %{
    id: "screenshot_region",
    split: :holdout,
    prompt: "take a screenshot of a region",
    expect: [{"screenshot", "region"}]
  },
  %{id: "open_app", split: :dev, prompt: "open obsidian", expect: [{"launch_app", "Obsidian"}]},
  %{
    id: "open_files",
    split: :holdout,
    prompt: "open the file manager",
    expect: [{"launch_app", "Files"}]
  },
  %{
    id: "open_url",
    split: :dev,
    prompt: "go to github.com",
    expect: [{"open_url", "https://github.com"}]
  },
  %{
    id: "reminder",
    split: :holdout,
    prompt: "remind me in 20 minutes to call mum",
    expect: [{"reminder", {:range, 20, 20}}]
  },
  %{
    id: "restart_audio",
    split: :dev,
    prompt: "audio is stuck, restart it",
    expect: [{"restart", "audio"}]
  },
  %{id: "reboot", split: :holdout, prompt: "reboot the computer", expect: [{"power", "reboot"}]},

  ## Root

  %{
    id: "install_two",
    split: :dev,
    prompt: "install ripgrep and htop",
    expect: [{"install_package", "ripgrep htop"}]
  },
  %{
    id: "uninstall",
    split: :holdout,
    prompt: "uninstall vlc",
    expect: [{"remove_package", "vlc"}]
  },
  %{id: "update", split: :dev, prompt: "update the system", expect: [{"system_update", "now"}]},
  %{
    id: "service",
    split: :holdout,
    prompt: "restart the bluetooth service",
    expect: [{"system_service", "restart bluetooth"}]
  },

  ## Outside the list: for the agent

  %{
    id: "keybinding",
    split: :dev,
    prompt: "bind super+alt+n to open obsidian",
    expect: :unsupported
  },
  %{
    id: "window_rule",
    split: :holdout,
    prompt: "make firefox always open on workspace 2",
    expect: :unsupported
  },
  %{
    id: "user_service",
    split: :dev,
    prompt: "start ollama automatically at login",
    expect: :unsupported
  },
  %{id: "aur_app", split: :holdout, prompt: "install the spotify app", expect: :unsupported},

  ## Questions

  %{id: "which_theme", split: :dev, prompt: "what theme am I using?", expect: :question},
  %{
    id: "how_loud",
    split: :holdout,
    prompt: "how loud is my volume right now?",
    expect: :question
  },

  ## holdout2: written after the dev/holdout fixes on 2026-10-12, run once
  ## untuned (the first holdout was used for one fix, the window rule).

  %{
    id: "h2_gruvbox_font",
    split: :holdout2,
    prompt: "gruvbox theme with the jetbrains font",
    expect: [{"theme", "Gruvbox"}, {"font", "JetBrainsMono Nerd Font"}]
  },
  %{
    id: "h2_thicker_borders",
    split: :holdout2,
    prompt: "make the window borders thicker",
    expect: [{"window_border", {:range, 3, 6}}]
  },
  %{
    id: "h2_quieter",
    split: :holdout2,
    prompt: "turn the sound down",
    expect: [{"volume", {:range, 45, 60}}]
  },
  %{id: "h2_unmute", split: :holdout2, prompt: "unmute my mic", expect: [{"mic_muted", "off"}]},
  %{
    id: "h2_blur_on",
    split: :holdout2,
    prompt: "add blur behind transparent windows",
    expect: [{"window_blur", "on"}]
  },
  %{
    id: "h2_signal",
    split: :holdout2,
    prompt: "launch signal",
    expect: [{"launch_app", "Signal"}]
  },
  %{
    id: "h2_shutdown",
    split: :holdout2,
    prompt: "shut the computer down",
    expect: [{"power", "shutdown"}]
  },
  %{
    id: "h2_install_neovim",
    split: :holdout2,
    prompt: "install neovim",
    expect: [{"install_package", "neovim"}]
  },
  %{
    id: "h2_hotkey",
    split: :holdout2,
    prompt: "make ctrl+alt+t open a terminal",
    expect: :unsupported
  },
  %{
    id: "h2_what_font",
    split: :holdout2,
    prompt: "which font is the terminal using?",
    expect: :question
  }
]
