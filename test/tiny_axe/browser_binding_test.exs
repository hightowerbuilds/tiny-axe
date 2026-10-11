defmodule TinyAxe.BrowserBindingTest do
  @moduledoc """
  Assessments bound to execution, with the real Chrome headless and the
  fixture site: observation ids in snapshots, the browser's own final check
  before acting, staleness that's scoped to the target, and each task's own
  tabs. The fixture site records what reaches it.
  """

  use ExUnit.Case, async: false

  alias TinyAxe.{Browser, Decider, FixtureSite, MCP, Tools}
  alias TinyAxe.Tools.Gate

  @moduletag :browser
  @moduletag timeout: 180_000

  setup_all do
    if Browser.available?() do
      site = FixtureSite.start()
      name = "browser-bind-#{System.unique_integer([:positive])}"

      profile =
        Path.join(
          System.tmp_dir!(),
          "tiny_axe_bind_profile_#{System.unique_integer([:positive])}"
        )

      {:ok, _} =
        MCP.start_server(name, Browser.config(profile: profile, headless: true, no_window: true))

      on_exit(fn ->
        MCP.stop_server(name)
        File.rm_rf(profile)
      end)

      %{site: site, server: name}
    else
      {:skip, "Node, Playwright or Chrome isn't available"}
    end
  end

  setup do
    previous =
      {Application.get_env(:tiny_axe, :decider), Application.get_env(:tiny_axe, :script_decider)}

    Decider.Script.script(fn _, _, _ -> nil end)
    FixtureSite.clear()
    FixtureSite.set_label("Send note")

    on_exit(fn ->
      {decider, script} = previous
      Application.put_env(:tiny_axe, :decider, decider)
      if script, do: Application.put_env(:tiny_axe, :script_decider, script)
    end)
  end

  defp open(ctx) do
    me = self()
    {:ok, task} = Gate.open_task(&send(me, {:gate, &1}), servers: [ctx.server])
    on_exit(fn -> Gate.close_task(task.id) end)
    task
  end

  # One call through the gate; `answer` replies to an approval, after
  # `meanwhile` runs (the page changing while the user decides).
  defp act(ctx, task, tool, args, answer \\ :deny, meanwhile \\ fn -> :ok end) do
    name = if tool == "browser_assess", do: tool, else: "#{ctx.server}__#{tool}"

    caller =
      Task.async(fn ->
        Req.post!(task.url,
          json: %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: name, arguments: args}
          },
          headers: %{"authorization" => "Bearer #{task.token}"},
          receive_timeout: 90_000,
          retry: false
        ).body["result"]
      end)

    await(caller, answer, meanwhile)
  end

  defp await(caller, answer, meanwhile) do
    receive do
      {:gate, {:tool_approval, ask}} ->
        send(self(), {:asked, ask})
        meanwhile.()
        send(ask.reply_to, {:tool_answer, ask.ref, answer})
        await(caller, answer, meanwhile)

      {ref, result} when ref == caller.ref ->
        Process.demonitor(ref, [:flush])
        result
    after
      90_000 -> flunk("the call never finished")
    end
  end

  defp text(%{"content" => content}),
    do: content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("\n", & &1["text"])

  defp open_page(ctx, task, path),
    do: text(act(ctx, task, "browser_navigate", %{url: ctx.site <> path}))

  defp ref(snapshot, role, name) do
    [_, ref] = Regex.run(~r/#{role} "#{Regex.escape(name)}"[^\n]*\[ref=(\w+)\]/, snapshot)
    ref
  end

  defp observation(snapshot) do
    [_, id] = Regex.run(~r/· observation (obs-[0-9a-f]+-\d+)/, snapshot)
    id
  end

  defp assess(ctx, task, args, extra \\ %{}) do
    result =
      act(
        ctx,
        task,
        "browser_assess",
        Map.merge(%{tool: "#{ctx.server}__browser_click", arguments: args}, extra)
      )

    JSON.decode!(text(result))
  end

  # Waits until the page's own polling shows the new label (without taking a
  # snapshot, which would hand out fresh refs).
  defp until_shown(ctx, task, label) do
    assert Enum.any?(1..40, fn _ ->
             Process.sleep(100)
             text(act(ctx, task, "browser_find", %{text: label})) =~ "- #{label}"
           end)
  end

  defp effects,
    do: for({"/bind-effect", params} <- FixtureSite.submissions(), do: params["label"])

  test "a snapshot names its observation; refs from an older one are refused before acting",
       ctx do
    task = open(ctx)
    first = open_page(ctx, task, "/bind")
    again = open_page(ctx, task, "/bind")
    assert observation(first) != observation(again)
    button = ref(again, "button", "Send note")

    old = assess(ctx, task, %{ref: button}, %{observation_id: observation(first)})
    assert old["disposition"] == "refused" and old["reason_codes"] == ["stale_target"]
    assert old["evidence"]["observation_id"] == observation(again)

    now = assess(ctx, task, %{ref: button}, %{observation_id: observation(again)})
    assert now["disposition"] == "needs_approval"
    assert effects() == []
  end

  test "a clock ticking beside the target doesn't make its assessment stale", ctx do
    task = open(ctx)
    page = open_page(ctx, task, "/bind")
    button = ref(page, "button", "Send note")

    %{"decision_id" => id, "disposition" => "needs_approval"} = assess(ctx, task, %{ref: button})
    Process.sleep(500)
    refute act(ctx, task, "browser_click", %{ref: button}, :once)["isError"]

    assert_received {:asked, %{reason: ~s(clicks "Send note") <> _}}
    assert List.last(Tools.Journal.read(task.id))["assessment"]["reused_from"] == id
    assert Enum.any?(1..20, fn _ -> Process.sleep(100) || effects() == ["Send note"] end)
  end

  test "a target that changed in place after it was assessed is refused; nothing is sent", ctx do
    task = open(ctx)
    page = open_page(ctx, task, "/bind")
    button = ref(page, "button", "Send note")
    assert assess(ctx, task, %{ref: button})["disposition"] == "needs_approval"

    FixtureSite.set_label("Delete everything")
    until_shown(ctx, task, "Delete everything")

    result = act(ctx, task, "browser_click", %{ref: button}, :once)
    assert result["isError"]
    assert text(result) =~ ~s(it was "Send note", now "Delete everything")
    refute_received {:asked, _}
    Process.sleep(300)
    assert effects() == []
  end

  test "a target that changes while the user decides isn't clicked", ctx do
    task = open(ctx)
    page = open_page(ctx, task, "/bind")
    button = ref(page, "button", "Send note")

    result =
      act(ctx, task, "browser_click", %{ref: button}, :once, fn ->
        FixtureSite.set_label("Delete everything")
        Process.sleep(1_000)
      end)

    assert_received {:asked, %{reason: ~s(clicks "Send note") <> _}}
    assert result["isError"]
    assert text(result) =~ "stale_target"
    Process.sleep(300)
    assert effects() == []
  end

  test "the browser itself checks the target just before acting", ctx do
    lease = "lease-#{System.unique_integer([:positive])}"
    call = fn tool, args -> MCP.call(ctx.server, tool, Browser.bind(args, lease), 60_000) end

    {:ok, page} = call.("browser_navigate", %{"url" => ctx.site <> "/bind"})
    button = ref(text(page), "button", "Send note")
    {:ok, inspected} = call.("browser_inspect", %{"ref" => button})
    %{"signature" => sig, "observation" => obs} = JSON.decode!(text(inspected))

    for expect <- [
          %{"observation" => obs, "targets" => %{button => "0000000000000000"}},
          %{"observation" => "obs-000000-0", "targets" => %{button => sig}}
        ] do
      {:ok, result} = call.("browser_click", Browser.bind(%{"ref" => button}, nil, expect))
      assert result["isError"] and text(result) =~ "stale_target: "
    end

    Process.sleep(300)
    assert effects() == []

    expect = %{"observation" => obs, "targets" => %{button => sig}}
    {:ok, result} = call.("browser_click", Browser.bind(%{"ref" => button}, nil, expect))
    refute result["isError"]
    assert Enum.any?(1..20, fn _ -> Process.sleep(100) || effects() == ["Send note"] end)
    call.("browser_release", %{})
  end

  test "a tab a task's page opens is that task's, even before its opener is known", ctx do
    # A browser that's slow to find a new tab's opener: the gap another
    # task could otherwise claim the tab in.
    name = "browser-popup-#{System.unique_integer([:positive])}"

    profile =
      Path.join(System.tmp_dir!(), "tiny_axe_popup_profile_#{System.unique_integer([:positive])}")

    config =
      Browser.config(profile: profile, headless: true, no_window: true)
      |> put_in(["env", "TINY_AXE_BROWSER_OPENER_DELAY_MS"], "2000")

    {:ok, _} = MCP.start_server(name, config)

    on_exit(fn ->
      MCP.stop_server(name)
      File.rm_rf(profile)
    end)

    ctx = %{ctx | server: name}
    a = open(ctx)
    page = open_page(ctx, a, "/popup")
    refute act(ctx, a, "browser_click", %{ref: ref(page, "link", "Open article")})["isError"]

    b = open(ctx)
    refute text(act(ctx, b, "browser_snapshot", %{})) =~ "/article"

    Process.sleep(2_500)
    tabs = text(act(ctx, a, "browser_tabs", %{action: "list"}))
    assert tabs =~ "/article" and tabs =~ "/popup"
    refute text(act(ctx, b, "browser_tabs", %{action: "list"})) =~ "/article"
  end

  test "each task works in its own tabs; the next task carries on where one left off", ctx do
    a = open(ctx)
    b = open(ctx)
    open_page(ctx, a, "/article")
    open_page(ctx, b, "/shop")

    assert text(act(ctx, a, "browser_snapshot", %{})) =~ "Page: #{ctx.site}/article"
    assert text(act(ctx, b, "browser_snapshot", %{})) =~ "Page: #{ctx.site}/shop"
    assert [only] = String.split(text(act(ctx, a, "browser_tabs", %{action: "list"})), "\n")
    assert only =~ "/article" and only =~ "* 0:"
    refute text(act(ctx, b, "browser_tabs", %{action: "list"})) =~ "/article"

    Gate.close_task(a.id)
    c = open(ctx)
    assert text(act(ctx, c, "browser_snapshot", %{})) =~ "Page: #{ctx.site}/article"
    assert text(act(ctx, b, "browser_snapshot", %{})) =~ "Page: #{ctx.site}/shop"
  end
end
