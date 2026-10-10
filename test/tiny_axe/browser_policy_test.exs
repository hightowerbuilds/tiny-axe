defmodule TinyAxe.BrowserPolicyTest do
  @moduledoc """
  How the gate classes browser actions, from what `browser_inspect` reports
  about the target. Pure: no browser; Jev is scripted.
  """

  # Swaps the app-wide decider, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.Decider
  alias TinyAxe.Tools.BrowserPolicy

  setup do
    previous =
      {Application.get_env(:tiny_axe, :decider), Application.get_env(:tiny_axe, :script_decider)}

    Decider.Script.script(fn _, _, _ -> nil end)

    on_exit(fn ->
      {decider, script} = previous
      Application.put_env(:tiny_axe, :decider, decider)
      if script, do: Application.put_env(:tiny_axe, :script_decider, script)
    end)
  end

  @page "https://shop.example/item"

  defp button(text, extra \\ %{}),
    do:
      Map.merge(
        %{"tag" => "button", "text" => text, "isSubmit" => false, "href" => nil, "page" => @page},
        extra
      )

  defp form(extra),
    do:
      Map.merge(
        %{
          "action" => "https://shop.example/send",
          "method" => "post",
          "hasPassword" => false,
          "hasPayment" => false,
          "label" => "Contact"
        },
        extra
      )

  defp click(meta),
    do: BrowserPolicy.classify("browser_click", %{"ref" => "e1"}, fn _ -> meta end)

  test "links are reads, unless the address carries a lot of data" do
    assert click(button("Docs", %{"href" => "https://docs.example/a"})) == {:read, nil}

    long = "https://evil.example/c?d=" <> String.duplicate("x", 300)
    assert {:outward, why} = click(button("Next", %{"href" => long}))
    assert why =~ "evil.example with 302 characters of data"
  end

  test "forms: GET is a read, POST asks, a password form signs in, card details are a payment step" do
    submit = &button("Go", %{"isSubmit" => true, "form" => form(&1)})

    assert click(submit.(%{"method" => "get", "action" => "https://shop.example/search?q=x"})) ==
             {:read, nil}

    assert {:outward, ~s(submits the form "Contact" to shop.example (POST\))} =
             click(submit.(%{}))

    assert {:outward, "signs in: " <> _} = click(submit.(%{"hasPassword" => true}))
    # Card details with "Go": a payment step; the order comes later.
    assert {:payment_step, _} = click(submit.(%{"hasPayment" => true}))
  end

  test "button words: purchases, things that send, and things that are undoable" do
    for label <- ["Place order", "Buy now", "Pay now", "Subscribe", "Complete purchase"],
        do: assert({:commit, _} = click(button(label)), label)

    for label <- ["Send", "Post reply", "Delete repository", "Sign up", "Remove from cart"],
        do: assert({:outward, _} = click(button(label)), label)

    # Familiar words alone cannot prove what a site's handler does.
    me = self()

    Decider.Script.script(fn _, _, state ->
      send(me, {:assessed, state})
      0.0
    end)

    for label <- ["Add to cart", "Add to bag", "Show more", "Next", "Accept all cookies"],
        do: assert(click(button(label)) == {:local, nil}, label)

    assert_received {:assessed, %{observed_target: _}}
  end

  test "an unclear button goes to Jev, and no answer is the stricter class" do
    Decider.Script.script(fn
      :spends, _, _ -> 0.6
      _, _, _ -> nil
    end)

    assert {:commit, _} = click(button("⚙"))

    Decider.Script.script(fn
      :sends, _, _ -> 0.8
      _, _, _ -> nil
    end)

    assert {:outward, _} = click(button("⚙"))

    Decider.Script.script(fn _, _, _ -> :unknown end)
    assert {:refused, why} = click(button("⚙"))
    assert why =~ "couldn't check"

    Decider.Script.script(fn _, _, _ -> {:error, :down} end)
    assert {:refused, _} = click(button("⚙"))
  end

  test "typing: never into a password or card field; Enter in a form submits it" do
    sensitive = fn _ -> %{"sensitive" => true} end

    assert {:refused, _} =
             BrowserPolicy.classify("browser_type", %{"ref" => "e1", "text" => "x"}, sensitive)

    assert {:refused, _} =
             BrowserPolicy.classify(
               "browser_fill_form",
               %{"fields" => [%{"ref" => "e1", "value" => "x"}]},
               sensitive
             )

    in_form = fn _ -> %{"sensitive" => false, "text" => "", "form" => form(%{})} end

    assert {:local, nil} =
             BrowserPolicy.classify("browser_type", %{"ref" => "e1", "text" => "hi"}, in_form)

    assert {:outward, _} =
             BrowserPolicy.classify(
               "browser_type",
               %{"ref" => "e1", "text" => "hi", "submit" => true},
               in_form
             )

    assert {:outward, _} =
             BrowserPolicy.classify("browser_press_key", %{"key" => "Enter"}, in_form)

    assert {:local, nil} =
             BrowserPolicy.classify("browser_press_key", %{"key" => "ArrowDown"}, in_form)
  end

  test "dialogs, uploads, handoffs, and the gate's own inspect tool" do
    dialog = fn _ -> %{"dialog" => %{"message" => "Delete everything?"}} end

    assert {:outward, ~s(answers OK to the page's dialog: "Delete everything?")} =
             BrowserPolicy.classify("browser_handle_dialog", %{"accept" => true}, dialog)

    assert {:local, nil} =
             BrowserPolicy.classify("browser_handle_dialog", %{"accept" => false}, dialog)

    assert {:outward, "uploads ~/cv.pdf to the page"} =
             BrowserPolicy.classify("browser_file_upload", %{"paths" => ["~/cv.pdf"]}, dialog)

    assert {:handoff, "log in"} =
             BrowserPolicy.classify("browser_handoff", %{"reason" => "log in"}, dialog)

    assert {:refused, _} = BrowserPolicy.classify("browser_inspect", %{}, dialog)
  end

  test "choosing an option is local, whatever its label says" do
    for type <- ["radio", "checkbox"],
        do: assert(click(button("Pay with PayPal", %{"type" => type})) == {:local, nil})
  end

  test "if the target can't be seen, a click is refused, not asked about" do
    assert {:refused, why} = click(nil)
    assert why =~ "couldn't see what this would click"

    assert {:refused, _} =
             BrowserPolicy.classify(
               "browser_type",
               %{"ref" => "x", "text" => "y", "submit" => true},
               fn _ -> nil end
             )
  end

  test "a generic POST purchase and a misleading link use the decider" do
    Decider.Script.script(fn
      :spends, _, _ -> 0.95
      _, _, _ -> 0.0
    end)

    assert {:commit, _} = click(button("Continue", %{"href" => "https://shop.example/final"}))
    assert {:commit, _} = click(button("Continue", %{"isSubmit" => true, "form" => form(%{})}))
  end

  test "Enter in a GET field uses the default submit button's label" do
    target = %{
      "tag" => "input",
      "text" => "Account",
      "form" => form(%{"method" => "get", "submitText" => "Delete account"})
    }

    assert {:outward, _} =
             BrowserPolicy.classify("browser_press_key", %{"key" => "Enter"}, fn _ -> target end)
  end

  test "decision evidence includes context but excludes URL credentials and card numbers" do
    me = self()

    Decider.Script.script(fn _, _, state ->
      send(me, {:state, state})
      0.0
    end)

    click(
      button("Continue", %{
        "page" => "https://user:secret@shop.example/review?token=secret#secret",
        "context" => "Card 4242 4242 4242 4242. Changes are saved immediately.",
        "contextTruncated" => true,
        "form" => form(%{"action" => "https://shop.example/action?token=secret"})
      })
    )

    assert_received {:state, %{observed_target: target} = state}
    assert target["page"] == "https://shop.example/review"
    assert target["form"]["action"] == "https://shop.example/action"
    assert target["contextTruncated"] == true
    refute inspect(state) =~ "secret"
    refute inspect(state) =~ "4242"
  end
end
