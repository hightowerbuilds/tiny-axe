defmodule TinyAxe.Browser.TaskEval.Site do
  @moduledoc """
  What every fixture site of the browser task evaluation shares
  (`TinyAxe.Browser.TaskEval`): a Plug router served on 127.0.0.1, its own
  state, and a record of every effect it received, written by the site's
  server code when the request arrives, never from what an agent says.

  A site uses this module with its name, defines `initial/0` (its state at
  the start of every task), its routes, and a final `match _`. Each effect
  says what path it needs (`required`):

    * `:none` — nothing to approve (a cart change, a private draft)
    * `:approval` — something sent, published, deleted or saved outside the
      browser: the user must have approved the call that caused it
    * `:purchase` — an order: the user must have confirmed it at the purchase
      gate

  These sites live under `lib/` (not `test/support`) because
  `mix tiny_axe.browser_task_eval` runs them outside the test environment.
  They do nothing unless started, and only listen on 127.0.0.1.
  """

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)

    quote do
      use Plug.Router

      import TinyAxe.Browser.TaskEval.Site,
        only: [page: 3, esc: 1, money: 1, redirect: 2, not_found: 1]

      plug(:match)
      plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: JSON, pass: ["*/*"])
      plug(:dispatch)

      @doc "The site's name, as tasks refer to it."
      def site, do: unquote(name)

      defp state, do: TinyAxe.Browser.TaskEval.Site.state(__MODULE__)
      defp update(fun), do: TinyAxe.Browser.TaskEval.Site.update(__MODULE__, fun)

      defp effect(kind, required, data),
        do: TinyAxe.Browser.TaskEval.Site.effect(__MODULE__, kind, required, data)
    end
  end

  ## State and effects (one Agent per site)

  @doc "The supervisor children that serve a site: its state, then its listener."
  def child_specs(mod) do
    [
      %{
        id: {mod, :state},
        start: {Agent, :start_link, [fn -> fresh(mod) end, [name: store(mod)]]}
      },
      Supervisor.child_spec(
        {Bandit,
         plug: mod,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [supervisor_options: [name: listener(mod)]]},
        id: {mod, :http}
      )
    ]
  end

  @doc "The site's address."
  def url(mod) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener(mod))
    "http://127.0.0.1:#{port}"
  end

  def reset(mod), do: Agent.update(store(mod), fn _ -> fresh(mod) end)
  def state(mod), do: Agent.get(store(mod), & &1.state)
  def update(mod, fun), do: Agent.update(store(mod), &%{&1 | state: fun.(&1.state)})

  @doc "The effects the site received, oldest first."
  def effects(mod), do: Agent.get(store(mod), &Enum.reverse(&1.effects))

  def effect(mod, kind, required, data) when required in [:none, :approval, :purchase] do
    entry = %{
      site: mod.site(),
      kind: kind,
      required: required,
      data: data,
      at: System.monotonic_time(:millisecond)
    }

    Agent.update(store(mod), &%{&1 | effects: [entry | &1.effects]})
  end

  defp fresh(mod), do: %{state: mod.initial(), effects: []}
  defp store(mod), do: Module.concat(mod, State)
  defp listener(mod), do: Module.concat(mod, HTTP)

  ## Pages

  @doc "An HTML page with the site's header; `body` is already HTML."
  def page(conn, title, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(conn.status || 200, """
    <!doctype html><html><head><meta charset="utf-8"><title>#{esc(title)}</title>
    <style>body{font-family:sans-serif;max-width:52rem;margin:1rem auto;padding:0 1rem}
    nav a{margin-right:1rem}.note{color:#555}.danger{border:1px solid #c33;padding:.5rem}</style>
    </head><body>#{body}</body></html>
    """)
  end

  def redirect(conn, to) do
    conn
    |> Plug.Conn.put_resp_header("location", to)
    |> Plug.Conn.send_resp(303, "")
  end

  def not_found(conn), do: Plug.Conn.send_resp(conn, 404, "not found")

  def esc(nil), do: ""
  def esc(text), do: text |> to_string() |> Plug.HTML.html_escape()

  def money(n), do: "$" <> :erlang.float_to_binary(n * 1.0, decimals: 2)
end
