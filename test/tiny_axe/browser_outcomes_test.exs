defmodule TinyAxe.BrowserOutcomesTest do
  @moduledoc """
  What browser actions came to (`TinyAxe.Browser.Outcomes`, through
  `TinyAxe.Browser.Decisions`), pure: the browser's reports and fresh
  observations are given, answers come from scripted decide functions. The
  gate, the drivers and the real browser are tested in
  browser_verify_test.exs and browser_outcome_test.exs.
  """

  use ExUnit.Case, async: true

  alias TinyAxe.Browser.Decisions

  @page "https://shop.example/notes"

  defp target(label, extra),
    do:
      Map.merge(
        %{
          "tag" => "button",
          "text" => label,
          "isSubmit" => true,
          "page" => @page,
          "context" => "Write a note",
          "observation" => "obs-a-1",
          "signature" => "sig-" <> label,
          "form" => %{"action" => @page <> "/send", "method" => "post", "label" => "Write a note"}
        },
        extra
      )

  defp assess(opts) do
    label = Keyword.get(opts, :label, "Send note")
    tool = Keyword.get(opts, :tool, "browser_click")

    Decisions.assess(
      %{
        task: "task-1",
        server: "browser",
        name: "browser__" <> tool,
        tool: tool,
        args: Keyword.get(opts, :args, %{"ref" => "e1"}),
        mode: Keyword.get(opts, :mode, :execute)
      },
      inspect: fn _ -> target(label, Keyword.get(opts, :meta, %{})) end,
      # Fields are judged; "no" to everything keeps them local.
      decide: fn _, q ->
        {:ok, Map.new(q, fn {k, _} -> {k, %{noul: 0.0}} end), %{backend: "script"}}
      end,
      unresolved: Keyword.get(opts, :unresolved, MapSet.new()),
      purchases: true,
      context: %{intent: %{max: 50.0}},
      now: 0
    )
  end

  defp request(status, extra \\ %{}),
    do:
      Map.merge(
        %{
          "method" => "POST",
          "url" => @page <> "/send",
          "type" => "document",
          "status" => status,
          "failed" => nil,
          "pending" => status == nil
        },
        extra
      )

  defp report(extra),
    do:
      Map.merge(
        %{
          "id" => "act-1",
          "error" => nil,
          "url_before" => @page,
          "url_after" => @page,
          "observation_before" => "obs-a-1",
          "observation_after" => "obs-a-1",
          "requests" => [],
          "fields" => [],
          "after" => %{"url" => @page, "title" => "Notes", "text" => "Write a note"}
        },
        extra
      )

  defp record(execution, opts \\ []) do
    a = assess(opts)

    Decisions.record(a, %{
      decision: Keyword.get(opts, :decision, :approved),
      browser_tool: a.binding.tool |> String.replace_prefix("browser__", ""),
      args: Keyword.get(opts, :args, %{"ref" => "e1"}),
      execution: execution,
      receipt: Keyword.get(opts, :receipt),
      error_result: Keyword.get(opts, :error_result, false)
    })
  end

  defp page(text), do: {:ok, %{"now" => %{"url" => @page, "title" => "Notes", "text" => text}}}

  # Answers to the verification questions; each call reports what it was
  # shown. `claims` answers the completion check's per-action questions, in
  # order (or one answer for all).
  defp answers(took, error, contradicts \\ nil, claims \\ nil) do
    me = self()

    fn state, questions ->
      send(me, {:shown, state, Enum.sort(Map.keys(questions))})

      {:ok,
       Map.new(questions, fn
         {:took_effect, _} -> {:took_effect, %{noul: took}}
         {:shows_error, _} -> {:shows_error, %{noul: error}}
         {:contradicts_claim, _} -> {:contradicts_claim, %{noul: contradicts}}
         {key, _} -> {key, %{noul: claim(claims, key)}}
       end), %{backend: "script"}}
    end
  end

  defp claim(list, key) when is_list(list),
    do: Enum.at(list, String.to_integer(String.replace_prefix(to_string(key), "claim_", "")) - 1)

  defp claim(p, _key), do: p

  defp failed(r), do: %{r | status: :failed, codes: ["error_shown"]}

  # A fresh look at the page: its text, how often the typed text shows on it
  # (nil: another page), and its observation id (obs-a-1 is the action's own).
  # obs-a-1 is the page view right after the action; any other stands for a
  # whole new document loaded since (the browser's `fresh_load`).
  defp shown(text, count, observation) do
    {:ok,
     %{
       "now" => %{"url" => @page, "text" => text, "observation" => observation},
       "action" =>
         report(%{
           "requests" => [request(502)],
           "fresh_load" => observation != "obs-a-1",
           "content" => %{"values" => 1, "before" => [0], "after" => [nil], "now" => [count]}
         })
     }}
  end

  defp never, do: fn _, _ -> flunk("asked the decider") end

  describe "straight after an action" do
    test "a response that's lost, late or a server error leaves a sent action unresolved" do
      for {ex, code} <- [
            {report(%{"requests" => [request(nil)]}), "response_lost"},
            {report(%{
               "requests" => [request(nil, %{"failed" => "net::ERR_ABORTED", "pending" => false})]
             }), "response_lost"},
            {report(%{"requests" => [request(502)]}), "server_error"}
          ] do
        r = record(ex)
        assert r.status == :unresolved and r.codes == ["outcome_unresolved", code]
        assert r.submission
        assert Decisions.note(r) =~ "Don't repeat it"
      end

      # No answer from the browser at all (it timed out): it may have clicked.
      r = record(nil, decision: :failed)
      assert r.status == :unresolved and "response_lost" in r.codes
    end

    test "what never ran, or was rejected, failed; a sent action awaits verification" do
      assert record(nil, decision: :denied).codes == ["not_executed"]
      assert record(nil, decision: :refused).status == :failed

      # The browser refused before acting: no record of its own.
      assert record(nil, error_result: true).codes == ["not_executed"]

      # It failed before anything happened on the page.
      assert record(report(%{"error" => "element not visible"})).codes == ["not_executed"]

      assert record(report(%{"requests" => [request(400)]})).codes == ["request_rejected"]

      r = record(report(%{"requests" => [request(200)]}))
      assert r.status == :pending and r.submission
      assert Decisions.note(r) =~ "call browser_verify with this action_id"
    end

    test "an edit is confirmed in code by the field holding what was typed" do
      ok =
        record(report(%{"fields" => [%{"after" => true, "now" => true}]}),
          tool: "browser_type",
          args: %{"ref" => "e1", "text" => "hi"},
          meta: %{"tag" => "textarea", "isSubmit" => false, "text" => "Note"},
          label: "Note"
        )

      assert ok.status == :succeeded and ok.codes == ["value_set"]

      bad =
        record(report(%{"fields" => [%{"after" => false, "now" => false}]}),
          tool: "browser_type",
          args: %{"ref" => "e1", "text" => "hi"},
          meta: %{"tag" => "textarea", "isSubmit" => false, "text" => "Note"},
          label: "Note"
        )

      assert bad.status == :failed and bad.codes == ["value_mismatch"]
    end

    test "a click that only opened a dialog sends nothing yet" do
      r = record(report(%{"after" => %{"url" => @page, "dialog" => "Remove Sam?", "text" => ""}}))
      refute r.submission
      assert r.status == :pending
    end
  end

  describe "repeating an unresolved action" do
    test "the same kind of action on its target or form is refused, whatever else is said" do
      held = Decisions.unresolved_keys([record(report(%{"requests" => [request(nil)]}))])

      for mode <- [:execute, :advice] do
        a = assess(mode: mode, unresolved: held)
        assert a.disposition == "refused" and "outcome_unresolved" in a.reason_codes
        assert a.next_step =~ "don't repeat it"
      end

      # The same form, by another button: refused too.
      other = assess(label: "Send it", unresolved: held)
      assert "outcome_unresolved" in other.reason_codes

      # Editing a field is another kind of action, on another target.
      edit =
        assess(
          tool: "browser_type",
          args: %{"ref" => "e2", "text" => "again"},
          label: "Note",
          meta: %{"tag" => "textarea", "isSubmit" => false},
          unresolved: held
        )

      refute "outcome_unresolved" in edit.reason_codes

      # Confirmed either way, it no longer holds.
      assert Decisions.unresolved_keys([record(report(%{"requests" => [request(200)]}))]) ==
               MapSet.new()
    end
  end

  describe "holding a formless button" do
    # A button with no form (its script sends), on a page with a query.
    defp formless(label, query, opts \\ []) do
      Keyword.merge(
        [
          label: label,
          meta: %{
            "form" => nil,
            "isSubmit" => false,
            "page" => @page <> query,
            # As the browser's: the full address is part of it.
            "signature" => "sig-#{label}#{query}"
          }
        ],
        opts
      )
    end

    test "the same label on the same page, whatever the query, is held" do
      lost = record(report(%{"requests" => [request(nil)]}), formless("Send", "?draft=a"))
      held = Decisions.unresolved_keys([lost])

      # The signature differs (its address has another query), the label key doesn't.
      again = assess(formless("Send", "?draft=b", unresolved: held))
      assert "outcome_unresolved" in again.reason_codes

      # Another label on that page isn't held.
      refute "outcome_unresolved" in assess(formless("Archive", "?draft=b", unresolved: held)).reason_codes
    end

    test "a later form sending to where the lost request went is held" do
      lost =
        record(
          report(%{"requests" => [request(nil, %{"url" => "https://shop.example/api/send"})]}),
          formless("Go", "?x=1")
        )

      held = Decisions.unresolved_keys([lost])

      form =
        assess(
          label: "Submit message",
          meta: %{"form" => %{"action" => "https://shop.example/api/send", "method" => "post"}},
          unresolved: held
        )

      assert "outcome_unresolved" in form.reason_codes
    end
  end

  describe "verifying" do
    test "a page that can't be observed leaves the outcome unresolved, never failed" do
      pending = record(report(%{"requests" => [request(200)]}))

      {v, r} =
        Decisions.verify(pending, observe: fn -> {:error, :crashed} end, decide: never())

      assert v.status == :unresolved
      assert v.reason_codes == ["outcome_unresolved", "observation_failed"]
      assert r.status == :unresolved

      # An outcome already settled isn't undone by failing to look again.
      edit =
        record(report(%{"fields" => [%{"after" => true}]}),
          tool: "browser_type",
          args: %{"ref" => "e1", "text" => "hi"},
          meta: %{"tag" => "textarea", "isSubmit" => false},
          label: "Note"
        )

      {v, r} = Decisions.verify(edit, observe: fn -> {:error, :crashed} end, decide: never())
      assert v.status == :unresolved and r.status == :succeeded
    end

    test "a sent action: the page's confirmation succeeds, its error fails, no answer is unresolved" do
      sent = record(report(%{"requests" => [request(200)]}))

      {v, r} =
        Decisions.verify(sent, observe: fn -> page("Note sent") end, decide: answers(0.9, 0.0))

      assert v.status == :succeeded and v.reason_codes == ["effect_observed"]
      assert r.status == :succeeded

      assert [%{schema: "browser-decision/3", kind: "verify", action_id: "act-" <> _}] =
               v.decisions

      assert_received {:shown, shown, [:shows_error, :took_effect]}
      assert shown.now.text == "Note sent" and shown.after_action.text == "Write a note"
      # What code verified goes as facts.
      assert shown.verified.facts == ["request pass: POST #{@page}/send: 200"]

      {v, _} =
        Decisions.verify(sent,
          observe: fn -> page("Couldn't send") end,
          decide: answers(0.1, 0.9)
        )

      assert v.status == :failed and v.reason_codes == ["error_shown"]

      {v, _} =
        Decisions.verify(sent,
          observe: fn -> page("?") end,
          decide: fn _, _ -> {:error, :down} end
        )

      assert v.status == :unresolved and "decision_unavailable" in v.reason_codes
    end

    test "a claim is judged on its own: it never decides whether the action took effect" do
      sent = record(report(%{"requests" => [request(200)]}))

      # A claim the page contradicts: the note went, but not to Sam.
      {v, r} =
        Decisions.verify(sent,
          observe: fn -> page("Note sent to Bo") end,
          claim: "sent to Sam",
          decide: answers(0.9, 0.0, 0.9)
        )

      assert v.status == :succeeded and v.claim == "contradicted"
      assert r.status == :succeeded and r.claim == "contradicted"
      assert Decisions.unresolved_keys([r]) == MapSet.new()

      assert_received {:shown,
                       %{
                         claimed_outcome: %{source: "agent", text: "sent to Sam"},
                         verified: %{outcome: "succeeded", facts: [_ | _]}
                       }, [:contradicts_claim]}

      # A detail the page doesn't show isn't a contradiction.
      {v, _} =
        Decisions.verify(sent,
          observe: fn -> page("Note sent") end,
          claim: "sent the note hello to Sam",
          decide: answers(0.9, 0.0, 0.1)
        )

      assert v.status == :succeeded and v.claim == "consistent"
    end

    test "concrete effects are confirmed in code, without asking" do
      # A removal: the row it acted on is gone from the same page.
      removed =
        record(
          report(%{
            "requests" => [request(303)],
            "row" => %{"before" => 1, "after" => 0, "now" => 0}
          }),
          label: "Remove"
        )

      assert removed.status == :succeeded and removed.codes == ["removed_from_page"]

      # A comment whose response was lost shows on the page it was sent from,
      # once that page has been loaded again.
      lost =
        record(
          report(%{
            "requests" => [request(502)],
            "content" => %{"values" => 1, "before" => [0], "after" => [nil], "now" => [nil]}
          })
        )

      assert lost.status == :unresolved

      {v, r} =
        Decisions.verify(lost,
          observe: fn -> shown("Comments: hello there", 1, "obs-a-2") end,
          decide: never()
        )

      assert v.status == :succeeded and v.reason_codes == ["content_shown", "server_error"]
      assert r.status == :succeeded
    end

    test "after trouble, a code confirmation needs a fresh page load, and fails safe" do
      lost =
        record(
          report(%{
            "requests" => [request(502)],
            "content" => %{"values" => 1, "before" => [0], "after" => [nil], "now" => [nil]}
          })
        )

      # The same page view as right after the action (no fresh load): not enough.
      {v, _} =
        Decisions.verify(lost,
          observe: fn -> shown("hello there", 1, "obs-a-1") end,
          decide: answers(0.1, 0.0)
        )

      assert v.status == :unresolved

      # Shown, but the page may say it didn't work: unresolved, without asking.
      for text <- [
            "Unable to post. hello there",
            "Invalid input: hello there",
            "Not sent: hello there",
            "hello there (awaiting moderation)"
          ] do
        {v, _} =
          Decisions.verify(lost, observe: fn -> shown(text, 1, "obs-a-2") end, decide: never())

        assert v.status == :unresolved and "page_ambiguous" in v.reason_codes, text
      end

      # Counts from another page aren't compared at all: the browser reports
      # none (nil), so nothing is confirmed.
      {v, _} =
        Decisions.verify(lost,
          observe: fn -> shown("Inbox: alice@example.com", nil, "obs-a-3") end,
          decide: answers(0.1, 0.0)
        )

      assert v.status == :unresolved
    end

    test "an autosave is confirmed only by a save carrying its value and a fresh reload" do
      edit = fn fields, requests ->
        record(report(%{"fields" => fields, "requests" => requests}),
          tool: "browser_type",
          args: %{"ref" => "e1", "text" => "Robin"},
          meta: %{"tag" => "input", "isSubmit" => false, "text" => "Display name", "form" => nil},
          label: "Display name"
        )
      end

      save = request(200, %{"url" => "https://shop.example/autosave", "carries_value" => true})
      beacon = request(204, %{"url" => "https://shop.example/beacon", "carries_value" => false})

      elsewhere =
        request(200, %{"url" => "https://tracker.example/save", "carries_value" => true})

      reloaded = %{"after" => true, "now" => true, "reread" => true, "reload" => true}
      # Chrome refilled the form after going back: read again, but no reload.
      restored = %{"after" => true, "now" => true, "reread" => true, "reload" => false}

      # Straight after, nothing has been reloaded yet: pending, not confirmed.
      typed = edit.([%{"after" => true, "now" => true}], [save])
      assert typed.status == :pending and typed.submission

      verify = fn fields, requests ->
        r = %{edit.([%{"after" => true}], []) | submission: true, status: :pending}

        observed =
          {:ok,
           %{
             "now" => %{"url" => @page, "text" => "Profile", "observation" => "obs-a-2"},
             "action" => report(%{"fields" => [fields], "requests" => requests})
           }}

        {v, _} = Decisions.verify(r, observe: fn -> observed end, decide: never())
        v
      end

      assert %{status: :succeeded, reason_codes: ["value_saved"]} = verify.(reloaded, [save])

      assert %{status: :unresolved, reason_codes: ["outcome_unresolved", "save_unproven"]} =
               verify.(restored, [save])

      assert verify.(reloaded, [beacon]).status == :unresolved
      assert verify.(reloaded, [elsewhere]).status == :unresolved
      assert verify.(reloaded, []).status == :unresolved
    end

    test "after a lost response, the decider may confirm only from the same page, reloaded, more surely" do
      lost =
        record(
          report(%{
            "requests" => [request(502)],
            "after" => %{"url" => @page, "text" => "502: may not have been saved"}
          })
        )

      reloaded = fn text ->
        {:ok,
         %{
           "now" => %{
             "url" => @page,
             "title" => "Notes",
             "text" => text,
             "observation" => "obs-a-2"
           },
           "action" => report(%{"requests" => [request(502)], "fresh_load" => true})
         }}
      end

      {v, r} =
        Decisions.verify(lost,
          observe: fn -> reloaded.("Notes: hi") end,
          decide: answers(0.6, 0.0)
        )

      assert v.status == :unresolved and r.status == :unresolved
      assert_received {:shown, shown, _}
      refute Map.has_key?(shown, :after_action)

      {v, r} =
        Decisions.verify(lost,
          observe: fn -> reloaded.("Notes: hi") end,
          decide: answers(0.8, 0.0)
        )

      assert v.status == :succeeded and v.reason_codes == ["effect_observed", "server_error"]
      assert r.status == :succeeded

      # Another page, or the same page view as right after the action: the
      # decider isn't even asked.
      # A new observation id without a whole document loaded (history.pushState)
      # doesn't count either.
      for {now, fresh} <- [
            {%{"url" => "https://shop.example/inbox", "text" => "hi", "observation" => "obs-a-3"},
             true},
            {%{"url" => @page, "text" => "hi", "observation" => "obs-a-1"}, false},
            {%{"url" => @page, "text" => "hi", "observation" => "obs-a-4"}, false}
          ] do
        seen = %{
          "now" => now,
          "action" => report(%{"requests" => [request(502)], "fresh_load" => fresh})
        }

        {v, _} = Decisions.verify(lost, observe: fn -> {:ok, seen} end, decide: never())

        assert v.status == :unresolved
      end
    end

    test "only the purchase gate's receipt settles an order; verifying never does" do
      # No order number, or "ORDER SUMMARY" read as one (no digits): unresolved.
      for order <- [nil, "SUMMARY"] do
        r = record(nil, label: "Place order", receipt: %{order: order})
        assert r.status == :unresolved and "receipt_uncertain" in r.codes
      end

      order = record(nil, label: "Place order", receipt: %{order: nil})

      # Order-like text on a later page (an old order on "Your orders")
      # neither confirms it nor lifts its hold, and the decider isn't asked.
      for text <- [
            "Your orders: ORDER # 112-7781 placed in May",
            "ORDER SUMMARY",
            "Order number: TA-1001"
          ] do
        {v, r} = Decisions.verify(order, observe: fn -> page(text) end, decide: never())
        assert v.status == :unresolved and r.status == :unresolved
        assert Decisions.unresolved_keys([r]) != MapSet.new()
      end

      # The gate's own receipt with an order number settles it.
      placed = record(nil, label: "Place order", receipt: %{order: "TA-1001"})
      assert placed.status == :succeeded and placed.codes == ["receipt_order"]
    end

    test "what never ran isn't looked at again; the agent can verify an action only so often" do
      denied = record(nil, decision: :denied)
      {v, _} = Decisions.verify(denied, observe: fn -> flunk("looked") end, decide: never())
      assert v.status == :failed and v.reason_codes == ["not_executed"]

      r = record(report(%{"requests" => [request(200)]}))

      r =
        Enum.reduce(1..3, r, fn _, r ->
          {_v, r} = Decisions.verify(r, observe: fn -> page("?") end, decide: answers(0.1, 0.0))
          r
        end)

      {v, _} = Decisions.verify(r, observe: fn -> flunk("looked") end, decide: never())
      assert "verify_limit" in v.reason_codes
    end
  end

  describe "the completion check" do
    test "with nothing failed or unresolved, the answer goes as it is, without asking" do
      ok = %{record(report(%{"requests" => [request(200)]})) | status: :succeeded}

      assert %{text: "Sent.", outcome: :delivered} =
               Decisions.completion([ok], "Sent.", decide: never())
    end

    test "an answer is replaced only when a verified outcome contradicts it" do
      # Earlier, on another form: a later success on the same form would
      # mean the failure was redone.
      done = %{
        record(report(%{"requests" => [request(200)]}),
          label: "Save",
          meta: %{"form" => %{"action" => @page <> "/save", "method" => "post"}}
        )
        | status: :succeeded
      }

      bad = failed(record(report(%{"requests" => [request(200)]})))
      lost = record(report(%{"requests" => [request(nil)]}))

      checked =
        Decisions.completion([done, bad, lost], "All done: your note was sent.",
          decide: answers(nil, nil, nil, 0.9)
        )

      assert checked.outcome == :replaced and checked.contradicted == [bad.id]
      assert checked.text =~ "tiny-axe held back the agent's reply"
      assert checked.text =~ ~s(✓ done: click "Save")
      assert checked.text =~ ~s(✗ not done: click "Send note": the page said it failed)
      assert checked.text =~ ~s(? click "Send note": the site's response was lost)
      refute checked.text =~ "All done"
      assert [%{kind: "completion", disposition: :contradicted}] = checked.records

      # Asked per action, with the verified outcomes as facts.
      assert_received {:shown, shown, [:claim_1]}

      assert [
               %{action: ~s(click "Save"), outcome: "confirmed"},
               %{
                 action: ~s(click "Send note"),
                 outcome: "failed",
                 why: "the page said it failed"
               },
               %{action: ~s(click "Send note"), outcome: "not confirmed"}
             ] = shown.verified.outcomes
    end

    test "only the actions the answer claims count: one question each" do
      a = failed(record(report(%{"requests" => [request(200)]})))
      b = failed(record(report(%{"requests" => [request(200)]}), label: "Post it"))

      checked =
        Decisions.completion([a, b], "The note failed, but I posted it.",
          decide: answers(nil, nil, nil, [0.1, 0.9])
        )

      assert checked.outcome == :replaced and checked.contradicted == [b.id]
      assert_received {:shown, _, [:claim_1, :claim_2]}
    end

    test "failures past the questions one check asks are noted, never passed over" do
      failures =
        for i <- 1..7,
            do: failed(record(report(%{"requests" => [request(200)]}), label: "Send #{i}"))

      checked = Decisions.completion(failures, "Sent!", decide: answers(nil, nil, nil, 0.1))
      assert_received {:shown, _, questions}
      assert length(questions) == 6

      assert checked.outcome == :caveated
      assert checked.text =~ ~s(✗ not done: click "Send 7")
      assert String.ends_with?(checked.text, "\n\nSent!")
    end

    test "something merely unresolved keeps the answer, under a note naming it, without asking" do
      lost = record(report(%{"requests" => [request(nil)]}))
      checked = Decisions.completion([lost], "Your note was sent.", decide: never())

      assert checked.outcome == :caveated and checked.unconfirmed == [lost.id]

      assert checked.text ==
               "⚠ tiny-axe couldn't confirm all of this answer. Not confirmed:\n" <>
                 ~s(? click "Send note": the site's response was lost, so it may or may not ) <>
                 "have gone through. tiny-axe won't repeat it; check before trying again.\n\n" <>
                 "Your note was sent."
    end

    test "when the decider can't judge, the answer stays, marked as not confirmed" do
      bad = failed(record(report(%{"requests" => [request(200)]})))
      down = Decisions.completion([bad], "Sent!", decide: fn _, _ -> {:error, :down} end)

      assert down.outcome == :caveated

      assert down.text =~
               ~s(⚠ tiny-axe couldn't confirm all of this answer. Not confirmed:\n✗ not done)

      assert String.ends_with?(down.text, "\n\nSent!")
      assert [%{reason_codes: ["decision_unavailable"]}] = down.records
    end

    test "an honest answer about a failure or a declined action goes as it is" do
      bad = failed(record(report(%{"requests" => [request(200)]})))
      denied = record(nil, decision: :denied)

      checked =
        Decisions.completion([bad, denied], "It failed, and you said no to the other.",
          decide: answers(nil, nil, nil, 0.1)
        )

      assert checked.outcome == :delivered and
               checked.text == "It failed, and you said no to the other."
    end

    test "a claim judged contradicted is the agent's feedback, never grounds to replace" do
      odd = %{
        record(report(%{"requests" => [request(200)]}))
        | status: :succeeded,
          claim: "contradicted"
      }

      assert %{outcome: :delivered} = Decisions.completion([odd], "Sent to Sam.", decide: never())
    end

    test "a click refused for a missing or stale target isn't a failure the answer could claim" do
      lost_target =
        Decisions.assess(
          %{
            task: "t",
            server: "browser",
            name: "browser__browser_click",
            tool: "browser_click",
            args: %{"ref" => "e9"},
            mode: :execute
          },
          inspect: fn _ -> nil end,
          decide: never(),
          now: 0
        )

      assert "target_not_found" in lost_target.reason_codes

      r =
        Decisions.record(lost_target, %{
          decision: :refused,
          browser_tool: "browser_click",
          args: %{},
          execution: nil,
          error_result: true
        })

      assert %{outcome: :delivered, problems: []} =
               Decisions.completion([r], "The Summit is lighter, at 1.9 kg.", decide: never())

      # A send the decision service couldn't check is one.
      down = %{r | assessment_codes: ["decision_unavailable"]}

      assert %{problems: [_]} =
               Decisions.completion([down], "Sent.", decide: answers(nil, nil, nil, 0.1))
    end

    test "a declined action counts as redone only by a later success on the same target" do
      declined = record(nil, decision: :denied)

      # Another button of the same form (Save draft) succeeding isn't it.
      draft = %{
        record(report(%{"requests" => [request(200)]}), label: "Save draft")
        | status: :succeeded
      }

      checked =
        Decisions.completion([declined, draft], "I sent the email.",
          decide: answers(nil, nil, nil, 0.9)
        )

      assert checked.outcome == :replaced and checked.contradicted == [declined.id]

      # The same button, clicked again and confirmed, is.
      redone = %{record(report(%{"requests" => [request(200)]})) | status: :succeeded}

      assert %{outcome: :delivered, problems: []} =
               Decisions.completion([declined, redone], "I sent the email.", decide: never())
    end

    test "a refused repeat of an unresolved action isn't another problem" do
      lost = record(report(%{"requests" => [request(nil)]}))
      held = Decisions.unresolved_keys([lost])
      blocked = assess(unresolved: held)

      repeat =
        Decisions.record(blocked, %{
          decision: :refused,
          browser_tool: "browser_click",
          args: %{},
          execution: nil,
          error_result: true
        })

      checked =
        Decisions.completion([repeat, lost], "Not sure it went.", decide: never())

      assert Enum.map(checked.problems, & &1.id) == [lost.id]
    end
  end
end
