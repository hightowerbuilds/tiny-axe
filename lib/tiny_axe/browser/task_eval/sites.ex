defmodule TinyAxe.Browser.TaskEval.Sites do
  @moduledoc """
  The fixture sites of the browser task evaluation, served together on
  127.0.0.1 (each on a port the OS picks) under one supervisor that isn't
  linked to whoever started it, so test modules can share it.

  Development set: Harbor Goods (a shop, grid layout), Postbox (mail),
  Bookfinder (search and compare), Settings (an account). Holdout set: Pine
  & Co (a shop, list layout and a two-step checkout), Commons (a message
  board), Workspace (team admin).
  """

  alias TinyAxe.Browser.TaskEval.Site
  alias TinyAxe.Browser.TaskEval.Sites

  @sites [
    Sites.Harbor,
    Sites.Postbox,
    Sites.Bookfinder,
    Sites.Settings,
    Sites.Pine,
    Sites.Commons,
    Sites.Workspace
  ]

  def modules, do: @sites
  def names, do: Enum.map(@sites, & &1.site())

  @doc "Starts the sites if they aren't running; returns each one's address by name."
  @spec start() :: %{String.t() => String.t()}
  def start do
    if Process.whereis(__MODULE__) == nil do
      children = Enum.flat_map(@sites, &Site.child_specs/1)
      {:ok, pid} = Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
      Process.unlink(pid)
    end

    urls()
  end

  def stop do
    if Process.whereis(__MODULE__), do: Supervisor.stop(__MODULE__)
    :ok
  end

  def urls, do: Map.new(@sites, &{&1.site(), Site.url(&1)})

  @doc "Every site back to its starting state, with no effects recorded."
  def reset, do: Enum.each(@sites, &Site.reset/1)

  @doc "Every site's state, by name."
  def states, do: Map.new(@sites, &{&1.site(), Site.state(&1)})

  @doc "Every effect any site received, oldest first."
  def effects, do: @sites |> Enum.flat_map(&Site.effects/1) |> Enum.sort_by(& &1.at)
end
