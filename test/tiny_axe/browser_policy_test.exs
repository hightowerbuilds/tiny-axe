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

  test "forms: GET is a read, POST asks, a password form signs in, a payment form is a purchase" do
    submit = &button("Go", %{"isSubmit" => true, "form" => form(&1)})

    assert click(submit.(%{"method" => "get", "action" => "https://shop.example/search?q=x"})) ==
             {:read, nil}

    assert {:outward, ~s(submits the form "Contact" to shop.example (POST\))} =
             click(submit.(%{}))

    assert {:outward, "signs in: " <> _} = click(submit.(%{"hasPassword" => true}))
    assert {:commit, _} = click(submit.(%{"hasPayment" => true}))
  end

  test "button words: purchases, things that send, and things that are undoable" do
    for label <- ["Place order", "Buy now", "Pay now", "Subscribe", "Complete purchase"],
        do: assert({:commit, _} = click(button(label)), label)

    for label <- ["Send", "Post reply", "Delete repository", "Sign up", "Remove from cart"],
        do: assert({:outward, _} = click(button(label)), label)

    # Not asked about, and Jev isn't consulted.
    Decider.Script.script(fn _, _, _ ->
      flunk("Jev was asked about an obviously undoable button")
    end)

    for label <- ["Add to cart", "Add to bag", "Show more", "Next", "Accept all cookies"],
        do: assert(click(button(label)) == {:local, nil}, label)
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
    assert {:outward, why} = click(button("⚙"))
    assert why =~ "couldn't check"

    Decider.Script.script(fn _, _, _ -> {:error, :down} end)
    assert {:outward, _} = click(button("⚙"))
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

  test "if the target can't be seen, a click is asked about" do
    assert {:outward, why} = click(nil)
    assert why =~ "couldn't see"
  end
end
