defmodule TinyAxe.RemoteApprovalsTest do
  @moduledoc """
  Approvals from the site's Chat tab (docs/plan-chrome-purchases.md, P3):
  the approval PIN (TinyAxe.Remote.Approvals) and the 🌐 chat sending what
  it asks to the Chat tab and acting on the answers. Not async: the PIN's
  file and keyring entry are shared.
  """
  use ExUnit.Case, async: false

  alias ExRatatui.Event
  alias TinyAxe.Remote.Approvals
  alias TinyAxe.TUI
  alias TinyAxe.TUI.Chats

  @size {110, 32}
  @pin "correct horse"

  setup do
    forget_pin()
    on_exit(&forget_pin/0)
  end

  defp forget_pin do
    File.rm(Approvals.path())
    tool = Application.get_env(:tiny_axe, :secret_tool)
    System.cmd(tool, ["clear", "service", "tiny-axe", "key", "remote-approval"])
    Approvals.discard_entry()
  end

  defp set_pin(pin \\ @pin) do
    Approvals.start_entry()
    for c <- String.graphemes(pin), do: Approvals.entry_key(c)
    :ok = Approvals.entry_next()
    for c <- String.graphemes(pin), do: Approvals.entry_key(c)
    Approvals.entry_finish()
  end

  defp saved, do: Approvals.path() |> File.read!() |> JSON.decode!()

  # What the page sends for an approval it was given.
  defp proof(approval, pin \\ @pin, total \\ ""),
    do:
      Approvals.proof_for(
        pin,
        approval.salt,
        approval.iterations,
        approval.id,
        approval.nonce,
        total
      )

  describe "the approval PIN" do
    test "none yet: approvals aren't ready and can't be switched on" do
      assert Approvals.status() == :no_pin
      assert Approvals.challenge() == {:error, :no_pin}
      assert {:error, "set an approval PIN first" <> _} = Approvals.set_enabled(true)
    end

    test "set twice at the machine; only a hash is kept, in the keyring" do
      assert :ok = set_pin()
      assert Approvals.status() == :ready

      file = File.read!(Approvals.path())
      refute file =~ @pin
      assert %{"enabled" => true, "failures" => 0, "iterations" => 1_000} = saved()

      tool = Application.get_env(:tiny_axe, :secret_tool)
      {hash, 0} = System.cmd(tool, ["lookup", "service", "tiny-axe", "key", "remote-approval"])
      assert String.trim(hash) =~ ~r/\A[0-9a-f]{64}\z/
      refute hash =~ @pin
    end

    test "too short, or two that don't match, aren't saved" do
      Approvals.start_entry()
      for c <- String.graphemes("12345"), do: Approvals.entry_key(c)
      assert {:error, "at least 6 characters"} = Approvals.entry_next()

      Approvals.start_entry()
      for c <- String.graphemes("123456"), do: Approvals.entry_key(c)
      :ok = Approvals.entry_next()
      for c <- String.graphemes("123457"), do: Approvals.entry_key(c)
      assert {:error, "the two didn't match"} = Approvals.entry_finish()
      assert Approvals.status() == :no_pin
    end

    test "a proof is good for its approval, its nonce and its total only" do
      :ok = set_pin()
      {:ok, c} = Approvals.challenge()
      a = Map.put(c, :id, "a1")

      assert :ok =
               Approvals.verify(%{
                 id: "a1",
                 nonce: c.nonce,
                 total: "16.00",
                 proof: proof(a, @pin, "16.00")
               })

      # The same proof for another total, another approval or another nonce.
      assert {:error, :wrong_pin, 2} =
               Approvals.verify(%{
                 id: "a1",
                 nonce: c.nonce,
                 total: "1.00",
                 proof: proof(a, @pin, "16.00")
               })

      assert {:error, :wrong_pin, 1} =
               Approvals.verify(%{
                 id: "a2",
                 nonce: c.nonce,
                 total: "16.00",
                 proof: proof(a, @pin, "16.00")
               })

      # A right one clears the count.
      assert :ok = Approvals.verify(%{id: "a1", nonce: c.nonce, total: "", proof: proof(a)})
      assert saved()["failures"] == 0
    end

    test "three wrong PINs lock approvals until they're switched on at the machine" do
      :ok = set_pin()
      {:ok, c} = Approvals.challenge()
      a = Map.put(c, :id, "a1")
      wrong = %{id: "a1", nonce: c.nonce, total: "", proof: proof(a, "wrong pin")}

      assert {:error, :wrong_pin, 2} = Approvals.verify(wrong)
      assert {:error, :wrong_pin, 1} = Approvals.verify(wrong)
      assert {:error, :wrong_pin, 0} = Approvals.verify(wrong)
      assert Approvals.status() == :locked
      # Even the right PIN does nothing now.
      assert {:error, :locked} = Approvals.verify(%{wrong | proof: proof(a)})

      assert :ok = Approvals.set_enabled(true)
      assert Approvals.status() == :ready
      assert :ok = Approvals.set_enabled(false)
      assert Approvals.status() == :off
      assert {:error, :off} = Approvals.challenge()
    end
  end

  ## The TUI

  defp mount do
    {:ok, state} = TUI.mount(test_mode: @size, remote: self())
    state
  end

  defp info(state, msg) do
    case TUI.handle_info(msg, state) do
      {:noreply, state} -> state
      {:noreply, state, _opts} -> state
    end
  end

  defp key(state, code) do
    {:noreply, state} =
      TUI.handle_event(%Event.Key{code: code, kind: "press", modifiers: []}, state)

    state
  end

  defp type(state, text) do
    ExRatatui.textarea_set_value(state.input, text)
    key(state, "enter")
  end

  defp remote(state),
    do: Chats.get(state, Enum.find(state.chats.order, &Chats.get(state, &1).remote_chat))

  defp metas(chat), do: for({:meta, text} <- chat.transcript, do: text)

  # A 🌐 message whose run the test plays itself.
  defp started do
    state = info(mount(), {:remote, {:message, %{id: "m1", body: "do it", created_at: "now"}}})
    {id, pid} = remote(state).run
    Process.exit(pid, :kill)
    {state, id}
  end

  defp events(state, id, events), do: Enum.reduce(events, state, &info(&2, {:pipeline, id, &1}))

  defp ask(extra) do
    ref = make_ref()
    {Map.merge(%{reply_to: self(), ref: ref}, extra), ref}
  end

  # The card goes to the site; the site gives it an id.
  defp opened(state, id) do
    assert_received {:remote_out, {:open_approval, ref, params}}
    state = info(state, {:remote, {:approval_opened, ref, %{"id" => id}}})
    {state, Map.put(params, :id, id)}
  end

  defp answered(state, approval, answer),
    do:
      info(
        state,
        {:remote,
         {:approval_answer, approval.id,
          %{"id" => approval.id, "status" => "answered", "answer" => answer}}}
      )

  defp approve(approval, pin \\ @pin, total \\ ""),
    do: %{"decision" => "approve", "proof" => proof(approval, pin, total), "total" => total}

  @purchase %{
    "host" => "shop.example",
    "total" => 16.0,
    "total_text" => "$16.00",
    "currency" => "USD",
    "items" => ["Blue mug × 1"],
    "paying_with" => "Mastercard ending in 5555"
  }

  test "with a PIN, a tool call goes to the Chat tab; the right PIN says yes, once" do
    :ok = set_pin()
    {state, id} = started()

    {tool, ref} =
      ask(%{
        tool: "github__create_issue",
        server: "github",
        class: :outward,
        args: %{"title" => "bug"}
      })

    state = events(state, id, [{:tool_approval, tool}])

    # Off the machine's popups, waiting on the site.
    assert state.tool_ask == nil
    {state, approval} = opened(state, "a1")
    assert approval.kind == "tool"
    assert approval.message_id == "m1"
    assert approval.body.title == "Use github__create_issue (github)"
    assert "title: bug" in approval.body.lines
    assert approval.expires_in == 540
    assert_received {:remote_out, {:progress, "m1", "waiting for your yes on the Chat tab"}}
    refute_received {:tool_answer, ^ref, _}

    state = answered(state, approval, approve(approval))
    assert_received {:tool_answer, ^ref, :once}
    assert_received {:remote_out, {:close_approval, "a1", "approved"}}
    assert "🔒 approved on the Chat tab: Use github__create_issue (github)" in metas(remote(state))
    assert state.remote_link.approvals == %{}
  end

  test "a purchase needs the right PIN and the exact total" do
    :ok = set_pin()
    {state, id} = started()
    {buy, ref} = ask(%{summary: @purchase, checks: [{:ok, "within your maximum of $20.00"}]})
    state = events(state, id, [{:purchase_approval, buy}])
    {state, approval} = opened(state, "a1")

    assert approval.kind == "purchase"
    assert approval.body.total == "16.00"
    assert approval.body.title == "Buy at shop.example for $16.00 USD"
    assert [%{ok: true, text: "within your maximum of $20.00"}] = approval.body.checks

    # The right PIN for a wrong total: not bought, and it's not a wrong PIN.
    state = answered(state, approval, approve(approval, @pin, "1.60"))
    assert_received {:purchase_answer, ^ref, :deny}
    assert_received {:remote_out, {:close_approval, "a1", "refused"}}
    assert Enum.any?(metas(remote(state)), &(&1 =~ "the total typed (1.60) isn't 16.00"))
    assert Approvals.status() == :ready

    {buy, ref} = ask(%{summary: @purchase, checks: []})
    state = events(state, id, [{:purchase_approval, buy}])
    {state, approval} = opened(state, "a2")
    _state = answered(state, approval, approve(approval, @pin, "16.00"))
    assert_received {:purchase_answer, ^ref, :confirm}
    assert_received {:remote_out, {:close_approval, "a2", "approved"}}
  end

  test "deny on the Chat tab is a no" do
    :ok = set_pin()
    {state, id} = started()
    {claude, ref} = ask(%{to: "Claude Haiku", reason: "the local model fell short"})
    state = events(state, id, [{:ask_remote, claude}])
    {state, approval} = opened(state, "a1")
    assert approval.kind == "model"
    assert approval.body.title == "Send this request to Claude Haiku"

    state = answered(state, approval, %{"decision" => "deny"})
    assert_received {:remote_answer, ^ref, false}
    assert_received {:remote_out, {:close_approval, "a1", "denied"}}
    assert Enum.any?(metas(remote(state)), &(&1 =~ "you said no on the Chat tab"))
  end

  test "three wrong PINs: each is a no, then approvals are off and the rest are refused" do
    :ok = set_pin()
    {state, id} = started()

    asks = for n <- 1..4, do: ask(%{tool: "t#{n}", class: :outward, args: %{}})
    state = events(state, id, Enum.map(asks, fn {a, _} -> {:tool_approval, a} end))

    {state, approvals} =
      Enum.reduce(1..4, {state, []}, fn n, {s, acc} ->
        {s, a} = opened(s, "a#{n}")
        {s, acc ++ [a]}
      end)

    [a1, a2, a3, _a4] = approvals
    [{_, r1}, {_, r2}, {_, r3}, {_, r4}] = asks

    state = answered(state, a1, approve(a1, "wrong pin"))
    assert_received {:tool_answer, ^r1, :deny}
    state = answered(state, a2, approve(a2, "wrong pin"))
    assert_received {:tool_answer, ^r2, :deny}
    state = answered(state, a3, approve(a3, "wrong pin"))
    assert_received {:tool_answer, ^r3, :deny}
    assert_received {:remote_out, {:close_approval, "a3", "wrong_pin"}}

    # The fourth is withdrawn without an answer.
    assert_received {:tool_answer, ^r4, :deny}
    assert_received {:remote_out, {:close_approval, "a4", "refused"}}
    assert Approvals.status() == :locked
    assert state.remote_link.approvals == %{}
    assert Enum.any?(metas(remote(state)), &(&1 =~ "off after 3 wrong PINs"))
  end

  test "never from the site: OS changes, a card's PIN, your turn in the browser" do
    :ok = set_pin()
    {state, id} = started()

    {os, os_ref} =
      ask(%{
        tool: "os_run",
        class: :outward,
        args: %{},
        shell: %{command: "rm x", dir: "~", unsandboxed: true}
      })

    {pin_buy, pin_ref} = ask(%{summary: @purchase, checks: [], needs: [:pin]})
    {handoff, handoff_ref} = ask(%{tool: "browser_handoff", class: :handoff, args: %{}})

    state =
      events(state, id, [
        {:tool_approval, os},
        {:purchase_approval, pin_buy},
        {:tool_approval, handoff}
      ])

    assert_received {:tool_answer, ^os_ref, :deny}
    assert_received {:purchase_answer, ^pin_ref, :deny}
    assert_received {:tool_answer, ^handoff_ref, :deny}
    refute_received {:remote_out, {:open_approval, _, _}}

    lines = metas(remote(state))
    assert Enum.any?(lines, &(&1 =~ "desktop and OS changes are never approved from the site"))
    assert Enum.any?(lines, &(&1 =~ "a card's PIN or CVC is typed at the machine"))
    assert Enum.any?(lines, &(&1 =~ "it needs you in the browser at the machine"))
  end

  test "no PIN yet: refused, and the reply says how to set one" do
    {state, id} = started()
    {tool, ref} = ask(%{tool: "github__create_issue", class: :outward, args: %{}})
    state = events(state, id, [{:tool_approval, tool}])
    assert_received {:tool_answer, ^ref, :deny}
    refute_received {:remote_out, {:open_approval, _, _}}
    assert Enum.any?(metas(remote(state)), &(&1 =~ "no approval PIN yet (/remote pin sets one)"))
  end

  test "sandboxed commands go to the Chat tab; desktop changes don't" do
    :ok = set_pin()
    {state, id} = started()
    dir = System.tmp_dir!()
    plan = %{commands: [%{command: "echo hi"}], read_only: false, dir: dir, check: nil}
    state = events(state, id, [{:command_plan, plan}])

    {state, approval} = opened(state, "a1")
    assert approval.kind == "command"
    assert "$ echo hi" in approval.body.lines
    # Still waiting in the chat, asked once.
    assert remote(state).pending_commands == plan
    state = info(state, {:remote, {:status, :online}})
    refute_received {:remote_out, {:open_approval, _, _}}

    state = answered(state, approval, %{"decision" => "deny"})
    assert remote(state).pending_commands == nil
    assert "commands cancelled; nothing ran" in metas(remote(state))

    desktop = %{kind: :desktop, changes: [], commands: [], dir: dir}
    state = events(state, id, [{:desktop_plan, desktop}])
    refute_received {:remote_out, {:open_approval, _, _}}
    assert remote(state).pending_commands == nil
    assert Enum.any?(metas(remote(state)), &(&1 =~ "desktop changes are made at the machine"))
  end

  test "nobody answers in time: a no; the message ending withdraws what's still open" do
    :ok = set_pin()
    {state, id} = started()
    {t1, r1} = ask(%{tool: "t1", class: :outward, args: %{}})
    {t2, r2} = ask(%{tool: "t2", class: :outward, args: %{}})
    state = events(state, id, [{:tool_approval, t1}])
    {state, _a1} = opened(state, "a1")

    # The card's time runs out.
    [{ref, entry}] = Map.to_list(state.remote_link.approvals)

    link = %{
      state.remote_link
      | approvals: %{ref => %{entry | until: System.monotonic_time(:millisecond) - 1}}
    }

    state = info(%{state | remote_link: link}, {:remote, {:status, :online}})
    assert_received {:tool_answer, ^r1, :deny}
    assert_received {:remote_out, {:close_approval, "a1", "expired"}}

    state = events(state, id, [{:tool_approval, t2}])
    {state, _a2} = opened(state, "a2")
    _state = events(state, id, [{:done, "Gave up."}])
    assert_received {:tool_answer, ^r2, :deny}
    assert_received {:remote_out, {:close_approval, "a2", "withdrawn"}}
    assert_received {:remote_out, {:reply, "m1", "answered", body}}
    assert body =~ "nobody approved it on the Chat tab in time"
  end

  test "an answer for an approval tiny-axe doesn't have does nothing" do
    :ok = set_pin()
    {state, _id} = started()
    fake = %{id: "nope", nonce: "x", salt: "y", iterations: 1_000}
    state = answered(state, fake, approve(fake))
    refute_received {:tool_answer, _, _}
    assert state.remote_link.approvals == %{}
  end

  test "/remote pin: typed into Approvals; the TUI only knows how many characters" do
    state = type(mount(), "/remote pin")
    assert state.pin_flow.step == :first

    state = Enum.reduce(String.graphemes(@pin), state, &key(&2, &1))
    assert state.pin_flow.length == String.length(@pin)
    refute inspect(state) =~ @pin

    state = key(state, "enter")
    assert state.pin_flow.step == :again
    state = Enum.reduce(String.graphemes(@pin), state, &key(&2, &1)) |> key("enter")

    assert state.pin_flow == nil
    assert {:meta, "🔐 approval PIN set" <> _} = List.last(state.transcript)
    assert Approvals.status() == :ready

    state = type(state, "/remote approvals off")

    assert {:meta, "🔐 approvals from the Chat tab: off (/remote approvals on)"} =
             List.last(state.transcript)

    state = type(state, "/remote approvals on")
    assert {:meta, "🔐 approvals from the Chat tab: on" <> _} = List.last(state.transcript)
  end
end
