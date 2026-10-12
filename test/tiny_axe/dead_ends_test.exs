defmodule TinyAxe.DeadEndsTest do
  @moduledoc """
  Paths that didn't work (`TinyAxe.Browser.DeadEnds`): kept per site, judged
  by Jev (or two failures), told to the agent when it reaches the site, and
  a repeat that fails again in the same task refused.
  """

  use ExUnit.Case, async: false

  alias TinyAxe.Browser.DeadEnds

  @target %{
    "text" => "Guest Checkout",
    "page" => "https://www.musiciansfriend.com/checkout/12345"
  }

  defp failed(target \\ @target, tool \\ "browser_click", codes \\ ["effect_not_observed"]) do
    %{
      id: "act-#{System.unique_integer([:positive])}",
      status: :unresolved,
      codes: ["outcome_unresolved" | codes],
      target: target,
      browser_tool: tool,
      description: ~s(click "#{target["text"]}")
    }
  end

  setup do
    Application.put_env(:tiny_axe, :dead_ends, enabled: true)
    File.rm(DeadEnds.path())

    on_exit(fn ->
      File.rm(DeadEnds.path())
      Application.put_env(:tiny_axe, :dead_ends, enabled: false)
    end)
  end

  test "the key: site, the page's path made general, the action, the label" do
    assert DeadEnds.key(@target, "browser_click") ==
             "www.musiciansfriend.com|/checkout/:id|click|Guest Checkout"

    assert DeadEnds.key(
             %{"text" => "  Add  to\ncart ", "page" => "https://a.example/dp/B0C1D2"},
             "browser_type"
           ) ==
             "a.example|/dp/:id|type|Add to cart"

    assert DeadEnds.key(%{"page" => "https://a.example/"}, "browser_click") == nil
    assert DeadEnds.key(nil, "browser_click") == nil
  end

  test "only failures count: not a refusal or the user's no" do
    assert DeadEnds.failure?(failed())
    assert DeadEnds.failure?(%{status: :failed, codes: ["error_shown"]})
    refute DeadEnds.failure?(%{status: :failed, codes: ["not_executed"]})
    refute DeadEnds.failure?(%{status: :succeeded, codes: ["value_set"]})
  end

  test "Jev judges the first failure; two make a dead end whatever it said" do
    assert %{"verdict" => "one_off", "failures" => 1} =
             DeadEnds.add_now(failed(), decide: fn _ -> false end)

    assert DeadEnds.known("www.musiciansfriend.com") == []
    refute DeadEnds.dead_end?(DeadEnds.key(@target, "browser_click"))

    assert %{"verdict" => "dead_end", "failures" => 2} =
             DeadEnds.add_now(failed(), decide: fn _ -> false end)

    assert [%{"label" => "Guest Checkout", "path" => "/checkout/:id"}] =
             DeadEnds.known("www.musiciansfriend.com")

    other = %{"text" => "Place order", "page" => "https://shop.example/pay"}

    assert %{"verdict" => "dead_end", "failures" => 1} =
             DeadEnds.add_now(failed(other), decide: fn info -> info.failures_before == 0 end)
  end

  test "the warning names each dead end, once a site has some" do
    assert DeadEnds.warning("www.musiciansfriend.com") == nil
    DeadEnds.add_now(failed(), decide: fn _ -> true end)

    warning = DeadEnds.warning("www.musiciansfriend.com")
    assert warning =~ "Known dead ends on www.musiciansfriend.com"

    assert warning =~
             ~s{- click "Guest Checkout" on /checkout/:id: didn't work once (effect_not_observed)}

    assert DeadEnds.warning("other.example") == nil
  end

  test "blocked: a dead end that already failed in this task, not before" do
    key = DeadEnds.key(@target, "browser_click")
    DeadEnds.add_now(failed(), decide: fn _ -> true end)

    refute DeadEnds.blocked?(key, [])
    refute DeadEnds.blocked?(key, [%{failed() | status: :succeeded, codes: []}])
    assert DeadEnds.blocked?(key, [failed()])
    refute DeadEnds.blocked?(nil, [failed()])
  end

  test "an entry not seen for 30 days is dropped; forget a site or all" do
    DeadEnds.add_now(failed(), decide: fn _ -> true end)
    other = %{"text" => "Pay", "page" => "https://shop.example/pay"}
    DeadEnds.add_now(failed(other), decide: fn _ -> true end)
    assert length(DeadEnds.list()) == 2

    assert DeadEnds.forget("shop.example") == 1
    assert [%{"host" => "www.musiciansfriend.com"}] = DeadEnds.list()

    # Aged past 30 days.
    raw = File.read!(DeadEnds.path()) |> JSON.decode!()
    old = DateTime.utc_now() |> DateTime.add(-31, :day) |> DateTime.to_iso8601()

    aged =
      update_in(raw, ["paths"], fn paths ->
        Map.new(paths, fn {k, e} -> {k, %{e | "last" => old}} end)
      end)

    File.write!(DeadEnds.path(), JSON.encode!(aged))
    assert DeadEnds.list() == []

    DeadEnds.add_now(failed(), decide: fn _ -> true end)
    assert DeadEnds.forget(:all) == 1
    assert DeadEnds.list() == []
  end
end
