defmodule TinyAxe.BrowserOutcomeTest do
  @moduledoc """
  Outcome verification with the real Chrome headless and the fixture site's
  note form, which records each note when it arrives, then answers as the
  test says: confirmed, an error page, a 502, or not at all (a lost
  response). What reached the site is the independent record of each
  outcome; the agent's answer is checked against what tiny-axe could
  confirm (`TinyAxe.Tools.Gate.complete/2`, the step every driver's answer
  goes through).
  """

  use ExUnit.Case, async: false

  alias TinyAxe.{Browser, Decider, FixtureSite, MCP, Tools}
  alias TinyAxe.Tools.Gate

  @moduletag :browser
  @moduletag timeout: 180_000

  setup_all do
    if Browser.available?() do
      site = FixtureSite.start()
      name = "browser-outcome-#{System.unique_integer([:positive])}"

      profile =
        Path.join(
          System.tmp_dir!(),
          "tiny_axe_outcome_profile_#{System.unique_integer([:positive])}"
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

  @failure ~r/couldn't|may not have|bad gateway/i

  setup do
    previous =
      {Application.get_env(:tiny_axe, :decider), Application.get_env(:tiny_axe, :script_decider),
       Application.get_env(:tiny_axe, :tools)}

    # The decider reads the pages: a page showing the note, or saying it was
    # sent, shows the effect; one reporting a failure shows an error. Every
    # answer claims success.
    Decider.Script.script(fn
      key, _, state when key in [:took_effect, :claim_supported] ->
        text = pages(state)
        if text =~ ~r/note sent|hello/i and not (text =~ @failure), do: 0.9, else: 0.1

      :shows_error, _, state ->
        if pages(state) =~ @failure, do: 0.9, else: 0.0

      # A field the page says saves itself is judged to send.
      :saves_on_change, _, %{target: target} ->
        if (target["context"] || "") =~ "automatically", do: 0.9, else: 0.0

      :claim_1, _, _ ->
        0.9

      _, _, _ ->
        nil
    end)

    FixtureSite.clear()
    FixtureSite.set_outcome(:ok)
    # Every test sends the same note on the same browser: no hold carries over.
    Gate.clear_holds()

    on_exit(fn ->
      {decider, script, tools} = previous
      Application.put_env(:tiny_axe, :decider, decider)
      if script, do: Application.put_env(:tiny_axe, :script_decider, script)
      Application.put_env(:tiny_axe, :tools, tools || [])
    end)
  end

  defp pages(state),
    do: Enum.map_join([state[:after_action], state[:now]], "\n", &((&1 && &1[:text]) || ""))

  defp open(ctx) do
    me = self()

    {:ok, task} =
      Gate.open_task(&send(me, {:gate, &1}),
        servers: [ctx.server],
        objective: "send the note hello"
      )

    on_exit(fn -> Gate.close_task(task.id) end)
    task
  end

  # One call through the gate, approving whatever it asks.
  defp act(ctx, task, tool, args) do
    name = if tool == "browser_verify", do: tool, else: "#{ctx.server}__#{tool}"

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

    await(caller)
  end

  defp await(caller) do
    receive do
      {:gate, {:tool_approval, ask}} ->
        send(self(), {:asked, ask})
        # Doing again what may already have gone through: never, here.
        send(ask.reply_to, {:tool_answer, ask.ref, if(ask[:repeat], do: :deny, else: :once)})
        await(caller)

      {ref, result} when ref == caller.ref ->
        Process.demonitor(ref, [:flush])
        result
    after
      90_000 -> flunk("the call never finished")
    end
  end

  defp text(%{"content" => content}),
    do: content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("\n", & &1["text"])

  defp ref(snapshot, role, name) do
    [_, ref] = Regex.run(~r/#{role} "#{Regex.escape(name)}"[^\n]*\[ref=(\w+)\]/, snapshot)
    ref
  end

  # Opens the note form, types "hello there" (and a recipient, if given) and
  # clicks "Send note".
  defp send_note(ctx, task, to \\ nil) do
    page = text(act(ctx, task, "browser_navigate", %{url: ctx.site <> "/note"}))

    if to,
      do:
        refute(
          act(ctx, task, "browser_type", %{ref: ref(page, "textbox", "To"), text: to})["isError"]
        )

    typed =
      act(ctx, task, "browser_type", %{ref: ref(page, "textbox", "Note"), text: "hello there"})

    refute typed["isError"]
    act(ctx, task, "browser_click", %{ref: ref(page, "button", "Send note")})
  end

  # The note form opened again: the same button, by a fresh ref.
  defp send_again(ctx, task), do: send_note(ctx, task)

  defp notes, do: for({"/note", %{"note" => n}} <- FixtureSite.submissions(), do: n)

  defp actions(task), do: for(e <- Tools.Journal.read(task.id), e["action"], do: e["action"])

  test "a typed field is confirmed in code; a sent note is confirmed from the page", ctx do
    task = open(ctx)
    result = send_note(ctx, task)
    refute result["isError"]
    assert text(result) =~ "call browser_verify with this action_id"
    assert notes() == ["hello there"]

    [typed, sent] = actions(task)
    assert typed["status"] == "succeeded" and typed["codes"] == ["value_set"]
    assert sent["status"] == "pending"

    assert [%{"check" => "request", "result" => "pass", "detail" => "POST " <> _}] =
             sent["checks"]

    v = JSON.decode!(text(act(ctx, task, "browser_verify", %{action_id: sent["id"]})))
    assert v["status"] == "succeeded" and v["reason_codes"] == ["effect_observed"]

    assert Gate.complete(task.id, "I sent your note.") == "I sent your note."
  end

  test "the site saying it failed: failed, and an answer claiming success isn't delivered", ctx do
    FixtureSite.set_outcome(:refused)
    task = open(ctx)
    refute send_note(ctx, task)["isError"]

    # The site said it failed and the answer says it worked: contradicted.
    reply = Gate.complete(task.id, "Done! Your note was sent.")
    refute reply =~ "Done!"
    assert reply =~ ~s(✗ not done: click "Send note": the page said it failed)
    assert_received {:gate, {:completion, %{outcome: :replaced, failed: [~s(click "Send note")]}}}

    # Verified at completion: failed, not unresolved (the site said so), so
    # trying again is allowed.
    [completion] = for e <- Tools.Journal.read(task.id), e["completion"], do: e

    assert [%{"status" => "failed", "reason_codes" => ["error_shown"]}] =
             completion["verifications"]

    FixtureSite.set_outcome(:ok)
    refute send_again(ctx, task)["isError"]
    assert notes() == ["hello there", "hello there"]
  end

  test "a lost submit response: unresolved, the retry is refused, the note arrived once", ctx do
    # Longer than the browser waits for a click's navigation (10 s), and
    # than this test takes: the answer never comes while it runs.
    FixtureSite.set_outcome({:hang, 60_000})
    task = open(ctx)
    result = send_note(ctx, task)
    assert text(result) =~ "outcome_unresolved: response_lost"

    assert_received {:gate,
                     {:outcome,
                      %{status: :unresolved, codes: ["outcome_unresolved", "response_lost"]}}}

    assert notes() == ["hello there"]

    # Looking again while there's still no answer, on the same page view:
    # still unresolved.
    v = JSON.decode!(text(act(ctx, task, "browser_verify", %{})))
    assert v["status"] == "unresolved", inspect(v)

    # The answer stays, under a note: it never reads as confirmed.
    reply = Gate.complete(task.id, "Your note was sent.")
    assert reply =~ ~r/\A⚠ tiny-axe couldn't confirm all of this answer. Not confirmed:\n/
    assert reply =~ ~s(? click "Send note": the site's response was lost)
    assert String.ends_with?(reply, "\n\nYour note was sent.")

    # Asked again (a fresh ref to the same button): the user is asked
    # whether to do it again, says no, and nothing is sent.
    flush_asked()
    repeat = send_again(ctx, task)
    assert repeat["isError"] and text(repeat) =~ "may already have gone through"
    assert_received {:asked, %{repeat: true}}
    Process.sleep(300)
    assert notes() == ["hello there"]

    # The form page, loaded afresh on the way, lists the note: it did arrive.
    v = JSON.decode!(text(act(ctx, task, "browser_verify", %{})))
    assert v["status"] == "succeeded" and "content_shown" in v["reason_codes"]
  end

  test "a response that never comes in time: unresolved, never repeated", ctx do
    tools = Application.get_env(:tiny_axe, :tools, [])
    Application.put_env(:tiny_axe, :tools, Keyword.put(tools, :action_timeout, 1_500))
    FixtureSite.set_outcome({:hang, 20_000})
    task = open(ctx)

    result = send_note(ctx, task)
    assert result["isError"] and text(result) =~ "outcome_unresolved: response_lost"
    assert List.last(actions(task))["status"] == "unresolved"

    Application.put_env(:tiny_axe, :tools, tools)
    flush_asked()
    assert text(send_again(ctx, task)) =~ "may already have gone through"
    assert_received {:asked, %{repeat: true}}
    Process.sleep(300)
    assert notes() == ["hello there"]
  end

  test "a 502 after saving: unresolved until the page shows it; then confirmed", ctx do
    FixtureSite.set_outcome(:bad_gateway)
    task = open(ctx)
    result = send_note(ctx, task)
    assert text(result) =~ "outcome_unresolved: server_error"

    # Verifying on the error page can't confirm it.
    v =
      JSON.decode!(
        text(act(ctx, task, "browser_verify", %{claimed_outcome: "the note hello was saved"}))
      )

    assert v["status"] == "unresolved"
    assert text(send_again(ctx, task)) =~ "may already have gone through"

    # The page it was sent from, loaded again, shows the text that was sent:
    # code confirms it, no judgment needed.
    act(ctx, task, "browser_navigate", %{url: ctx.site <> "/note"})

    v =
      JSON.decode!(
        text(act(ctx, task, "browser_verify", %{claimed_outcome: "the note hello was saved"}))
      )

    assert v["status"] == "succeeded"
    assert v["reason_codes"] == ["content_shown", "server_error"]

    assert Gate.complete(task.id, "Your note was saved.") == "Your note was saved."
    assert notes() == ["hello there"]
  end

  test "a removal is confirmed in code: the row it acted on is gone", ctx do
    task = open(ctx)
    page = text(act(ctx, task, "browser_navigate", %{url: ctx.site <> "/rows"}))
    refute act(ctx, task, "browser_click", %{ref: ref(page, "button", "Remove")})["isError"]
    assert [%{"id" => "elm"}] = for({"/rows/remove", p} <- FixtureSite.submissions(), do: p)

    [removed] = actions(task)
    assert removed["status"] == "succeeded" and removed["codes"] == ["removed_from_page"]

    # Nothing to doubt: the answer goes as it is, without asking anyone.
    assert Gate.complete(task.id, "I removed the Elm St address.") ==
             "I removed the Elm St address."
  end

  test "an autosaving field is confirmed in code, also after the page is loaded again", ctx do
    task = open(ctx)
    page = text(act(ctx, task, "browser_navigate", %{url: ctx.site <> "/autosave"}))

    typed =
      act(ctx, task, "browser_type", %{
        ref: ref(page, "textbox", "Display name"),
        text: "Robin H."
      })

    refute typed["isError"]
    assert_received {:asked, _}
    [saved] = actions(task)
    id = saved["id"]

    # Loaded again: the field, read afresh, holds what the server kept.
    act(ctx, task, "browser_navigate", %{url: ctx.site <> "/autosave"})
    v = JSON.decode!(text(act(ctx, task, "browser_verify", %{action_id: id})))
    assert v["status"] == "succeeded" and v["reason_codes"] == ["value_saved"]

    {:ok, observed} =
      MCP.call(ctx.server, "browser_observe", Browser.bind(%{"action" => id}, task.id), 30_000)

    assert [%{"now" => true, "reread" => true}] = JSON.decode!(text(observed))["action"]["fields"]

    assert Gate.complete(task.id, "Your display name is now Robin H.") ==
             "Your display name is now Robin H."
  end

  test "after a lost send, only the sent text on the page it came from confirms it", ctx do
    FixtureSite.set_outcome(:bad_gateway)
    task = open(ctx)
    assert text(send_note(ctx, task, "alice@example.com")) =~ "outcome_unresolved: server_error"

    # Old mail elsewhere quoting the recipient and the very text: not evidence.
    act(ctx, task, "browser_navigate", %{url: ctx.site <> "/inbox"})
    v = JSON.decode!(text(act(ctx, task, "browser_verify", %{})))
    assert v["status"] == "unresolved", inspect(v)

    # The page it was sent from now lists "Sent to alice@example.com": the
    # recipient isn't the content, so that doesn't confirm it either.
    act(ctx, task, "browser_navigate", %{url: ctx.site <> "/note"})
    v = JSON.decode!(text(act(ctx, task, "browser_verify", %{})))
    assert v["status"] == "unresolved"
    assert text(send_again(ctx, task)) =~ "may already have gone through"
  end

  test "an optimistic echo of a lost post confirms nothing, wherever the agent looks next", ctx do
    task = open(ctx)
    page = text(act(ctx, task, "browser_navigate", %{url: ctx.site <> "/echo"}))
    note = %{ref: ref(page, "textbox", "Note"), text: "hello there, echoed"}
    refute act(ctx, task, "browser_type", note)["isError"]
    sent = act(ctx, task, "browser_click", %{ref: ref(page, "button", "Post")})
    assert text(sent) =~ "outcome_unresolved: server_error"
    assert text(sent) =~ "hello there, echoed"

    # Elsewhere, then back (from memory, not loaded afresh): nothing confirms.
    for move <- [
          fn -> act(ctx, task, "browser_navigate", %{url: ctx.site <> "/article"}) end,
          fn -> act(ctx, task, "browser_navigate_back", %{}) end
        ] do
      move.()
      v = JSON.decode!(text(act(ctx, task, "browser_verify", %{})))
      assert v["status"] == "unresolved", inspect(v)
    end

    # Loaded afresh, the page doesn't list it: still unresolved, still held.
    act(ctx, task, "browser_navigate", %{url: ctx.site <> "/echo"})
    assert JSON.decode!(text(act(ctx, task, "browser_verify", %{})))["status"] == "unresolved"
    page = text(act(ctx, task, "browser_snapshot", %{}))

    assert text(act(ctx, task, "browser_click", %{ref: ref(page, "button", "Post")})) =~
             "may already have gone through"

    assert for({"/echo", _} <- FixtureSite.submissions(), do: :posted) == [:posted]
  end

  test "an error toast outside the main region keeps it unresolved", ctx do
    task = open(ctx)
    page = text(act(ctx, task, "browser_navigate", %{url: ctx.site <> "/toast"}))
    comment = %{ref: ref(page, "textbox", "Comment"), text: "count me in please"}
    refute act(ctx, task, "browser_type", comment)["isError"]
    refute act(ctx, task, "browser_click", %{ref: ref(page, "button", "Post comment")})["isError"]

    # The comment shows in the main region, but the page also says it failed.
    v = JSON.decode!(text(act(ctx, task, "browser_verify", %{})))
    assert v["status"] == "unresolved", inspect(v)
  end

  test "a save carries a field's value only as a whole value, not inside a beacon's number",
       ctx do
    carried = fn path ->
      task = open(ctx)
      page = text(act(ctx, task, "browser_navigate", %{url: ctx.site <> path}))
      act(ctx, task, "browser_type", %{ref: ref(page, "textbox", "Display name"), text: "5"})
      [typed] = actions(task)
      Process.sleep(500)

      {:ok, seen} =
        MCP.call(
          ctx.server,
          "browser_observe",
          Browser.bind(%{"action" => typed["id"]}, task.id),
          30_000
        )

      for q <- JSON.decode!(text(seen))["action"]["requests"],
          q["method"] == "POST",
          do: q["carries_value"]
    end

    # A beacon saying {"event":"typing","seq":15}: "5" is only inside "15".
    assert carried.("/autosave?broken=1") == [false]
    # A save of {"name":"5"}: the whole value.
    assert carried.("/autosave") == [true]
  end

  test "a recipient showing up isn't the sent content: no confirmation from it", ctx do
    task = open(ctx)
    page = text(act(ctx, task, "browser_navigate", %{url: ctx.site <> "/invite"}))

    refute act(ctx, task, "browser_type", %{
             ref: ref(page, "textbox", "To"),
             text: "alice@example.com"
           })["isError"]

    assert text(act(ctx, task, "browser_click", %{ref: ref(page, "button", "Invite")})) =~
             "outcome_unresolved"

    # Loaded again, the page lists "Invited alice@example.com".
    assert text(act(ctx, task, "browser_navigate", %{url: ctx.site <> "/invite"})) =~
             "Invited alice@example.com"

    v = JSON.decode!(text(act(ctx, task, "browser_verify", %{})))
    assert v["status"] == "unresolved", inspect(v)
  end

  test "an autosave with no save behind it isn't confirmed, even when Chrome refills the field",
       ctx do
    task = open(ctx)
    page = text(act(ctx, task, "browser_navigate", %{url: ctx.site <> "/autosave?broken=1"}))

    typed =
      act(ctx, task, "browser_type", %{
        ref: ref(page, "textbox", "Display name"),
        text: "Robin H."
      })

    refute typed["isError"]
    [saved] = actions(task)

    # Away and back: the field shows what was typed, from Chrome's memory.
    act(ctx, task, "browser_navigate", %{url: ctx.site <> "/article"})
    act(ctx, task, "browser_navigate_back", %{})
    v = JSON.decode!(text(act(ctx, task, "browser_verify", %{action_id: saved["id"]})))
    assert v["status"] == "unresolved", inspect(v)
    assert for({"/autosave", _} <- FixtureSite.submissions(), do: :saved) == []
  end

  test "the browser forgets a task's actions, and what was typed, when the task ends", ctx do
    task = open(ctx)
    send_note(ctx, task)
    [_typed, sent] = actions(task)

    observe = fn ->
      MCP.call(
        ctx.server,
        "browser_observe",
        Browser.bind(%{"action" => sent["id"]}, task.id),
        30_000
      )
    end

    {:ok, before} = observe.()
    assert JSON.decode!(text(before))["action"]["id"] == sent["id"]

    Gate.close_task(task.id)
    {:ok, after_} = observe.()
    assert JSON.decode!(text(after_))["action"] == nil
  end

  defp flush_asked do
    receive do
      {:asked, _} -> flush_asked()
    after
      0 -> :ok
    end
  end
end
