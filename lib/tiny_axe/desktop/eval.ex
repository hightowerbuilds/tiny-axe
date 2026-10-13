defmodule TinyAxe.Desktop.Eval do
  @moduledoc """
  Scores the desktop route (`TinyAxe.Desktop.decide/4`) on fixed tasks
  (`eval/desktop_tasks.exs`) with the real local model and decider, against
  a fixed desktop (`Fixture`): canned current values, temporary config
  files, a made-up app list. Nothing is applied and nothing on the computer
  is read for the answers, so runs are comparable.

  Each task expects changes (`[{setting, value}]`, where a value may be
  `{:range, lo, hi}`), `:unsupported` (for the agent) or `:question`.
  Outcomes:

    * `:right` — the local model's plan was right and would run (or ask,
      for risky items) without escalating
    * `:right_asked` — right, but doubtful, so the user would be asked
    * `:escalated` — the local model gave up or was doubted and wrong: a
      bigger model would take it (with `--haiku`, it does)
    * `:wrong` — a wrong plan that would have run: the number that matters
    * `:error`
  """

  alias TinyAxe.Desktop
  alias TinyAxe.Desktop.Eval.Fixture

  @doc "Runs the tasks; returns a summary map (and writes it to eval/results)."
  def run(tasks, opts \\ []) do
    Fixture.install()

    try do
      remote = if opts[:haiku], do: :allowed, else: :denied

      results =
        Enum.map(tasks, fn task ->
          t0 = System.monotonic_time(:millisecond)
          result = Desktop.decide([], task.prompt, fn _ -> :ok end, remote: remote)
          outcome = score(task.expect, result)
          ms = System.monotonic_time(:millisecond) - t0

          if opts[:verbose],
            do:
              IO.puts(
                "#{outcome |> to_string() |> String.pad_trailing(12)} #{task.id} (#{ms} ms) #{describe(result)}"
              )

          %{
            id: task.id,
            split: task.split,
            prompt: task.prompt,
            outcome: outcome,
            ms: ms,
            got: describe(result)
          }
        end)

      summary(results)
    after
      Fixture.uninstall()
    end
  end

  @doc false
  def score(expect, result) do
    case {expect, result} do
      {:question, {:reply, _}} ->
        :right

      # Already as asked: nothing to change is the right outcome.
      {changes, {:reply, "Already as asked" <> _}} when is_list(changes) ->
        :right

      {:unsupported, {:unsupported, _}} ->
        :right

      {changes, {:ok, got, _}} when is_list(changes) ->
        if same?(changes, got), do: :right, else: :wrong

      {changes, {:doubtful, got, _}} when is_list(changes) ->
        if same?(changes, got), do: :right_asked, else: :escalated

      {_, {:gave_up, _, _}} ->
        :escalated

      {_, {:doubtful, _, _}} ->
        :escalated

      {_, {:error, _}} ->
        :error

      # A plan that runs when a question or the agent was expected, or the reverse.
      {_, {:ok, _, _}} ->
        :wrong

      {_, _} ->
        :escalated
    end
  end

  defp same?(expected, got) do
    got = Map.new(got, &{&1.setting.id, &1.value})

    map_size(got) == length(expected) and
      Enum.all?(expected, fn {id, want} -> matches?(want, got[id]) end)
  end

  defp matches?(_want, nil), do: false
  defp matches?({:range, lo, hi}, v), do: match?({n, _} when n >= lo and n <= hi, Float.parse(v))
  defp matches?(want, v), do: String.downcase(to_string(want)) == String.downcase(v)

  defp describe({:ok, changes, _}), do: "run: " <> changes_text(changes)
  defp describe({:doubtful, changes, _}), do: "ask: " <> changes_text(changes)
  defp describe({:gave_up, _, _}), do: "gave up"
  defp describe({:reply, r}), do: "reply: " <> String.slice(r, 0, 60)
  defp describe({:unsupported, _}), do: "to the agent"
  defp describe({:error, r}), do: "error: #{inspect(r)}"
  defp describe(other), do: inspect(other)

  defp changes_text(changes), do: Enum.map_join(changes, ", ", &"#{&1.setting.id}=#{&1.value}")

  defp summary(results) do
    count = fn list, o -> Enum.count(list, &(&1.outcome == o)) end

    by_split =
      results
      |> Enum.group_by(& &1.split)
      |> Map.new(fn {split, list} ->
        {split,
         %{
           tasks: length(list),
           right: count.(list, :right),
           right_asked: count.(list, :right_asked),
           escalated: count.(list, :escalated),
           wrong: count.(list, :wrong),
           error: count.(list, :error)
         }}
      end)

    %{
      model: Application.get_env(:tiny_axe, :model),
      decider: inspect(Application.get_env(:tiny_axe, :decider)),
      splits: by_split,
      median_ms: results |> Enum.map(& &1.ms) |> median(),
      results: results
    }
  end

  defp median([]), do: 0

  defp median(list) do
    sorted = Enum.sort(list)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defmodule Fixture do
    @moduledoc "The fixed desktop the eval runs against (a `TinyAxe.Desktop.Runner`)."
    @behaviour TinyAxe.Desktop.Runner

    @themes [
      "Catppuccin",
      "Everforest",
      "Gruvbox",
      "Kanagawa",
      "Nord",
      "Rose Pine",
      "Solitude",
      "Tokyo Night"
    ]
    @fonts ["iA Writer Mono S", "JetBrainsMono Nerd Font", "Liberation Mono"]
    @repo ~w(ripgrep fd htop btop neovim obsidian firefox chromium vlc gimp git zed)
    @explicit ~w(obsidian ripgrep vlc gimp zed signal-desktop)
    @options %{
      "general:gaps_in" => ~s({"css":"5 5 5 5"}),
      "general:gaps_out" => ~s({"css":"10 10 10 10"}),
      "general:border_size" => ~s({"int":2}),
      "decoration:rounding" => ~s({"int":6}),
      "general:layout" => ~s({"str":"dwindle"}),
      "decoration:dim_inactive" => ~s({"bool":false}),
      "decoration:inactive_opacity" => ~s({"float":1.0}),
      "decoration:blur:enabled" => ~s({"bool":false}),
      "animations:enabled" => ~s({"bool":true}),
      "group:groupbar:enabled" => ~s({"bool":true})
    }

    def install do
      dir =
        Path.join(
          System.tmp_dir!(),
          "tiny-axe-desktop-eval-#{System.unique_integer([:positive])}"
        )

      apps = Path.join(dir, "applications")
      File.mkdir_p!(apps)

      for {id, name} <- [
            {"obsidian", "Obsidian"},
            {"firefox", "Firefox"},
            {"org.gnome.Nautilus", "Files"},
            {"spotify", "Spotify"},
            {"signal-desktop", "Signal"},
            {"btop", "btop++"}
          ] do
        File.write!(
          Path.join(apps, id <> ".desktop"),
          "[Desktop Entry]\nType=Application\nName=#{name}\nExec=#{id}\n"
        )
      end

      File.write!(
        Path.join(dir, "ghostty"),
        "font-family = \"Liberation Mono\"\nfont-size = 12\nwindow-padding-x = 14\nwindow-padding-y = 14\n"
      )

      File.write!(Path.join(dir, "looknfeel.lua"), "-- look'n'feel\n")
      File.write!(Path.join(dir, "shell.json"), ~s({"bar":{"position":"top","transparent":true}}))

      previous =
        {Application.get_env(:tiny_axe, :desktop_runner),
         Application.get_env(:tiny_axe, :desktop)}

      Application.put_env(:tiny_axe, :desktop_eval_previous, {previous, dir})
      Application.put_env(:tiny_axe, :desktop_runner, __MODULE__)

      Application.put_env(:tiny_axe, :desktop,
        ghostty_config: Path.join(dir, "ghostty"),
        hypr_look: Path.join(dir, "looknfeel.lua"),
        omarchy_shell: Path.join(dir, "shell.json"),
        app_dirs: [apps]
      )
    end

    def uninstall do
      {{runner, desktop}, dir} = Application.get_env(:tiny_axe, :desktop_eval_previous)

      put = fn k, v ->
        if v, do: Application.put_env(:tiny_axe, k, v), else: Application.delete_env(:tiny_axe, k)
      end

      put.(:desktop_runner, runner)
      put.(:desktop, desktop)
      File.rm_rf(dir)
    end

    @impl true
    def cmd("omarchy", args), do: omarchy(args)
    def cmd("hyprctl", ["getoption", name, "-j"]), do: {Map.get(@options, name, "{}"), 0}
    def cmd("hyprctl", _), do: {"", 0}
    def cmd("wpctl", ["get-volume", "@DEFAULT_AUDIO_SINK@"]), do: {"Volume: 0.65\n", 0}
    def cmd("wpctl", ["get-volume", "@DEFAULT_AUDIO_SOURCE@"]), do: {"Volume: 1.00\n", 0}
    def cmd("pactl", ["get-default-sink"]), do: {"alsa_output.analog\n", 0}

    def cmd("pactl", ["list", "sinks"]),
      do:
        {"Sink #1\n\tName: alsa_output.analog\n\tDescription: Built-in Audio Analog Stereo\nSink #2\n\tName: usb_headset\n\tDescription: USB Headset\n",
         0}

    def cmd("powerprofilesctl", ["get"]), do: {"balanced\n", 0}

    def cmd("powerprofilesctl", ["list"]),
      do:
        {"  performance:\n    Driver: x\n\n* balanced:\n    Driver: x\n\n  power-saver:\n    Driver: x\n",
         0}

    def cmd("pacman", ["-Qqe"]), do: {Enum.join(@explicit, "\n") <> "\n", 0}

    def cmd("pacman", ["-Si", "--", name]),
      do:
        if(name in @repo,
          do: {"Name : #{name}\n", 0},
          else: {"error: package '#{name}' was not found\n", 1}
        )

    def cmd(_program, _args), do: {"", 0}

    defp omarchy(["theme", "list"]), do: {Enum.join(@themes, "\n") <> "\n", 0}
    defp omarchy(["theme", "current"]), do: {"Solitude\n", 0}
    defp omarchy(["font", "list"]), do: {Enum.join(@fonts, "\n") <> "\n", 0}
    defp omarchy(["font", "current"]), do: {"Liberation Mono\n", 0}
    defp omarchy(["display", "text", "size"]), do: {"text size: 12 (default) px\n", 0}
    defp omarchy(["hyprland", "monitor", "scaling"]), do: {"1\n", 0}
    defp omarchy(["brightness", "display"]), do: {"100\n", 0}
    defp omarchy(["toggle", "nightlight", "--status"]), do: {~s({"enabled":false}), 0}
    defp omarchy(["toggle", "idle", "status"]), do: {~s({"enabled":true}), 0}
    defp omarchy(["toggle", "enabled", "bar-off"]), do: {"", 1}
    defp omarchy(["bluetooth", "power", "is-on"]), do: {"", 0}
    defp omarchy(["default", "browser"]), do: {"chrome\n", 0}
    defp omarchy(["default", "editor"]), do: {"nvim\n", 0}
    defp omarchy(["default", "terminal"]), do: {"ghostty\n", 0}
    defp omarchy(["hw", "touchpad"]), do: {"", 1}
    defp omarchy(_), do: {"", 0}
  end
end
