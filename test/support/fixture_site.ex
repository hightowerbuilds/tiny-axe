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
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  def start do
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
