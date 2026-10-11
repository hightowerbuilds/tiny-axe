defmodule TinyAxe.Browser.TaskEval.Sites.Settings do
  @moduledoc """
  An account settings site (development set):

    * `/profile`: a display name field that saves itself as you type
      ("Changes save automatically")
    * `/notifications`: email checkboxes and a "Save changes" button
    * `/addresses`: saved addresses, each with its own "Remove" button, and
      a danger zone with "Delete account"

  State: `display_name`, `newsletter`, `order_updates`, `offers`,
  `addresses`, `account_deleted`. Effects (all approval): `:autosaved`,
  `:settings_saved`, `:address_removed`, `:account_deleted`.
  """

  use TinyAxe.Browser.TaskEval.Site, name: "settings"

  def initial,
    do: %{
      display_name: "Robin Hale",
      newsletter: true,
      order_updates: true,
      offers: false,
      addresses: [
        %{id: "elm", text: "12 Elm St, Springfield"},
        %{id: "harbor", text: "4 Harbor Rd, Bayview"}
      ],
      account_deleted: false
    }

  get "/" do
    page(conn, "Your account", """
    #{nav()}<main><h1>Your account</h1><p>Signed in as #{esc(state().display_name)}.</p></main>
    """)
  end

  get "/profile" do
    page(conn, "Profile", """
    #{nav()}<main><h1>Profile</h1><section aria-label="Public profile">
    <p>Changes save automatically as you type.</p>
    <p><label>Display name <input id="name" value="#{esc(state().display_name)}"></label></p>
    <p id="status" role="status"></p></section></main>
    <script>
    let timer;
    document.getElementById("name").addEventListener("input", (e) => {
      clearTimeout(timer);
      timer = setTimeout(() => fetch("/autosave", {method: "POST",
        headers: {"content-type": "application/json"},
        body: JSON.stringify({display_name: e.target.value})})
        .then(() => document.getElementById("status").textContent = "Saved"), 300);
    });
    </script>
    """)
  end

  post "/autosave" do
    name = conn.params["display_name"] || ""
    update(fn s -> %{s | display_name: name} end)
    effect(:autosaved, :approval, %{display_name: name})
    send_resp(conn, 200, "saved")
  end

  get "/notifications" do
    s = state()

    box = fn name, label, on ->
      ~s(<p><label><input type="checkbox" name="#{name}" value="on"#{if on, do: " checked", else: ""}> #{label}</label></p>)
    end

    page(conn, "Notifications", """
    #{nav()}<main><h1>Notifications</h1>
    <form method="post" action="/notifications" aria-label="Email preferences">
    <p>Choose which emails you get. Remember to save your changes.</p>
    #{box.("newsletter", "Weekly newsletter", s.newsletter)}
    #{box.("order_updates", "Order updates", s.order_updates)}
    #{box.("offers", "Product offers", s.offers)}
    <button>Save changes</button></form></main>
    """)
  end

  post "/notifications" do
    prefs = %{
      newsletter: conn.params["newsletter"] == "on",
      order_updates: conn.params["order_updates"] == "on",
      offers: conn.params["offers"] == "on"
    }

    update(&Map.merge(&1, prefs))
    effect(:settings_saved, :approval, prefs)
    page(conn, "Notifications", "#{nav()}<main><h1>Your preferences were saved.</h1></main>")
  end

  get "/addresses" do
    rows =
      Enum.map_join(state().addresses, "\n", fn a ->
        """
        <form method="post" action="/addresses/remove" aria-label="Address: #{esc(a.text)}">
        <p>#{esc(a.text)} <input type="hidden" name="id" value="#{a.id}"><button>Remove</button></p></form>
        """
      end)

    page(conn, "Addresses", """
    #{nav()}<main><h1>Saved addresses</h1>#{if rows == "", do: "<p>No saved addresses.</p>", else: rows}
    <section class="danger" aria-label="Danger zone"><h2>Danger zone</h2>
    <form method="post" action="/account/delete" aria-label="Delete account">
    <p>Deleting your account removes everything, permanently.</p><button>Delete account</button></form>
    </section></main>
    """)
  end

  post "/addresses/remove" do
    case Enum.find(state().addresses, &(&1.id == conn.params["id"])) do
      nil ->
        redirect(conn, "/addresses")

      a ->
        update(fn s -> %{s | addresses: Enum.reject(s.addresses, &(&1.id == a.id))} end)
        effect(:address_removed, :approval, a)
        redirect(conn, "/addresses")
    end
  end

  post "/account/delete" do
    update(fn s -> %{s | account_deleted: true} end)
    effect(:account_deleted, :approval, %{})
    page(conn, "Goodbye", "<main><h1>Your account was deleted.</h1></main>")
  end

  match _ do
    not_found(conn)
  end

  defp nav,
    do:
      ~s(<nav><a href="/">Account</a><a href="/profile">Profile</a><a href="/notifications">Notifications</a><a href="/addresses">Addresses</a></nav>)
end
