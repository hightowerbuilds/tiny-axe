defmodule TinyAxe.Browser.DeadEnds do
  @moduledoc """
  Paths that didn't work, per site (`docs/plan-leash.md`, L3): a browser
  action that failed or couldn't be confirmed is kept here, keyed by the
  site, the page's path (ids and numbers made general), the kind of action
  and the control's label. Jev judges each one: a real dead end (it would
  fail again the same way) or a one-off (a slow network, a page that was
  still loading). Two failures make it a dead end whatever Jev said.

    * **Warned ahead** — when a task first reaches a site, its known dead
      ends are added to what the agent sees (`warning/1`).
    * **Repeats blocked** — an action matching a known dead end that has
      already failed in this task is refused (`blocked?/2`), so the agent
      tries another way.

  Kept in `<state_dir>/dead_ends.json`; an entry not seen for 30 days is
  dropped. Only the harness's own facts go in (the action, the label, the
  page's address, the reason codes): never page text. `mix
  tiny_axe.dead_ends` lists and forgets them.
  """

  use GenServer

  require Logger

  alias TinyAxe.Decider

  @expire_days 30
  @label_chars 80
  @question %{
    dead_end: %{
      type: :noul,
      instructions:
        "A browser action on a shopping or web site failed or couldn't be confirmed. " <>
          "Would the same action on the same page most likely fail again the same way " <>
          "(a real dead end: the control doesn't do what it seems, the site blocks it, " <>
          "the flow needs something else), rather than a one-off problem (a slow " <>
          "network, a page still loading, a lost response)?"
    }
  }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def path, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "dead_ends.json")

  ## What a record says

  @doc "Whether an action record is a failure worth keeping (not a refusal or a no)."
  def failure?(%{status: :unresolved}), do: true
  def failure?(%{status: :failed, codes: codes}), do: codes != ["not_executed"]
  def failure?(_record), do: false

  @doc """
  The key for an action: `host|path|action|label`, from its target (as the
  gate assessed it) and the browser tool; nil when there's no page or label.
  """
  def key(target, browser_tool) when is_map(target) do
    with page when is_binary(page) <- target["page"],
         %URI{host: host, path: path} when is_binary(host) <- URI.parse(page),
         label when is_binary(label) and label != "" <- clean_label(target["text"]) do
      Enum.join([host, general(path || "/"), action(browser_tool), label], "|")
    else
      _ -> nil
    end
  end

  def key(_target, _tool), do: nil

  defp clean_label(nil), do: nil

  defp clean_label(text),
    do: text |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, @label_chars)

  # /dp/B0123ABCD/ref=x and /item/12345 become /dp/:id/ref=x and /item/:id.
  defp general(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn seg ->
      if seg =~ ~r/\d/ and String.length(seg) >= 4, do: ":id", else: seg
    end)
  end

  defp action("browser_click"), do: "click"
  defp action("browser_type"), do: "type"
  defp action("browser_fill_form"), do: "fill"
  defp action("browser_select_option"), do: "select"
  defp action("browser_press_key"), do: "press"
  defp action(other) when is_binary(other), do: String.replace_prefix(other, "browser_", "")
  defp action(_), do: "act"

  ## Keeping them

  @doc "Keeps a failed action (in the background: Jev may take a moment)."
  def add(record) do
    case info(record) do
      nil -> :ok
      info -> GenServer.cast(__MODULE__, {:add, info})
    end
  catch
    :exit, _ -> :ok
  end

  @doc "The same, and waits; `decide` replaces asking Jev (for tests)."
  def add_now(record, opts \\ []) do
    case info(record) do
      nil -> :ok
      info -> keep(info, Keyword.get(opts, :decide, &ask_jev/1))
    end
  end

  defp info(%{target: target, browser_tool: tool} = record) do
    case key(target, tool) do
      nil ->
        nil

      key ->
        %{
          key: key,
          description: record[:description],
          page: target["page"],
          codes: record[:codes] || [],
          status: record[:status]
        }
    end
  end

  defp info(_record), do: nil

  defp keep(info, decide) do
    all = read()
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    old = all[info.key] || %{"failures" => 0, "first" => now}
    failures = old["failures"] + 1

    verdict =
      cond do
        failures >= 2 -> "dead_end"
        decide.(Map.put(info, :failures_before, old["failures"])) -> "dead_end"
        true -> "one_off"
      end

    [host, path, action, label] = String.split(info.key, "|", parts: 4)

    entry =
      Map.merge(old, %{
        "host" => host,
        "path" => path,
        "action" => action,
        "label" => label,
        "description" => info.description,
        "codes" => info.codes,
        "status" => to_string(info.status),
        "failures" => failures,
        "last" => now,
        "verdict" => verdict
      })

    write(Map.put(all, info.key, entry))
    entry
  end

  defp ask_jev(info) do
    state = %{
      action: info.description,
      page: info.page,
      what_happened: Enum.join(info.codes, ", "),
      failed_before_on_this_site: info.failures_before
    }

    Decider.yes?(Decider.decide(state, @question), :dead_end, 0.6)
  catch
    _, _ -> false
  end

  ## Using them

  @doc "This site's known dead ends (Jev's verdict, or two failures), newest first."
  def known(host) when is_binary(host) do
    read()
    |> Map.values()
    |> Enum.filter(&(&1["host"] == host and &1["verdict"] == "dead_end"))
    |> Enum.sort_by(& &1["last"], :desc)
  end

  def known(_host), do: []

  @doc "Whether a key is a known dead end."
  def dead_end?(nil), do: false
  def dead_end?(key), do: match?(%{"verdict" => "dead_end"}, read()[key])

  @doc """
  Whether an action (its key) is refused: a known dead end that already
  failed in this task (`records`, the task's action records).
  """
  def blocked?(nil, _records), do: false

  def blocked?(key, records) do
    dead_end?(key) and
      Enum.any?(records, fn r -> failure?(r) and key(r[:target], r[:browser_tool]) == key end)
  end

  @doc "What the agent is told when it first reaches a site with known dead ends; nil if none."
  def warning(host) do
    case known(host) do
      [] ->
        nil

      ends ->
        lines =
          Enum.map_join(Enum.take(ends, 8), "\n", fn e ->
            times = if e["failures"] == 1, do: "once", else: "#{e["failures"]} times"

            "- #{e["action"]} \"#{e["label"]}\" on #{e["path"]}: didn't work #{times} (#{Enum.join(e["codes"] -- ["outcome_unresolved"], ", ")})"
          end)

        "Known dead ends on #{host}, from earlier tasks (tiny-axe's own record, not the page): " <>
          "these didn't work, so find another way rather than trying them first. Repeating one " <>
          "that fails again in this task is refused.\n" <> lines
    end
  end

  @doc "Every kept path, newest first."
  def list, do: read() |> Map.values() |> Enum.sort_by(& &1["last"], :desc)

  @doc "Forgets a site's paths (`host`), or all of them (`:all`); how many."
  def forget(:all) do
    n = map_size(read())
    write(%{})
    n
  end

  def forget(host) do
    {gone, kept} = read() |> Enum.split_with(fn {_k, e} -> e["host"] == host end)
    write(Map.new(kept))
    length(gone)
  end

  ## The file

  defp read do
    cutoff = DateTime.utc_now() |> DateTime.add(-@expire_days, :day) |> DateTime.to_iso8601()

    with {:ok, raw} <- File.read(path()),
         {:ok, %{"paths" => %{} = paths}} <- JSON.decode(raw) do
      Map.filter(paths, fn {_k, e} -> is_binary(e["last"]) and e["last"] >= cutoff end)
    else
      _ -> %{}
    end
  end

  defp write(paths) do
    File.mkdir_p!(Path.dirname(path()))
    tmp = path() <> ".tmp"
    File.write!(tmp, JSON.encode!(%{"version" => 1, "paths" => paths}))
    File.rename!(tmp, path())
  end

  ## Server: one writer, so two failures never interleave

  @impl true
  def init(:ok), do: {:ok, nil}

  @impl true
  def handle_cast({:add, info}, s) do
    keep(info, &ask_jev/1)
    {:noreply, s}
  rescue
    error ->
      Logger.warning("tiny-axe couldn't keep a dead end: #{inspect(error)}")
      {:noreply, s}
  end
end
