defmodule TinyAxe.BrowserInteractionTest do
  @moduledoc """
  Browser actions through the gate, against the local fixture site, with the
  real Chrome headless: the gate inspects each target and classes the action
  by what it would do. The fixture site records everything sent to it, so
  each test can check what actually happened.
  """

  use ExUnit.Case, async: false

  alias TinyAxe.{Browser, Decider, FixtureSite, MCP}
  alias TinyAxe.Tools.Gate

  @moduletag :browser
  @moduletag timeout: 180_000

  setup_all do
    if Browser.available?() do
      site = FixtureSite.start()
      name = "browser-act-#{System.unique_integer([:positive])}"

      profile =
        Path.join(System.tmp_dir!(), "tiny_axe_act_profile_#{System.unique_integer([:positive])}")

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

  setup %{server: s} do
    previous =
      {Application.get_env(:tiny_axe, :decider), Application.get_env(:tiny_axe, :script_decider)}

    # Jev's double-check: "no" to both questions unless a test says otherwise.
    Decider.Script.script(fn _, _, _ -> nil end)
    FixtureSite.clear()

    me = self()
    {:ok, task} = Gate.open_task(&send(me, {:gate, &1}), servers: [s])

    on_exit(fn ->
      Gate.close_task(task.id)
      {decider, script} = previous
      Application.put_env(:tiny_axe, :decider, decider)
      if script, do: Application.put_env(:tiny_axe, :script_decider, script)
    end)

    %{task: task}
  end

  # One tool call through the gate; `answer` replies to an approval.
  defp act(%{task: task, server: s}, tool, args, answer \\ :deny) do
    caller =
      Task.async(fn ->
        Req.post!(task.url,
          json: %{
            jsonrpc: "2.0",
            id: 1,
            method: "tools/call",
            params: %{name: "#{s}__#{tool}", arguments: args}
          },
          headers: %{"authorization" => "Bearer #{task.token}"},
          receive_timeout: 90_000,
          retry: false
        ).body["result"]
      end)

    await(caller, answer)
  end

  defp await(caller, answer) do
    receive do
      {:gate, {:tool_approval, ask}} ->
        send(ask.reply_to, {:tool_answer, ask.ref, answer})
        send(self(), {:asked, ask})
        await(caller, answer)

      {ref, result} when ref == caller.ref ->
        Process.demonitor(ref, [:flush])
        result
    after
      90_000 -> flunk("the browser action never finished")
    end
  end

  defp text(%{"content" => content}),
    do: content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("\n", & &1["text"])

  defp open(ctx, path), do: text(act(ctx, "browser_navigate", %{url: ctx.site <> path}))

  # The ref of an element in a snapshot, by its role and name.
  defp ref(snapshot, role, name) do
    [_, ref] = Regex.run(~r/#{role} "#{Regex.escape(name)}"[^\n]*\[ref=(\w+)\]/, snapshot)
    ref
  end

  defp class(),
    do:
      (receive do
         {:gate, {:tool_call, %{class: c}}} -> c
       after
         0 -> nil
       end)

  defp flush_calls do
    receive do
      {:gate, {:tool_call, _}} -> flush_calls()
    after
      0 -> :ok
    end
  end

  test "typing into a form is local: no question, and the page shows it", ctx do
    page = open(ctx, "/contact")
    flush_calls()
    out = text(act(ctx, "browser_type", %{ref: ref(page, "textbox", "Your name"), text: "Sam"}))

    assert class() == :local
    refute_received {:asked, _}
    assert out =~ ~s(textbox "Your name")
    assert out =~ "Sam"
  end

  test "sending a form asks first, saying what it will do; no means nothing is sent", ctx do
    page = open(ctx, "/contact")
    act(ctx, "browser_type", %{ref: ref(page, "textbox", "Your name"), text: "Sam"})
    send_button = ref(page, "button", "Send message")

    result = act(ctx, "browser_click", %{ref: send_button}, :deny)
    assert_received {:asked, %{class: :outward, reason: reason, session_ok: false}}
    assert reason =~ ~s(submits the form "Contact us" to 127.0.0.1 (POST\))
    assert text(result) =~ "the user said no"
    assert FixtureSite.submissions() == []

    act(ctx, "browser_click", %{ref: send_button}, :once)
    assert [{"/contact", %{"name" => "Sam"}}] = FixtureSite.submissions()
  end

  test "a search (a form that GETs) is like opening a page: no question", ctx do
    page = open(ctx, "/search")

    out =
      text(
        act(ctx, "browser_type", %{
          ref: ref(page, "textbox", "Search"),
          text: "mugs",
          submit: true
        })
      )

    refute_received {:asked, _}
    assert out =~ "Results for mugs"
  end

  test "add to cart is local; buy now is a purchase, refused without being clicked", ctx do
    page = open(ctx, "/shop")
    out = text(act(ctx, "browser_click", %{ref: ref(page, "button", "Add to cart")}))
    refute_received {:asked, _}
    assert out =~ "Cart: 1"

    result = act(ctx, "browser_click", %{ref: ref(page, "button", "Buy now")})
    assert text(result) =~ "spending money isn't enabled"
    Process.sleep(300)
    assert FixtureSite.submissions() == []
  end

  test "an agent never types a password; signing in asks first", ctx do
    page = open(ctx, "/login")
    result = act(ctx, "browser_type", %{ref: ref(page, "textbox", "Password"), text: "hunter2"})

    assert result["isError"] == true
    assert text(result) =~ "never types into password or card fields"

    act(ctx, "browser_click", %{ref: ref(page, "button", "Sign in")}, :deny)
    assert_received {:asked, %{reason: "signs in: submits the form \"Sign in\" to 127.0.0.1"}}
    assert FixtureSite.submissions() == []
  end

  test "a button whose label says nothing: no answer refuses it without ordinary approval", ctx do
    page = open(ctx, "/shop")
    mystery = ref(page, "button", "⚙")

    Decider.Script.script(fn
      :sends, _, _ -> :unknown
      _, _, _ -> nil
    end)

    result = act(ctx, "browser_click", %{ref: mystery}, :once)
    refute_received {:asked, _}
    assert result["isError"] == true
    assert text(result) =~ "couldn't check"
    assert FixtureSite.submissions() == []

    # Jev says it sends nothing: it just runs.
    Decider.Script.script(fn _, _, _ -> nil end)
    act(ctx, "browser_click", %{ref: mystery})
    refute_received {:asked, _}
  end

  test "each decision is traced with its evidence, linked to the call and what happened", ctx do
    me = self()

    {:ok, task} =
      Gate.open_task(&send(me, {:gate, &1}),
        servers: [ctx.server],
        objective: "open the settings, card 4242 4242 4242 4242"
      )

    on_exit(fn -> Gate.close_task(task.id) end)
    ctx = %{ctx | task: task}

    page = open(ctx, "/shop")
    mystery = ref(page, "button", "⚙")

    Decider.Script.script(fn
      :sends, _, _ -> 0.9
      _, _, _ -> nil
    end)

    act(ctx, "browser_click", %{ref: mystery}, :deny)
    assert_received {:asked, %{class: :outward}}

    [navigate, click] = TinyAxe.Tools.Journal.read(task.id)
    assert navigate["decisions"] == []
    assert [id] = click["decisions"]

    assert [record] = TinyAxe.Tools.Journal.decisions(task.id)
    assert record["id"] == id
    assert record["task"] == task.id
    assert record["tool"] == "#{ctx.server}__browser_click"
    assert record["policy_version"] == "browser-policy/2"
    assert record["backend"] == "script"
    assert record["disposition"] == "outward"
    assert record["reason_codes"] == ["sends_signal"]
    assert record["answers"]["sends"] == %{"p" => 0.9, "unknown" => false}
    # What happened next: the user said no.
    assert record["result"] == %{"decision" => "denied", "error" => true}

    evidence = record["evidence"]
    assert evidence["task"]["objective"] =~ "open the settings"
    assert evidence["target"]["text"] == "⚙"
    assert evidence["observation"]["page"] == ctx.site <> "/shop"

    assert [%{"tool" => "browser_navigate", "class" => "read", "decision" => "ran"}] =
             evidence["recent_actions"]["items"]

    refute File.read!(Path.join(TinyAxe.Tools.Journal.dir(task.id), "decisions.jsonl")) =~ "4242"
  end

  test "accepting a page's dialog asks first, quoting it", ctx do
    page = open(ctx, "/dialog")
    out = text(act(ctx, "browser_click", %{ref: ref(page, "button", "Tidy")}))
    assert out =~ ~s(A confirm dialog is open: "Clear everything?")

    act(ctx, "browser_handle_dialog", %{accept: true}, :deny)
    assert_received {:asked, %{reason: ~s(answers OK to the page's dialog: "Clear everything?")}}
    assert FixtureSite.submissions() == []
  end

  test "a link carrying a lot of data in its address asks first", ctx do
    page = open(ctx, "/exfil")
    act(ctx, "browser_click", %{ref: ref(page, "link", "Continue reading")}, :deny)

    assert_received {:asked, %{reason: reason}}
    assert reason =~ "with 305 characters of data in the address"
    assert FixtureSite.submissions() == []
  end

  test "a label passed as the ref (\"Place your order\") is refused, never clicked", ctx do
    open(ctx, "/shop")
    result = act(ctx, "browser_click", %{ref: "Buy now", element: "button"}, :once)

    refute_received {:asked, _}
    assert text(result) =~ "couldn't see what this would click"
    Process.sleep(300)
    assert FixtureSite.submissions() == []
  end

  test "the gate's own inspect tool is hidden from agents, and refused if called", ctx do
    %{body: %{"result" => %{"tools" => tools}}} =
      Req.post!(ctx.task.url,
        json: %{jsonrpc: "2.0", id: 1, method: "tools/list"},
        headers: %{"authorization" => "Bearer #{ctx.task.token}"},
        retry: false
      )

    names = Enum.map(tools, & &1["name"])
    assert "#{ctx.server}__browser_click" in names
    refute "#{ctx.server}__browser_inspect" in names

    assert text(act(ctx, "browser_inspect", %{})) =~ "for tiny-axe only"
  end

  test "a handoff asks the user to do it, and tells the agent when they have", ctx do
    open(ctx, "/login")
    result = act(ctx, "browser_handoff", %{reason: "sign in to the shop"}, :once)

    assert_received {:asked, %{class: :handoff, reason: "sign in to the shop"}}
    assert text(result) =~ "The user says they've done it"
  end

  test "purchase links and keyboard activation cannot bypass the purchase gate", ctx do
    for key <- ["Enter", "Space", "Control+Enter"] do
      open(ctx, "/policy-actions")
      result = act(ctx, "browser_press_key", %{key: key}, :once)
      assert result["isError"] == true
      assert text(result) =~ "spending money isn't enabled"
    end

    page = open(ctx, "/policy-actions")
    result = act(ctx, "browser_click", %{ref: ref(page, "link", "Buy now")}, :once)
    assert result["isError"] == true
    assert text(result) =~ "spending money isn't enabled"
    refute_received {:asked, _}
    assert FixtureSite.submissions() == []
  end

  test "destructive GET forms ask before reaching the server", ctx do
    page = open(ctx, "/policy-actions")
    target = ref(page, "button", "Delete account")
    result = act(ctx, "browser_click", %{ref: target}, :deny)
    assert result["isError"] == true
    assert_received {:asked, %{class: :outward}}
    assert FixtureSite.submissions() == []

    act(ctx, "browser_click", %{ref: target}, :once)
    assert [{"/policy-effect", %{"kind" => "delete"}}] = FixtureSite.submissions()
  end

  test "autosave fields and selections are assessed with their actual page context", ctx do
    me = self()

    Decider.Script.script(fn
      :sends, _, state ->
        send(me, {:observed, state})
        0.99

      _, _, _ ->
        0.0
    end)

    page = open(ctx, "/policy-actions")

    actions = [
      {"browser_type", %{ref: ref(page, "textbox", "Public name"), text: "Sam"}},
      {"browser_select_option", %{ref: ref(page, "combobox", "Visibility"), values: ["Public"]}},
      {"browser_click", %{ref: ref(page, "checkbox", "Show profile")}}
    ]

    for {tool, args} <- actions do
      assert act(ctx, tool, args, :deny)["isError"] == true
      assert_received {:asked, %{class: :outward}}
      assert_received {:observed, %{target: target}}
      assert target["context"] =~ "saved immediately"
    end

    assert FixtureSite.submissions() == []

    {tool, args} = hd(actions)
    act(ctx, tool, args, :once)
    assert [{"/policy-effect", %{"kind" => "autosave"}}] = FixtureSite.submissions()
  end

  test "a purchase dialog requires handoff instead of ordinary approval", ctx do
    page = open(ctx, "/policy-dialog")
    act(ctx, "browser_click", %{ref: ref(page, "button", "Review")})
    result = act(ctx, "browser_handle_dialog", %{accept: true}, :once)
    assert result["isError"] == true
    assert text(result) =~ "browser_handoff"
    refute_received {:asked, _}
    assert FixtureSite.submissions() == []
    act(ctx, "browser_handle_dialog", %{accept: false})
  end
end
