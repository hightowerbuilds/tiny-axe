defmodule TinyAxe.CommanderTest do
  use ExUnit.Case, async: false

  alias TinyAxe.{Commander, Decider, Location, Model}

  @moduletag :tmp_dir
  @keys ~w(model_backend decider script_model script_decider fs_root project_dir command_answer)a

  setup %{tmp_dir: dir} do
    previous = Map.new(@keys, &{&1, Application.get_env(:tiny_axe, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        if value == nil,
          do: Application.delete_env(:tiny_axe, key),
          else: Application.put_env(:tiny_axe, key, value)
      end

      Location.reset()
    end)

    app = Path.join(dir, "app")
    File.mkdir_p!(app)
    Application.put_env(:tiny_axe, :fs_root, dir)
    Application.put_env(:tiny_axe, :project_dir, app)
    Location.reset()
    Location.set(app)

    owner = self()

    Model.Script.script(fn messages, _opts ->
      send(owner, {:planned, messages})
      JSON.encode!(%{commands: ["touch approved-only"], reply: "Create the file."})
    end)

    %{app: app, home: dir}
  end

  defp events do
    receive do
      {:event, e} -> [e | events()]
    after
      0 -> []
    end
  end

  test "a weak review retries once with feedback, then offers the plan without running it", %{
    app: app
  } do
    Decider.Script.script(fn _, _, _ -> 0.2 end)
    Commander.run([], "create the file", &send(self(), {:event, &1}))

    assert_receive {:planned, _first}
    assert_receive {:planned, retried}
    assert List.last(retried).content =~ "A reviewer checked the commands"
    refute_receive {:planned, _}
    assert_receive {:event, {:command_plan, %{review: 0.2, dir: ^app}}}
    assert_receive {:event, {:done, _}}
    refute File.exists?(Path.join(app, "approved-only"))
  end

  test "one unknown review makes the overall score unknown without retrying" do
    Decider.Script.script(fn
      :right_folder, _, _ -> :unknown
      _, _, _ -> 0.9
    end)

    Commander.run([], "create the file", &send(self(), {:event, &1}))
    assert_receive {:planned, _}
    refute_receive {:planned, _}
    assert_receive {:event, {:decider_unavailable, "reviewing the commands"}}
    assert_receive {:event, {:command_plan, %{review: nil, commands: [%{review: 0.9}]}}}
  end

  test "an unavailable reviewer still offers an explicitly unreviewed plan" do
    Decider.Script.script(fn _, _, _ -> {:error, :unavailable} end)
    Commander.run([], "create the file", &send(self(), {:event, &1}))
    assert_receive {:planned, _}
    refute_receive {:planned, _}
    assert_receive {:event, {:decider_unavailable, "reviewing the commands"}}
    assert_receive {:event, {:command_plan, %{review: nil, commands: [%{review: nil}]}}}
  end

  describe "started in the home folder" do
    setup %{home: home} do
      Location.set(home)
      :ok
    end

    test "a plan that changes things is sent back to name a subfolder, then offered there", %{
      app: app
    } do
      me = self()

      Model.Script.script(fn messages, _opts ->
        send(me, {:planned, messages})

        dir =
          if List.last(messages).content =~ "can't run in the home folder itself",
            do: "app",
            else: ""

        JSON.encode!(%{commands: ["touch made"], dir: dir, reply: "Make the file."})
      end)

      Decider.Script.script(fn _, _, _ -> 0.9 end)
      Commander.run([], "make a file called made in my app", &send(me, {:event, &1}))

      assert_receive {:event, {:command_problems, [problem]}}
      assert problem =~ "Set \"dir\" to the subfolder"
      assert_receive {:event, {:command_plan, %{dir: ^app, read_only: false}}}
      assert_receive {:event, {:done, text}}
      assert text =~ "waiting for your approval, in ~/app"
      refute File.exists?(Path.join(app, "made"))
    end

    test "commands that only look run straight away, and the model answers from the output", %{
      home: home
    } do
      if TinyAxe.Shell.available?() do
        File.write!(Path.join(home, "notes.txt"), "hello")
        Application.put_env(:tiny_axe, :command_answer, true)
        me = self()

        Model.Script.script(fn messages, opts ->
          if opts[:format] do
            JSON.encode!(%{commands: ["ls"], dir: "", reply: "This lists the folder."})
          else
            send(me, {:answering, messages})
            "There's an app folder and notes.txt."
          end
        end)

        Decider.Script.script(fn key, _, _ ->
          send(me, {:decided, key})
          0.9
        end)

        Commander.run([], "what's in my home folder?", &send(me, {:event, &1}))
        events = events()

        assert {:command_plan, %{read_only: true, dir: ^home, review: nil}} =
                 List.keyfind(events, :command_plan, 0)

        assert {:cmd_exit, 0, 0} in events
        refute List.keyfind(events, :cmds_done, 0)
        # Nothing to approve, so no review.
        refute_received {:decided, _}

        assert_received {:answering, [%{role: "system"}, %{role: "user", content: shown}]}
        assert shown =~ "$ ls\n(exit 0)\n"
        assert shown =~ "notes.txt"

        {:done, text} = List.keyfind(events, :done, 0)

        assert text ==
                 "*Ran in ~, without asking (they only look): `ls` → exit 0.*\n\n" <>
                   "There's an app folder and notes.txt."

        # The answer goes after the output.
        assert Enum.find_index(events, &(&1 == {:attempt, 1})) >
                 Enum.find_index(events, &match?({:cmd_exit, _, _}, &1))

        # Later turns, and the verifier, see that it ran.
        history = [
          %{role: "user", content: "what's in my home folder?"},
          %{role: "assistant", content: text}
        ]

        assert TinyAxe.Pipeline.context(history, "thanks").commands_tiny_axe_ran ==
                 "Ran in ~, without asking (they only look): `ls` → exit 0."
      end
    end

    test "without the answer step, the output's tail is the answer", %{home: home} do
      if TinyAxe.Shell.available?() do
        File.write!(Path.join(home, "notes.txt"), "hello")

        Model.Script.script(fn _messages, _opts ->
          JSON.encode!(%{commands: ["cat notes.txt"], dir: "", reply: "Shows the notes."})
        end)

        Decider.Script.script(fn _, _, _ -> 0.9 end)
        Commander.run([], "show my notes", &send(self(), {:event, &1}))
        {:done, text} = List.keyfind(events(), :done, 0)
        assert text =~ "*Ran in ~, without asking (they only look): `cat notes.txt` → exit 0.*"
        assert text =~ "```console\n$ cat notes.txt\nhello\n```"
      end
    end
  end
end
