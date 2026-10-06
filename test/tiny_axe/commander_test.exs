defmodule TinyAxe.CommanderTest do
  use ExUnit.Case, async: false

  alias TinyAxe.{Commander, Decider, Location, Model}

  @moduletag :tmp_dir
  @keys ~w(model_backend decider script_model script_decider fs_root project_dir)a

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

    %{app: app}
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
end
