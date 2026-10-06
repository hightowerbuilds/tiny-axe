defmodule TinyAxe.PurchaseSettingsTest do
  @moduledoc "purchases.json and `mix tiny_axe.purchases`; the TUI's purchases-on sign."

  # Points the app-wide purchases.json at a temp file, so not async.
  use ExUnit.Case, async: false

  alias TinyAxe.{Purchases, TUI}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    keys = [:purchases_config, :purchases, :state_dir]
    previous = Map.new(keys, &{&1, Application.get_env(:tiny_axe, &1)})
    Application.put_env(:tiny_axe, :purchases_config, Path.join(dir, "purchases.json"))

    Application.put_env(:tiny_axe, :purchases,
      enabled: false,
      per_order_max: 100.0,
      daily_max: 200.0,
      currency: "USD"
    )

    Application.put_env(:tiny_axe, :state_dir, dir)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)

      for {k, v} <- previous,
          do:
            if(v == nil,
              do: Application.delete_env(:tiny_axe, k),
              else: Application.put_env(:tiny_axe, k, v)
            )
    end)
  end

  defp output do
    receive do
      {:mix_shell, _, [line]} -> line <> "\n" <> output()
    after
      0 -> ""
    end
  end

  defp task(args), do: Mix.Tasks.TinyAxe.Purchases.run(args)

  test "on and off, without touching code" do
    refute Purchases.enabled?()
    task(["on"])
    assert Purchases.enabled?()
    assert output() =~ "Purchases: ON"
    task(["off"])
    refute Purchases.enabled?()
  end

  test "limits, shops and cards go to the file, which overrides the config" do
    task(["limits", "--per-order", "25", "--daily", "40", "--currency", "gbp"])
    task(["shops", "shop.example", "books.example"])
    task(["card", "add", "Privacy ••1234", "--keyring", "card-test", "--shops", "shop.example"])

    s = Purchases.settings()
    assert s[:per_order_max] == 25.0 and s[:daily_max] == 40.0 and s[:currency] == "GBP"
    assert s[:merchants] == ["shop.example", "books.example"]

    assert [%{label: "Privacy ••1234", keyring: "card-test", merchants: ["shop.example"]}] =
             s[:cards]

    # The file holds names, never card details.
    refute File.read!(Purchases.config_path()) =~ "4111"
    assert File.stat!(Purchases.config_path()).mode |> Bitwise.band(0o777) == 0o600

    task(["card", "remove", "Privacy ••1234"])
    assert Purchases.settings()[:cards] == []
  end

  test "status says whether a card's details are in the keyring, never what they are" do
    task(["card", "add", "Test card", "--keyring", "card-test"])
    task(["card", "add", "Missing card", "--keyring", "nope"])
    output()
    task([])
    out = output()

    assert out =~ "Test card (in the keyring; any shop)"
    assert out =~ "Missing card (NOT in the keyring yet; any shop)"
    refute out =~ "4111"
  end

  test "recent purchases are listed with what happened" do
    id = Purchases.start(%{request: "mug", max: 50.0, currency: "USD"})

    Purchases.event(id, %{
      t: "summary",
      summary: %{"host" => "shop.example", "total_text" => "$16.00"}
    })

    Purchases.event(id, %{t: "clicking"})
    task([])
    assert output() =~ ~r/shop\.example  \$16\.00  MAY have been placed/
  end

  test "the TUI says when purchases are on, first, so a long folder can't hide it" do
    # A folder long enough to fill the title.
    deep = Path.join([System.tmp_dir!() | List.duplicate("a-rather-long-folder-name", 8)])
    File.mkdir_p!(deep)
    {:ok, _} = TinyAxe.Location.cd(deep)
    on_exit(fn -> TinyAxe.Location.reset() end)

    {:ok, state} = TUI.mount(test_mode: {140, 30})

    draw = fn ->
      t = ExRatatui.init_test_terminal(140, 30)
      ExRatatui.draw(t, TUI.render(state, %ExRatatui.Frame{width: 140, height: 30}))
      ExRatatui.get_buffer_content(t)
    end

    refute draw.() =~ "purchases on"
    task(["on"])
    # The emoji is double-width on screen.
    assert draw.() =~ ~r/💳\s+purchases on/
  end
end
