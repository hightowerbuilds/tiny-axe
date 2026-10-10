defmodule TinyAxe.Browser.EvidenceTest do
  @moduledoc """
  What browser decisions are shown: bounded, redacted, and labelled by where
  each part came from.
  """

  use ExUnit.Case, async: true

  alias TinyAxe.Browser.Evidence

  @card "4242 4242 4242 4242"

  defp target(extra \\ %{}) do
    Map.merge(
      %{
        "tag" => "button",
        "text" => "Continue",
        "role" => "",
        "page" => "https://shop.example/review",
        "context" => "Review your order.",
        "sensitive" => false,
        "isSubmit" => false
      },
      extra
    )
  end

  defp click(target, context \\ %{}),
    do:
      Evidence.build(
        context,
        %{tool: "browser_click", args: %{"ref" => "e1"}, description: "click this control"},
        target
      )

  test "each part says where it came from; the agent's proposal is never an observation" do
    e =
      click(target(), %{
        objective: "buy the blue mug, under $20",
        intent: %{request: "buy the blue mug", max: 20.0, currency: "USD"},
        recent: [%{tool: "browser_navigate", class: :read, decision: :ran, error: false}]
      })

    assert e.schema == "browser-evidence/1"

    assert e.task == %{
             source: "user",
             objective: "buy the blue mug, under $20",
             purchase: %{max_price: 20.0, currency: "USD"}
           }

    assert e.target["source"] == "page" and e.observation.source == "page"

    assert e.proposed_action == %{
             source: "agent",
             tool: "browser_click",
             action: "click this control",
             args: %{"ref" => "e1"}
           }

    assert e.recent_actions == %{
             source: "harness",
             items: [
               %{
                 "tool" => "browser_navigate",
                 "class" => "read",
                 "decision" => "ran",
                 "error" => false
               }
             ]
           }

    assert e.truncated == []
    # Field metadata the decision doesn't need stays out.
    refute Map.has_key?(e.target, "sensitive")
  end

  test "no task context: the evidence says so rather than guessing" do
    e = click(target(), nil)
    assert e.task == %{source: "user", objective: nil, purchase: nil}
    assert e.recent_actions.items == []
  end

  test "every text has a budget, and whatever was cut is listed" do
    fields =
      for i <- 1..40,
          do: %{"tag" => "input", "type" => "text", "name" => "f#{i}", "value" => "secret"}

    e =
      click(
        target(%{
          "text" => String.duplicate("L", 500),
          "context" => String.duplicate("c", 5_000),
          "form" => %{
            "action" => "https://shop.example/send",
            "method" => "post",
            "label" => String.duplicate("F", 500),
            "submitText" => "Send",
            "fields" => fields
          }
        }),
        %{
          objective: String.duplicate("o", 5_000),
          recent: for(i <- 1..9, do: %{tool: "t#{i}", class: :read, decision: :ran, error: false})
        }
      )

    assert String.length(e.task.objective) == 1_000
    assert String.length(e.target["text"]) == 200
    assert String.length(e.target["context"]) == 2_000
    assert length(e.target["form"]["fields"]) == 30
    # Field values never come along, only what each field is.
    refute Enum.any?(e.target["form"]["fields"], &Map.has_key?(&1, "value"))
    # The newest five calls.
    assert Enum.map(e.recent_actions.items, & &1["tool"]) == ~w(t5 t6 t7 t8 t9)

    assert Enum.sort(e.truncated) ==
             Enum.sort(
               ~w(task.objective target.text target.context target.form.fields target.form.label)
             )

    # However big the page, the evidence stays bounded.
    assert byte_size(JSON.encode!(e)) < 12_000
  end

  test "a context the page already cut short is reported as cut" do
    assert "target.context" in click(target(%{"contextTruncated" => true})).truncated
  end

  test "typed text stays in tiny-axe: only its length is shown" do
    e =
      Evidence.build(
        nil,
        %{
          tool: "browser_type",
          args: %{"ref" => "e3", "text" => "my home address is 1 Elm St", "submit" => true},
          description: "change this field or selection"
        },
        target(%{"tag" => "input", "type" => "text"})
      )

    assert e.proposed_action.args == %{"ref" => "e3", "typed_chars" => 27, "submit" => true}
    refute inspect(e) =~ "Elm"

    e =
      Evidence.build(
        nil,
        %{tool: "browser_fill_form", args: %{"fields" => [%{"ref" => "e4", "value" => "Sam"}]}},
        target()
      )

    assert e.proposed_action.args == %{"fields" => [%{"ref" => "e4", "typed_chars" => 3}]}
  end

  test "other arguments are capped; nested ones are left out" do
    e =
      Evidence.build(
        nil,
        %{
          tool: "browser_select_option",
          args: %{
            "ref" => "e5",
            "element" => String.duplicate("x", 500),
            "values" => Enum.map(1..20, &"v#{&1}"),
            "extra" => %{"deep" => "thing"}
          }
        },
        target()
      )

    args = e.proposed_action.args
    assert String.length(args["element"]) == 200
    assert length(args["values"]) == 10
    assert args["extra"] == "(omitted)"
    assert "proposed_action.args.element" in e.truncated
    assert "proposed_action.args.values" in e.truncated
  end

  test "URLs lose credentials, queries and fragments; card numbers go everywhere" do
    e =
      click(
        target(%{
          "page" => "https://user:pw@shop.example/review?token=abc#frag",
          "href" => "https://shop.example/next?session=abc",
          "context" => "Paying with #{@card}.",
          "form" => %{"action" => "https://shop.example/pay?sid=abc", "method" => "post"}
        }),
        %{objective: "pay with card #{@card}"}
      )

    assert e.target["page"] == "https://shop.example/review"
    assert e.observation.page == "https://shop.example/review"
    assert e.target["href"] == "https://shop.example/next"
    assert e.target["form"]["action"] == "https://shop.example/pay"

    text = JSON.encode!(e)
    refute text =~ "4242"
    refute text =~ "abc"
    refute text =~ "pw@"
  end

  test "the same target gets the same observation id; a different one doesn't" do
    a = click(target())
    b = click(target())
    c = click(target(%{"text" => "Place order"}))

    assert a.observation.id == b.observation.id
    assert a.observation.id != c.observation.id
    assert a.observation.id =~ ~r/\Aobs-[0-9a-f]{16}\z/
  end

  test "hashes don't depend on map key order" do
    assert Evidence.hash(%{a: 1, b: %{c: [1, 2]}}) ==
             Evidence.hash(%{"b" => %{"c" => [1, 2]}, "a" => 1})

    refute Evidence.hash(%{a: 1}) == Evidence.hash(%{a: 2})
  end
end
