defmodule Mix.Tasks.TinyAxe.Purchases do
  @shortdoc "Turn purchases on or off, set limits and cards, and see what was bought"
  @moduledoc """
  Purchase settings, in `~/.config/tiny-axe/purchases.json` (`TinyAxe.Purchases`):

      mix tiny_axe.purchases                       # status: on/off, limits, cards, today, recent orders
      mix tiny_axe.purchases on                    # let agents buy (within the limits, after you type the total)
      mix tiny_axe.purchases off
      mix tiny_axe.purchases limits --per-order 25 --daily 50 --currency USD
      mix tiny_axe.purchases shops any             # or: shops amazon.com bookshop.org
      mix tiny_axe.purchases card add "Privacy ••1234" --keyring card-1 [--shops amazon.com]
      mix tiny_axe.purchases card remove "Privacy ••1234"

  A card's details go in the keyring, never here (see `card add`). This file is
  read when tiny-axe needs it, so changes apply at once, in an installed copy too.
  """

  use Mix.Task

  alias TinyAxe.{MCP, Purchases}

  @impl true
  def run(["on"]) do
    Purchases.update_file(&Map.put(&1, "enabled", true))

    Mix.shell().info(
      "Purchases are on. Agents can buy only within your limits, and only after you type the total."
    )

    run([])
  end

  def run(["off"]) do
    Purchases.update_file(&Map.put(&1, "enabled", false))
    Mix.shell().info("Purchases are off.")
  end

  def run(["limits" | rest]) do
    {opts, _, _} =
      OptionParser.parse(rest, strict: [per_order: :float, daily: :float, currency: :string])

    Purchases.update_file(fn json ->
      json
      |> put_if("per_order_max", opts[:per_order])
      |> put_if("daily_max", opts[:daily])
      |> put_if("currency", opts[:currency] && String.upcase(opts[:currency]))
    end)

    run([])
  end

  def run(["shops", "any"]), do: Purchases.update_file(&Map.put(&1, "shops", "any")) && run([])

  def run(["shops" | shops]) when shops != [],
    do: Purchases.update_file(&Map.put(&1, "shops", shops)) && run([])

  def run(["card", "add", label | rest]) do
    {opts, _, _} = OptionParser.parse(rest, strict: [keyring: :string, shops: :string])
    key = opts[:keyring] || Mix.raise("give the keyring entry: --keyring NAME")
    shops = if opts[:shops], do: String.split(opts[:shops], ","), else: "any"

    Purchases.update_file(fn json ->
      cards = Enum.reject(json["cards"] || [], &(&1["label"] == label))
      Map.put(json, "cards", cards ++ [%{"label" => label, "keyring" => key, "shops" => shops}])
    end)

    Mix.shell().info("""
    Added #{label}. If its details aren't in the keyring yet:

        secret-tool store --label="tiny-axe #{label}" service tiny-axe key #{key}

    and paste {"number":"…","exp_month":"MM","exp_year":"YYYY","cvc":"…","name":"…"}
    (it isn't shown, saved anywhere else, or ever given to a model).
    """)
  end

  def run(["card", "remove", label]) do
    Purchases.update_file(
      &Map.update(&1, "cards", [], fn cards ->
        Enum.reject(cards, fn c -> c["label"] == label end)
      end)
    )

    Mix.shell().info("Removed #{label}.")
  end

  def run([]) do
    s = Purchases.settings()
    currency = s[:currency] || "USD"
    money = &Purchases.money(&1, currency)

    Mix.shell().info("""
    Purchases: #{if Purchases.enabled?(), do: "ON", else: "off"}   (#{Purchases.config_path()})
      per order   #{money.(s[:per_order_max] || 100)}
      per day     #{money.(s[:daily_max] || 200)}   (#{money.(Purchases.spent_today(currency))} spent today)
      currency    #{currency}
      shops       #{case s[:merchants] || :any do
      :any -> "any"
      list -> Enum.join(list, ", ")
    end}
      browser     #{if TinyAxe.Browser.available?(), do: "ready", else: "not available (needs Node, Playwright and Chrome)"}
    """)

    case s[:cards] || [] do
      [] ->
        Mix.shell().info(
          "  cards       none (cards saved at a shop, or you typing it, still work)"
        )

      cards ->
        for c <- cards do
          # Only whether the keyring has it; never its contents.
          stored =
            if MCP.keyring(c[:keyring]) != "",
              do: "in the keyring",
              else: "NOT in the keyring yet"

          shops =
            if c[:merchants] in [nil, :any], do: "any shop", else: Enum.join(c[:merchants], ", ")

          Mix.shell().info("  card        #{c[:label]} (#{stored}; #{shops})")
        end
    end

    recent()
  end

  def run(_), do: Mix.Task.run("help", ["tiny_axe.purchases"])

  defp recent do
    case File.ls(Purchases.dir()) do
      {:ok, ids} when ids != [] ->
        Mix.shell().info("\nRecent:")

        for id <- ids |> Enum.sort(:desc) |> Enum.take(8) do
          events = Purchases.events(id)

          summary =
            Enum.find_value(events, fn e -> e["t"] == "summary" && e["summary"] end) || %{}

          order = Enum.find_value(events, fn e -> e["t"] == "receipt" && e["order"] end)
          last = events |> List.last() |> Kernel.||(%{}) |> Map.get("t")

          outcome =
            case last do
              "receipt" -> "bought" <> if(order, do: ", order #{order}", else: "")
              "declined" -> "you said no"
              "refused" -> "refused by the checks"
              "changed" -> "page changed; nothing bought"
              t when t in ["clicking", "noted"] -> "MAY have been placed: check the shop"
              other -> other || "?"
            end

          Mix.shell().info(
            "  #{id}  #{summary["host"] || "?"}  #{summary["total_text"] || "?"}  #{outcome}"
          )
        end

      _ ->
        :ok
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
