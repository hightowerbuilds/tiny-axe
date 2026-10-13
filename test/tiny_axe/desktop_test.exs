defmodule TinyAxe.DesktopTest do
  use ExUnit.Case, async: false

  alias TinyAxe.{Desktop, Decider, FakeDesktop, Model}
  alias TinyAxe.Desktop.{ConfigFiles, Undo, Value}

  doctest TinyAxe.Desktop.Value
  doctest TinyAxe.Desktop.Settings

  @keys ~w(model_backend decider script_model script_decider models)a

  setup do
    previous = Map.new(@keys, &{&1, Application.get_env(:tiny_axe, &1)})

    on_exit(fn ->
      for {k, v} <- previous,
          do:
            if(v == nil,
              do: Application.delete_env(:tiny_axe, k),
              else: Application.put_env(:tiny_axe, k, v)
            )

      FakeDesktop.reset()
      File.rm(ConfigFiles.ghostty_path())
      File.rm(ConfigFiles.hypr_path())
      File.rm(Undo.path())
    end)

    File.write!(
      ConfigFiles.ghostty_path(),
      "# Font\nfont-family = \"Liberation Mono\"\nfont-size = 12\n"
    )

    File.write!(ConfigFiles.hypr_path(), "-- Change the default Omarchy look'n'feel.\n")
    File.rm(Undo.path())
    desktop()
    # Reviews pass; "does the user want a change?" (asked when no item fits) is no.
    Decider.Script.script(fn
      :change, _, _ -> 0.1
      _, _, _ -> 0.9
    end)

    :ok
  end

  # A desktop on Solitude, with three themes; hyprctl reports no errors
  # unless `errors` says otherwise. Theme changes are remembered.
  defp desktop(opts \\ []) do
    theme = :counters.new(1, [])
    themes = ["Solitude", "Tokyo Night", "Gruvbox"]
    errors = Keyword.get(opts, :errors, fn -> "" end)

    FakeDesktop.script(fn
      "omarchy", ["theme", "list"] ->
        {Enum.join(themes, "\n") <> "\n", 0}

      "omarchy", ["theme", "current"] ->
        {Enum.at(themes, :counters.get(theme, 1)) <> "\n", 0}

      "omarchy", ["theme", "set", name] ->
        :counters.put(theme, 1, Enum.find_index(themes, &(&1 == name)))
        {"", 0}

      "omarchy", ["font", "list"] ->
        {"Liberation Mono\nJetBrainsMono Nerd Font\n", 0}

      "omarchy", ["font", "current"] ->
        {"Liberation Mono\n", 0}

      "omarchy", ["restart", "terminal"] ->
        {"", 0}

      "hyprctl", ["configerrors"] ->
        {errors.(), 0}

      "hyprctl", ["reload"] ->
        {"ok", 0}

      "wpctl", ["get-volume", "@DEFAULT_AUDIO_SINK@"] ->
        {"Volume: 0.65\n", 0}

      "wpctl", ["set-volume" | _] ->
        {"", 0}

      "omarchy", ["bluetooth", "power", "is-on"] ->
        {"", 0}

      "omarchy", ["bluetooth", "power", _] ->
        {"", 0}

      "omarchy", ["reminder" | _] ->
        {"", 0}

      "setsid", _ ->
        {"", 0}

      "hyprctl", ["getoption", "decoration:rounding", "-j"] ->
        {~s({"option":"decoration:rounding","int":6,"set":true}), 0}

      _program, _args ->
        {"", 1}
    end)
  end

  defp plan(changes, reply \\ "Done.") do
    owner = self()

    Model.Script.script(fn messages, opts ->
      send(owner, {:asked, messages, opts})
      JSON.encode!(%{changes: changes, reply: reply})
    end)
  end

  defp run(prompt, opts \\ []) do
    me = self()
    Desktop.run([], prompt, &send(me, {:event, &1}), opts)
    events()
  end

  defp events do
    receive do
      {:event, e} -> [e | events()]
    after
      0 -> []
    end
  end

  defp done(events), do: Enum.find_value(events, &(match?({:done, _}, &1) && elem(&1, 1)))

  describe "values" do
    test "numbers, relative steps and ranges" do
      assert Value.parse({:int, 6, 40}, "14pt", "12") == {:ok, "14"}
      assert Value.parse({:int, 6, 40}, "-2", "12") == {:ok, "10"}
      assert {:error, why} = Value.parse({:int, 6, 40}, "60", "12")
      assert why =~ "outside 6–40"
      assert {:error, _} = Value.parse({:int, 6, 40}, "+2", nil)
      assert Value.parse({:float, 0.3, 1.0}, "0.85", "1") == {:ok, "0.85"}
    end

    test "choices ignore case and spacing, and list the real ones when wrong" do
      kind = {:choice, fn -> ["Tokyo Night", "Gruvbox"] end}
      assert Value.parse(kind, "tokyo-night", nil) == {:ok, "Tokyo Night"}
      assert {:error, why} = Value.parse(kind, "Dracula", nil)
      assert why =~ "Tokyo Night, Gruvbox"
    end

    test "words before kinds, and toggling flips the current value" do
      assert Value.parse({:or, ["next"], :image}, "Next", nil) == {:ok, "next"}
      assert {:error, _} = Value.parse({:or, ["next"], :image}, "/no/such.png", nil)
      assert Value.parse({:enum, ~w(on off)}, "toggle", "on") == {:ok, "off"}
    end
  end

  describe "config files" do
    test "Ghostty lines are replaced where they are, or added, and Ghostty reloads" do
      assert {:ok, before} =
               ConfigFiles.ghostty_set([{"font-size", "14"}, {"cursor-style", "bar"}])

      assert before =~ "font-size = 12"
      text = File.read!(ConfigFiles.ghostty_path())
      assert text =~ "# Font\nfont-family = \"Liberation Mono\"\nfont-size = 14\n"
      assert text =~ "cursor-style = bar\n"
      assert ConfigFiles.ghostty_get("font-size") == "14"
      assert_received {:desktop, "omarchy", ["restart", "terminal"]}
    end

    test "Hyprland values go in tiny-axe's block, which is rewritten in place" do
      assert {:ok, _} = ConfigFiles.hypr_set(%{"decoration.rounding" => 8})

      assert {:ok, _} =
               ConfigFiles.hypr_set(%{"general.gaps_in" => 0, "decoration.blur.enabled" => true})

      text = File.read!(ConfigFiles.hypr_path())

      assert text =~ "-- Change the default Omarchy look'n'feel.\n\n-- tiny-axe: begin"
      assert length(String.split(text, "-- tiny-axe: begin")) == 2
      assert text =~ "rounding = 8,"
      assert text =~ "gaps_in = 0,"
      assert text =~ "blur = {\n      enabled = true,"

      assert ConfigFiles.hypr_values() ==
               %{
                 "decoration.rounding" => 8,
                 "general.gaps_in" => 0,
                 "decoration.blur.enabled" => true
               }

      assert {:ok, _} =
               ConfigFiles.hypr_set(%{
                 "decoration.rounding" => nil,
                 "general.gaps_in" => nil,
                 "decoration.blur.enabled" => nil
               })

      assert File.read!(ConfigFiles.hypr_path()) == "-- Change the default Omarchy look'n'feel.\n"
    end

    test "a change Hyprland reports errors for is put back" do
      calls = :counters.new(1, [])

      desktop(
        errors: fn ->
          :counters.add(calls, 1, 1)
          if :counters.get(calls, 1) == 2, do: "looknfeel.lua:5: unknown config key", else: ""
        end
      )

      original = File.read!(ConfigFiles.hypr_path())
      assert {:error, why} = ConfigFiles.hypr_set(%{"decoration.rounding" => 8})
      assert why =~ "unknown config key"
      assert File.read!(ConfigFiles.hypr_path()) == original
    end
  end

  describe "requests" do
    test "Gemma's change is checked, made without asking, read back and undoable" do
      plan([%{setting: "terminal_font_size", value: "+2"}], "Made the terminal font bigger.")
      events = run("make the terminal font bigger")

      assert File.read!(ConfigFiles.ghostty_path()) =~ "font-size = 14"
      text = done(events)
      assert text =~ "Done without asking"
      assert text =~ "terminal font size: 12 → 14"
      assert text =~ "`/look undo`"

      assert_received {:asked, [_system, %{content: first}], opts}
      assert first =~ "terminal_font_size — font size in the terminal, in points — now: 12"
      assert opts[:use] == nil

      assert Desktop.undo() =~ "terminal_font_size put back"
      assert File.read!(ConfigFiles.ghostty_path()) =~ "font-size = 12"
      assert Desktop.undo() == "no desktop changes to undo"
    end

    test "an omarchy setting runs its command, and undo sets the value from before" do
      plan([%{setting: "theme", value: "tokyo night"}])
      events = run("switch to tokyo night")

      assert_received {:desktop, "omarchy", ["theme", "set", "Tokyo Night"]}
      assert done(events) =~ "theme: Solitude → Tokyo Night"

      Desktop.undo()
      assert_received {:desktop, "omarchy", ["theme", "set", "Solitude"]}
    end

    test "a value that isn't a real choice goes back with the choices, then the fix runs" do
      owner = self()
      tries = :counters.new(1, [])

      Model.Script.script(fn messages, _ ->
        :counters.add(tries, 1, 1)
        send(owner, {:asked, messages})
        value = if :counters.get(tries, 1) == 1, do: "Dracula", else: "Gruvbox"
        JSON.encode!(%{changes: [%{setting: "theme", value: value}], reply: ""})
      end)

      events = run("use a dark retro theme")

      assert [problems] = for({:desktop_problems, p} <- events, do: p)
      assert hd(problems) =~ "isn't one of: Solitude, Tokyo Night, Gruvbox"
      assert_received {:asked, _}
      assert_received {:asked, retry}
      assert List.last(retry).content =~ "Reply with corrected JSON"
      assert done(events) =~ "Solitude → Gruvbox"
    end

    test "a change to a setting the request names isn't reviewed" do
      owner = self()

      Decider.Script.script(fn key, _, _ ->
        send(owner, {:reviewed, key})
        0.1
      end)

      plan([%{setting: "theme", value: "Tokyo Night"}])
      events = run("switch to tokyo night")

      refute_received {:reviewed, _}
      assert {:review_skipped, ["theme"]} in events
      assert done(events) =~ "theme: Solitude → Tokyo Night"
    end

    test "only the changes the request doesn't name are reviewed" do
      owner = self()

      Decider.Script.script(fn key, q, _ ->
        send(owner, {:reviewed, key, q.instructions})
        0.9
      end)

      plan([%{setting: "terminal_font_size", value: "14"}, %{setting: "theme", value: "Gruvbox"}])
      run("make the terminal font bigger")

      assert_received {:reviewed, :change_0, about}
      assert about =~ "theme → Gruvbox"
      refute_received {:reviewed, :change_1, _}
    end

    test "asking for what's already so says so, and hands nothing over" do
      plan([%{setting: "theme", value: "Solitude"}])
      events = run("switch to solitude")
      assert done(events) == "Already as asked: theme is Solitude."
      refute Enum.any?(events, &match?({:escalate, _}, &1))
    end

    test "a question about the current look changes nothing" do
      plan([], "You're on Solitude.")
      events = run("what theme am I using?")
      assert done(events) == "You're on Solitude."
      refute_received {:desktop, "omarchy", ["theme", "set", _]}
      assert Undo.load() == []
    end

    test "a doubtful review sends it back once; still doubtful, it waits for the user" do
      Decider.Script.script(fn _, _, _ -> 0.2 end)
      plan([%{setting: "theme", value: "Gruvbox"}])
      events = run("make the font bigger")

      assert_received {:asked, _, _}
      assert_received {:asked, retry, _}
      assert List.last(retry).content =~ "A reviewer checked the changes"
      refute_received {:desktop, "omarchy", ["theme", "set", _]}

      assert [plan] = for({:desktop_plan, p} <- events, do: p)
      assert plan.changes == [%{"setting" => "theme", "value" => "Gruvbox"}]
      assert done(events) =~ "waiting for your approval"

      # Approved: checked again against the settings now, then made.
      me = self()
      Desktop.execute(plan, &send(me, {:event, &1}))
      assert [text] = for({:desktop_done, t} <- events(), do: t)
      assert text =~ "theme: Solitude → Gruvbox"
      assert_received {:desktop, "omarchy", ["theme", "set", "Gruvbox"]}
    end

    test "when the local model can't, Haiku fills the same shape" do
      models = Application.get_env(:tiny_axe, :models, [])

      Application.put_env(
        :tiny_axe,
        :models,
        Keyword.merge(models,
          escalate: [{:claude, "claude-haiku-5-5"}],
          without_asking: [{:claude, "claude-haiku-5-5"}]
        )
      )

      :telemetry.execute([:tiny_axe, :model, :quota], %{}, %{
        backend: :claude,
        quota: %{status: "allowed", five_hour: 0.1, seven_day: 0.1}
      })

      plan([%{setting: "theme", value: "Dracula"}])
      events = run("use dracula", remote: :ask)

      assert [%{to: "Claude Haiku 5.5"}] = for({:escalate, e} <- events, do: e)
      assert {:answered_by, %{model: "Claude Haiku 5.5"}} in events
    end

    test "volume is a low-risk setting: set at once, read back, undoable" do
      plan([%{setting: "volume", value: "40"}])
      events = run("set the volume to 40")

      assert_received {:desktop, "wpctl", ["set-volume", "@DEFAULT_AUDIO_SINK@", "40%"]}
      assert done(events) =~ "volume: 65 → 40"
      assert [%{"changes" => [%{"setting" => "volume", "from" => "65"}]}] = Undo.load()
    end

    test "without a number, the volume moves a step, not to the top" do
      owner = self()
      tries = :counters.new(1, [])

      Model.Script.script(fn messages, _ ->
        :counters.add(tries, 1, 1)
        send(owner, {:asked, messages})
        value = if :counters.get(tries, 1) == 1, do: "100", else: "+10"
        JSON.encode!(%{changes: [%{setting: "volume", value: value}], reply: ""})
      end)

      events = run("louder")
      assert [[problem]] = for({:desktop_problems, p} <- events, do: p)
      assert problem =~ "change volume by at most 20 from 65"
      assert_received {:desktop, "wpctl", ["set-volume", "@DEFAULT_AUDIO_SINK@", "75%"]}
    end

    test "bluetooth always asks first, then runs once approved" do
      plan([%{setting: "bluetooth", value: "off"}])
      events = run("turn bluetooth off")

      refute_received {:desktop, "omarchy", ["bluetooth", "power", "off"]}
      assert [%{why: :risk} = plan] = for({:desktop_plan, p} <- events, do: p)
      assert done(events) =~ "these always ask first"

      me = self()
      Desktop.execute(plan, &send(me, {:event, &1}))
      assert_received {:desktop, "omarchy", ["bluetooth", "power", "off"]}
      assert [text] = for({:desktop_done, t} <- events(), do: t)
      assert text =~ "Done, after you approved"
    end

    test "actions run once, aren't recorded for undo, and apps open detached" do
      data =
        Path.join(System.tmp_dir!(), "tiny_axe_test_apps_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(data, "applications"))

      File.write!(
        Path.join(data, "applications/zz-fake-notes.desktop"),
        "[Desktop Entry]\nType=Application\nName=Fake Notes\nExec=true\n"
      )

      previous = System.get_env("XDG_DATA_HOME")
      System.put_env("XDG_DATA_HOME", data)

      on_exit(fn ->
        if previous,
          do: System.put_env("XDG_DATA_HOME", previous),
          else: System.delete_env("XDG_DATA_HOME")

        File.rm_rf(data)
      end)

      plan([
        %{setting: "launch_app", value: "fake notes"},
        %{setting: "reminder", value: "in 10 minutes: check the oven"}
      ])

      events = run("open fake notes and remind me in 10 minutes to check the oven")

      assert_received {:desktop, "setsid", ["-f", "uwsm-app", "--", "zz-fake-notes.desktop"]}
      assert_received {:desktop, "omarchy", ["reminder", "10", "check the oven"]}
      assert done(events) =~ "launch app: Fake Notes, done"
      assert Undo.load() == []
    end

    test "an app that isn't installed goes back with the closest names" do
      owner = self()
      tries = :counters.new(1, [])

      Model.Script.script(fn messages, _ ->
        :counters.add(tries, 1, 1)
        send(owner, {:asked, messages})

        JSON.encode!(%{
          changes: [%{setting: "launch_app", value: "Definitely Not An App"}],
          reply: ""
        })
      end)

      events = run("open definitely not an app")
      assert [[problem] | _] = for({:desktop_problems, p} <- events, do: p)
      assert problem =~ "isn't one of the installed names; the closest are:"
    end

    test "from the site's Chat tab nothing changes" do
      plan([%{setting: "theme", value: "Gruvbox"}])
      events = run("switch to gruvbox", origin: :site)

      assert done(events) =~ "only be made from tiny-axe on this computer"
      assert done(events) =~ "theme → Gruvbox"
      refute_received {:desktop, "omarchy", ["theme", "set", _]}
    end
  end
end
