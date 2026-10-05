defmodule TinyAxe.FixtureSite do
  @moduledoc """
  A small website served on 127.0.0.1 for browser tests, so no test touches
  the real web. `start/0` returns its base URL.

    * `/article` — an article
    * `/js` — text that only appears once JavaScript runs
    * `/checkout` — card, CVC and password fields already filled in, a card
      number in plain text, and a line showing how long the card field's value
      is (so a test can tell its value was put back after a snapshot)
    * `/console` — writes to the console
    * `/contact` — a form that POSTs; `/search` — a form that GETs results
    * `/shop` — "Add to cart" (on the page only), "Buy now" (records a
      purchase), and an unlabelled button that records a click
    * `/login` — a sign-in form with a password field
    * `/dialog` — a button that asks "Clear everything?" before recording
    * `/exfil` — a link whose address carries a long query string
    * `/order?item=…` — a checkout: items, shipping, an order total that
      follows `set_price/1` (checked every 200 ms), where it ships, the card as
      shown, and "Place order", which POSTs `/place-order` and shows an order
      number
    * `/order-saved` — the same, paying with one of two cards saved at the
      shop (radio buttons; the second is chosen)
    * `/order-card` — the same, with empty card fields to fill in; the order
      POST carries them (so a test can see they arrived)

  Everything sent to the site is recorded: `submissions/0`.
  """

  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: JSON, pass: ["*/*"])
  plug(:dispatch)

  def start do
    Agent.start_link(fn -> [] end, name: __MODULE__.Log)
    Agent.start_link(fn -> 12.0 end, name: __MODULE__.Price)

    {:ok, pid} =
      Bandit.start_link(plug: __MODULE__, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  get "/article" do
    html(conn, """
    <title>Volcanoes</title>
    <nav>Home · About</nav>
    <article><h1>Volcanoes</h1>
    <p>A volcano is a rupture in the crust of a planet.</p>
    <p>Mount Etna is one of the most active volcanoes in the world.</p></article>
    """)
  end

  get "/js" do
    html(conn, """
    <title>Widgets</title><body><div id="app">Loading…</div>
    <script>setTimeout(() => {
      document.getElementById("app").innerHTML =
        "<main><h1>Inventory</h1><p>Rendered by JavaScript: 42 widgets in stock.</p></main>";
    }, 100);</script></body>
    """)
  end

  get "/checkout" do
    html(conn, """
    <title>Checkout</title><main><h1>Checkout</h1>
    <label>Name <input id="name" value="Sam Lee"></label>
    <label>Card number <input id="card" autocomplete="cc-number" value="4242 4242 4242 4242"></label>
    <label>CVC <input name="cvc" value="123"></label>
    <label>Password <input type="password" value="hunter2"></label>
    <p>Card on file: 4000 0566 5566 5556. Order number 1234567890.</p>
    <p id="len">card field length: ?</p>
    <button>Place order</button></main>
    <script>setInterval(() => {
      document.getElementById("len").textContent =
        "card field length: " + document.getElementById("card").value.length;
    }, 50);</script>
    """)
  end

  get "/console" do
    html(conn, """
    <title>Console</title><p>Logging.</p>
    <script>console.log("hello from the page"); console.error("something broke");</script>
    """)
  end

  @doc "What was sent to the site, oldest first: `{path, params}`."
  def submissions, do: Agent.get(__MODULE__.Log, &Enum.reverse/1)
  def clear, do: Agent.update(__MODULE__.Log, fn _ -> [] end)

  defp record(conn), do: Agent.update(__MODULE__.Log, &[{conn.request_path, conn.params} | &1])

  get "/contact" do
    html(conn, """
    <title>Contact</title><main><form method="post" action="/contact" aria-label="Contact us">
    <h2>Contact us</h2>
    <label>Your name <input name="name"></label>
    <label>Message <textarea name="message"></textarea></label>
    <button>Send message</button></form></main>
    """)
  end

  post "/contact" do
    record(conn)
    html(conn, "<title>Thanks</title><main><h1>Thanks, #{conn.params["name"]}</h1></main>")
  end

  get "/search" do
    html(conn, """
    <title>Search</title><main><form method="get" action="/results">
    <label>Search <input name="q"></label><button>Search</button></form></main>
    """)
  end

  get "/results" do
    html(conn, "<title>Results</title><main><h1>Results for #{conn.params["q"]}</h1></main>")
  end

  get "/shop" do
    html(conn, """
    <title>Shop</title><main><h1>Blue mug</h1><p>$12.00</p>
    <p id="cart">Cart: 0</p>
    <button id="add" onclick="document.getElementById('cart').textContent='Cart: ' + (++window.n || (window.n=1))">Add to cart</button>
    <button onclick="fetch('/bought', {method: 'POST'})">Buy now</button>
    <button id="mystery" onclick="fetch('/mystery', {method: 'POST'})">⚙</button>
    </main>
    """)
  end

  post "/bought" do
    record(conn)
    send_resp(conn, 200, "ok")
  end

  post "/mystery" do
    record(conn)
    send_resp(conn, 200, "ok")
  end

  get "/login" do
    html(conn, """
    <title>Sign in</title><main><form method="post" action="/login" aria-label="Sign in">
    <label>Username <input name="user"></label>
    <label>Password <input type="password" name="pass"></label>
    <button>Sign in</button></form></main>
    """)
  end

  post "/login" do
    record(conn)
    html(conn, "<title>Signed in</title><main><h1>Welcome</h1></main>")
  end

  get "/dialog" do
    html(conn, """
    <title>Dialog</title><main><p id="state">Items: 3</p>
    <button onclick="if (confirm('Clear everything?')) { fetch('/cleared', {method: 'POST'}); document.getElementById('state').textContent = 'Items: 0'; }">Tidy</button>
    </main>
    """)
  end

  post "/cleared" do
    record(conn)
    send_resp(conn, 200, "ok")
  end

  @doc "The mug's price on `/order` (shipping is $4.00 on top)."
  def set_price(price), do: Agent.update(__MODULE__.Price, fn _ -> price end)

  defp total, do: Agent.get(__MODULE__.Price, & &1) + 4.0
  defp dollars(n), do: "$" <> :erlang.float_to_binary(n * 1.0, decimals: 2)

  get "/order" do
    item = conn.params["item"] || "Blue mug"
    price = Agent.get(__MODULE__.Price, & &1)

    html(conn, """
    <title>Checkout</title><main><h1>Review your order</h1>
    <p>#{item} × 1 — <span id="price">#{dollars(price)}</span></p>
    <p>Shipping: $4.00</p>
    <p>Order total: <span id="total">#{dollars(price + 4.0)}</span></p>
    <p>Ship to:</p><p>Sam Lee</p><p>1 High St, Springfield</p>
    <p>Paying with Visa ending in 4242</p>
    <form method="post" action="/place-order"><button>Place order</button></form></main>
    <script>setInterval(() => fetch('/price').then(r => r.text()).then(t => {
      document.getElementById('total').textContent = t;
    }), 200);</script>
    """)
  end

  get "/order-saved" do
    price = Agent.get(__MODULE__.Price, & &1)

    html(conn, """
    <title>Checkout</title><main><h1>Review your order</h1>
    <p>Blue mug × 1 — #{dollars(price)}</p><p>Shipping: $4.00</p>
    <p>Order total: #{dollars(price + 4.0)}</p>
    <p>Ship to:</p><p>Sam Lee</p><p>1 High St, Springfield</p>
    <form method="post" action="/place-order"><fieldset><legend>Payment</legend>
    <label><input type="radio" name="card" value="visa"> Visa ending in 4242</label>
    <label><input type="radio" name="card" value="mc" checked> Mastercard ending in 5555</label>
    </fieldset><button>Place order</button></form></main>
    """)
  end

  get "/order-card" do
    price = Agent.get(__MODULE__.Price, & &1)

    html(conn, """
    <title>Checkout</title><main><h1>Review your order</h1>
    <p>Blue mug × 1 — #{dollars(price)}</p><p>Shipping: $4.00</p>
    <p>Order total: #{dollars(price + 4.0)}</p>
    <p>Ship to:</p><p>Sam Lee</p><p>1 High St, Springfield</p>
    <form method="post" action="/place-order"><h2>Card details</h2>
    <label>Name on card <input name="ccname" autocomplete="cc-name"></label>
    <label>Card number <input name="ccnumber" autocomplete="cc-number"></label>
    <label>Expiry <input name="ccexp" autocomplete="cc-exp" placeholder="MM/YY"></label>
    <label>CVC <input name="cvc" autocomplete="cc-csc"></label>
    <button>Place order</button></form></main>
    """)
  end

  get "/price" do
    send_resp(conn, 200, dollars(total()))
  end

  post "/place-order" do
    record(conn)

    html(
      conn,
      "<title>Thanks</title><main><h1>Thank you!</h1><p>Your order was placed. Order number: TA-1001</p></main>"
    )
  end

  get "/exfil" do
    data = String.duplicate("secret", 50)

    html(
      conn,
      ~s(<title>Exfil</title><main><a href="/collect?data=#{data}">Continue reading</a></main>)
    )
  end

  get "/collect" do
    record(conn)
    html(conn, "<title>Collected</title><main>ok</main>")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp html(conn, body) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      "<!doctype html><html><head><meta charset=utf-8></head>" <> body <> "</html>"
    )
  end
end
