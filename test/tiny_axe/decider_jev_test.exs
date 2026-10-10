defmodule TinyAxe.Decider.JevTest do
  @moduledoc """
  The Jev adapter against a stubbed API: what it sends, what it reports
  about who answered, and how it treats answers that don't fit the question.
  """

  # Swaps the app-wide Jev config and decider, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.Decider
  alias TinyAxe.Decider.Jev

  setup do
    previous = {Application.get_env(:tiny_axe, :jev), Application.get_env(:tiny_axe, :decider)}

    Application.put_env(:tiny_axe, :jev,
      api_key: "test-key",
      model: "jev-latest",
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    )

    on_exit(fn ->
      {jev, decider} = previous
      Application.put_env(:tiny_axe, :jev, jev)
      Application.put_env(:tiny_axe, :decider, decider)
    end)
  end

  defp reply(body, test \\ self()) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:sent, JSON.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_header("x-typesafe-request-id", "req_123")
      |> Req.Test.json(body)
    end)
  end

  @noul %{type: :noul, instructions: "Would this pay now?"}
  @choice %{type: :choice, instructions: "Which?", options: %{cart: "adds to cart", pay: "pays"}}
  @score %{type: :score, instructions: "How risky?", criteria: ["low", "medium", "high"]}

  test "yes/no criteria are sent as Jev's true/false meanings" do
    reply(%{"model" => "jev-1.13.0", "answers" => %{"spends" => %{"noul" => 0.1}}})

    question = Map.put(@noul, :criteria, %{true: "It charges now", false: "Confirmed later"})
    assert {:ok, %{spends: %{noul: 0.1}}} = Jev.decide("state", %{spends: question})

    assert_received {:sent, %{"questions" => %{"spends" => sent}}}

    assert sent == %{
             "type" => "noul",
             "instructions" => "Would this pay now?",
             "criteria" => %{"true" => "It charges now", "false" => "Confirmed later"}
           }
  end

  test "who answered: the resolved model, token usage and the request id" do
    reply(%{
      "model" => "jev-1.13.0",
      "answers" => %{"spends" => %{"noul" => 0.03}},
      "usage" => %{"input_tokens" => 366, "output_tokens" => 49}
    })

    assert {:ok, %{spends: %{noul: 0.03}}, meta} = Jev.decide_meta("state", %{spends: @noul})

    assert meta == %{
             model: "jev-1.13.0",
             usage: %{input_tokens: 366, output_tokens: 49},
             request_id: "req_123"
           }

    # Through the Decider, with the backend and timing added.
    Application.put_env(:tiny_axe, :decider, Jev)
    assert {:ok, _answers, traced} = Decider.decide_traced("state", %{spends: @noul})
    assert %{backend: "jev", model: "jev-1.13.0", request_id: "req_123", ms: ms} = traced
    assert is_integer(ms)
    # decide/2 keeps its shape for every existing caller.
    assert {:ok, %{spends: %{noul: 0.03}}} = Decider.decide("state", %{spends: @noul})
  end

  test "answers that don't fit the question become unknown, never a guess" do
    reply(%{
      "model" => "jev-1.13.0",
      "answers" => %{
        "too_high" => %{"noul" => 1.4},
        "text" => %{"noul" => "yes"},
        "offlist" => %{"choice" => "refund", "probabilities" => %{"refund" => 1.0}},
        "choice" => %{
          "choice" => "cart",
          "probabilities" => %{"cart" => 0.9, "pay" => 0.1, "refund" => 0.5, "bad" => 2},
          "confidence" => 0.8
        },
        "score" => %{
          "score" => 1.5,
          "probabilities" => %{"1" => 0.5, "2" => 0.5, "x" => 0.1, "9" => 0.2}
        },
        "bad_score" => %{"score" => 7}
      }
    })

    questions = %{
      too_high: @noul,
      text: @noul,
      missing: @noul,
      offlist: @choice,
      choice: @choice,
      score: @score,
      bad_score: @score
    }

    assert {:ok, a} = Jev.decide("state", questions)

    for key <- [:too_high, :text, :missing] do
      assert %{noul: nil, unknown: true} = a[key]
      assert Decider.p(a, key) == nil
    end

    assert %{choice: nil, unknown: true} = a.offlist
    # Only offered options with real probabilities are kept.
    assert a.choice == %{choice: :cart, probabilities: %{cart: 0.9, pay: 0.1}, confidence: 0.8}
    assert a.score == %{score: 1.5, probabilities: %{1 => 0.5, 2 => 0.5}, confidence: nil}
    assert %{score: nil, unknown: true} = a.bad_score
  end

  test "a 200 without answers is an error, not an empty decision" do
    reply(%{"model" => "jev-1.13.0", "detail" => "odd"})
    assert {:error, {:malformed, _}} = Jev.decide("state", %{spends: @noul})
  end
end
