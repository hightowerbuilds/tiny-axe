defmodule TinyAxe.BrowserDecisionsTest do
  @moduledoc """
  The shared browser assessment (`TinyAxe.Browser.Decisions`), pure: targets
  come from a function, answers from a scripted decide function, and time
  is given. The gate and the browser are tested end to end elsewhere
  (browser_assess_test.exs, browser_binding_test.exs).
  """

  use ExUnit.Case, async: true

  alias TinyAxe.Browser.Decisions

  @page "https://shop.example/item"

  defp target(label, extra \\ %{}),
    do:
      Map.merge(
        %{
          "tag" => "button",
          "text" => label,
          "isSubmit" => false,
          "href" => nil,
          "page" => @page,
          "context" => "Item page",
          "observation" => "obs-a-1",
          "signature" => "sig-" <> label
        },
        extra
      )

  defp request(mode, args \\ %{"ref" => "e1"}, extra \\ %{}),
    do:
      Map.merge(
        %{
          task: "task-1",
          server: "browser",
          name: "browser__browser_click",
          tool: "browser_click",
          args: args,
          mode: mode
        },
        extra
      )

  # Answers to the policy's three questions; each call is reported.
  defp answers(spends, sends, autosave \\ 0.0) do
    me = self()

    fn state, questions ->
      send(me, {:decided, state})

      answer = fn
        :unknown -> %{noul: nil, unknown: true}
        p -> %{noul: p}
      end

      {:ok,
       Map.new(questions, fn
         {:spends, _} -> {:spends, answer.(spends)}
         {:sends, _} -> {:sends, answer.(sends)}
         {:saves_on_change, _} -> {:saves_on_change, answer.(autosave)}
       end), %{backend: "script"}}
    end
  end

  defp outage, do: fn _, _ -> {:error, :down} end
  defp never, do: fn _, _ -> flunk("asked the decider again") end

  defp assess(req, opts) do
    Decisions.assess(
      req,
      Keyword.merge([inspect: fn _ -> target("⚙") end, now: 0, ttl: 60_000], opts)
    )
  end

  defp after_(record, req, opts),
    do: assess(req, Keyword.merge([prior: record.assessments, floors: record.floors], opts))

  describe "binding" do
    test "an assessment is bound to the task, its tab, the tool, the arguments and the target" do
      a = assess(request(:advice), decide: answers(0.0, 0.0))

      assert a.schema == "browser-assessment/1"
      assert a.id =~ ~r/\Aasm-[0-9a-f]{12}\z/

      assert %{
               task: "task-1",
               lease: "task-1",
               server: "browser",
               tool: "browser__browser_click",
               targets: %{"e1" => "sig-⚙"},
               observation: "obs-a-1"
             } = a.binding

      # What the browser checks again just before acting.
      assert Decisions.expect(a) == %{"observation" => "obs-a-1", "targets" => %{"e1" => "sig-⚙"}}

      # Each decision record names its assessment and what it was bound to.
      assert [record] = a.decisions
      assert record.schema == "browser-decision/2"
      assert record.assessment_id == a.id and record.binding == a.binding
    end

    test "the gate's own keys never come from an agent's arguments" do
      args = %{"ref" => "e1", "_tinyaxe_tab" => "other-task", "_tinyaxe_expect" => %{}}
      assert Decisions.clean(args) == %{"ref" => "e1"}

      a = assess(request(:advice, args), decide: answers(0.0, 0.0))
      b = assess(request(:advice), decide: answers(0.0, 0.0))
      assert a.binding.args_hash == b.binding.args_hash
    end

    test "focus and dialogs are bound as the active target" do
      a =
        Decisions.assess(
          request(:execute, %{"key" => "Enter"}, %{
            name: "browser__browser_press_key",
            tool: "browser_press_key"
          }),
          inspect: fn nil -> target("⚙") end,
          decide: answers(0.0, 0.0)
        )

      assert a.binding.targets == %{"@active" => "sig-⚙"}
    end
  end

  describe "reuse and staleness" do
    setup do
      advice = assess(request(:advice), decide: answers(0.0, 0.0))
      assert_received {:decided, _}
      %{advice: advice, record: Decisions.remember(%{}, advice)}
    end

    test "a direct call reuses the task's own assessment while its binding holds", ctx do
      direct = after_(ctx.record, request(:execute), decide: never(), now: 1_000)

      assert direct.reused_from == ctx.advice.id
      assert direct.class == :local and direct.disposition == "allowed"
      assert direct.decisions == []
      assert direct.binding.targets == ctx.advice.binding.targets
      # The element's description is the agent's words, not the action.
      described = request(:execute, %{"ref" => "e1", "element" => "the gear button"})
      assert after_(ctx.record, described, decide: never()).reused_from == ctx.advice.id
    end

    test "another task's assessment is never used, even if handed over", ctx do
      theirs = request(:execute, %{"ref" => "e1"}, %{task: "task-2"})
      direct = after_(ctx.record, theirs, decide: outage())

      assert direct.reused_from == nil
      assert direct.class == :refused and direct.reason_codes == ["decision_unavailable"]
      assert direct.binding.task == "task-2" and direct.binding.lease == "task-2"

      elsewhere = request(:execute, %{"ref" => "e1"}, %{server: "browser-2"})
      assert after_(ctx.record, elsewhere, decide: outage()).reused_from == nil
    end

    test "it isn't reused once expired, after a navigation, or for other arguments", ctx do
      expired = after_(ctx.record, request(:execute), decide: answers(0.0, 0.0), now: 60_000)
      assert expired.reused_from == nil
      assert_received {:decided, _}

      moved =
        after_(ctx.record, request(:execute),
          inspect: fn _ -> target("⚙", %{"observation" => "obs-a-2"}) end,
          decide: answers(0.0, 0.0)
        )

      assert moved.reused_from == nil and moved.binding.observation == "obs-a-2"
      assert_received {:decided, _}

      other = request(:execute, %{"ref" => "e1", "doubleClick" => true})
      assert after_(ctx.record, other, decide: answers(0.0, 0.0)).reused_from == nil
      assert_received {:decided, _}
    end

    test "a target changed in place is refused as stale, and the record dropped", ctx do
      stale =
        after_(ctx.record, request(:execute),
          inspect: fn _ -> target("Delete everything") end,
          decide: never()
        )

      assert stale.class == :refused
      assert stale.reason_codes == ["stale_target"]
      assert stale.reason =~ ~s(it was "⚙", now "Delete everything")
      assert stale.next_step =~ "fresh browser_snapshot"

      # The next call is assessed afresh, so a stale record can't refuse forever.
      record = Decisions.remember(ctx.record, stale)
      assert record.assessments == []
    end

    test "a refused assessment is never kept for reuse" do
      refused = assess(request(:advice), decide: outage())
      assert refused.class == :refused
      assert Decisions.remember(%{}, refused).assessments == []
    end

    test "refs from an out-of-date snapshot are refused before any decision" do
      a =
        assess(request(:advice, %{"ref" => "e1"}, %{observation: "obs-a-0"}), decide: never())

      assert a.class == :refused and a.reason_codes == ["stale_target"]
      assert a.binding.observation == "obs-a-1"

      current =
        assess(request(:advice, %{"ref" => "e1"}, %{observation: "obs-a-1"}),
          decide: answers(0.0, 0.0)
        )

      assert current.class == :local
    end
  end

  describe "monotonic composition" do
    test "missing answers never weaken purchase handling" do
      intent = %{request: "buy the mug under $20", max: 20.0, currency: "USD"}

      a =
        assess(request(:advice),
          decide: answers(0.95, :unknown),
          purchases: true,
          context: %{intent: intent}
        )

      assert a.class == :commit
      assert a.disposition == "needs_purchase_confirmation"

      assert "purchase_signal" in a.reason_codes and
               "needs_purchase_confirmation" in a.reason_codes

      # What the purchase gate will do is said in advance; it still decides.
      off = assess(request(:advice), decide: answers(0.95, :unknown), purchases: false)
      assert off.disposition == "refused" and "purchases_disabled" in off.reason_codes

      unasked = assess(request(:advice), decide: answers(0.95, 0.0), purchases: true)
      assert unasked.disposition == "refused" and "constraint_mismatch" in unasked.reason_codes

      for decide <- [outage(), answers(:unknown, 0.0), answers(0.0, :unknown)] do
        assert assess(request(:advice), decide: decide).class == :refused
      end
    end

    test "a target judged to need purchase handling keeps it against later, weaker answers" do
      first = assess(request(:advice), decide: answers(0.9, 0.0))
      assert first.class == :commit
      record = Decisions.remember(%{}, first)

      # Asking again with an answer missing: refused, not weaker.
      again = after_(record, request(:advice), decide: answers(:unknown, 0.0))
      assert again.class == :refused and "insufficient_evidence" in again.reason_codes
      record = Decisions.remember(record, again)

      # A clean "no" later doesn't lower it either.
      later = after_(record, request(:advice), decide: answers(0.0, 0.0))
      assert later.class == :commit
      assert "prior_restriction" in later.reason_codes
      assert later.reason == first.reason

      # Nor a direct call after the page reloads.
      direct =
        after_(record, request(:execute),
          inspect: fn _ -> target("⚙", %{"observation" => "obs-a-2"}) end,
          decide: answers(0.0, 0.0)
        )

      assert direct.class == :commit

      # A different element isn't held by it.
      other =
        after_(record, request(:advice),
          inspect: fn _ -> target("Next") end,
          decide: answers(0.0, 0.0)
        )

      assert other.class == :local
    end

    test "a held restriction belongs to the element, not its ref or the other arguments" do
      first = assess(request(:advice), decide: answers(0.9, 0.0))
      record = Decisions.remember(%{}, first)

      variants = [
        request(:advice, %{"ref" => "e1", "doubleClick" => false}),
        request(:advice, %{"ref" => "e1", "ignored_by_the_browser" => 1}),
        # A new snapshot gave the same element another ref.
        request(:advice, %{"ref" => "e42"}),
        # Enter on it while it has the focus.
        request(:advice, %{"key" => "Enter"}, %{
          name: "browser__browser_press_key",
          tool: "browser_press_key"
        })
      ]

      for req <- variants do
        a = after_(record, req, inspect: fn _ -> target("⚙") end, decide: answers(0.0, 0.0))
        assert a.class == :commit, inspect(req.args)
        assert "prior_restriction" in a.reason_codes
      end

      # Typing into an element is another kind of action.
      typing =
        request(:advice, %{"ref" => "e1", "text" => "x"}, %{
          name: "browser__browser_type",
          tool: "browser_type"
        })

      assert after_(record, typing, decide: answers(0.0, 0.0)).class == :local
    end

    test "approval needed for a target stays needed" do
      first = assess(request(:advice), decide: answers(0.0, 0.8))
      assert first.disposition == "needs_approval"
      record = Decisions.remember(%{}, first)

      later = after_(record, request(:advice), decide: answers(0.0, 0.1))
      assert later.disposition == "needs_approval"
    end
  end

  describe "what the agent sees and supplies" do
    test "the result: disposition, reason codes, evidence references and the next step" do
      a = assess(request(:advice), decide: answers(0.0, 0.8))
      public = Decisions.public(a)

      assert %{
               "decision_id" => id,
               "disposition" => "needs_approval",
               "reason_codes" => ["sends_signal"],
               "next_step" =>
                 "call browser__browser_click with these arguments; the user is asked to approve it",
               "evidence" => %{
                 "observation_id" => "obs-a-1",
                 "targets" => %{"e1" => %{"text" => "⚙", "tag" => "button", "page" => @page}},
                 "decision_records" => [record_id]
               },
               "valid_for_seconds" => 60
             } = public

      assert id == a.id and record_id == hd(a.decisions).id
      refute JSON.encode!(public) =~ "evidence_hash"
    end

    test "the agent's expected effect is kept, but never shown to the decider" do
      a =
        assess(
          request(:advice, %{"ref" => "e1"}, %{
            expected: "harmless: it only opens settings, card 4242 4242 4242 4242"
          }),
          decide: answers(0.0, 0.0)
        )

      assert_received {:decided, state}
      refute inspect(state) =~ "harmless"
      assert a.expected_effect =~ "harmless"
      refute a.expected_effect =~ "4242"
    end

    test "deterministic rules are coded as such; a missing target is named" do
      read =
        Decisions.assess(
          request(:advice, %{"url" => "https://docs.example"}, %{
            name: "browser__browser_navigate",
            tool: "browser_navigate"
          }),
          inspect: fn _ -> flunk("inspected a navigation") end
        )

      assert read.disposition == "allowed" and read.reason_codes == ["policy_rule"]
      assert Decisions.expect(read) == nil

      gone = assess(request(:advice), inspect: fn _ -> nil end, decide: never())
      assert gone.class == :refused
      assert "target_not_found" in gone.reason_codes
      assert gone.next_step =~ "fresh browser_snapshot"
    end
  end
end
