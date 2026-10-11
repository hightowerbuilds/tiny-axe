defmodule TinyAxe.Vault.Ingest do
  @moduledoc """
  Task journals into the vault's accumulated state (`docs/vault-format.md`,
  "Reading the journals"). Pure apart from reading the journals: the state
  goes in, the state with the new journal lines folded in comes out, and
  `TinyAxe.Vault.Notes` renders it.

  The state is plain JSON data, kept in `.tiny-axe/ingested.json`, so notes
  from tasks whose journals were pruned keep their counts:

      %{"schema" => ..., "tasks" => %{id => task}, "sites" => ..., "pages" => ...,
        "controls" => ..., "paths" => ..., "tools" => ...}

  Each task records how many `calls.jsonl` lines are in (`"lines"`) and
  where its tab was after the last of them (`"tab"`), so a task read while
  still running carries on where it left off. Only what a note shows is kept:
  page keys, never URLs; never `args`, result text, evidence context or
  anything from `purchases/`.
  """

  alias TinyAxe.Vault.Format

  @schema "tiny-axe-vault-state/1"

  @looks ~w(browser_snapshot browser_take_screenshot browser_find browser_extract browser_read
            browser_scroll browser_wait_for browser_console_messages browser_network_requests
            browser_tabs browser_inspect browser_hover browser_show)

  @gates ~w(ran approved denied refused)

  @seen {"first_seen", "last_seen"}
  @reached {"reached_first", "reached_last"}

  def schema, do: @schema

  @doc "A vault state with nothing in it."
  def empty do
    %{
      "schema" => @schema,
      "tasks" => %{},
      "sites" => %{},
      "pages" => %{},
      "controls" => %{},
      "paths" => %{},
      "tools" => %{}
    }
  end

  @doc """
  The folder holding the task folders: `dir/tasks` when there is one (a
  state folder, as the fixture lays it out), otherwise `dir` itself.
  """
  @spec tasks_dir(String.t()) :: String.t()
  def tasks_dir(dir) do
    nested = Path.join(dir, "tasks")
    if File.dir?(nested), do: nested, else: dir
  end

  @doc """
  Folds the journal lines not yet in into `state`: the tasks named in
  `only` (all of them when `nil`), oldest first. Every known task is then
  marked pruned or not by whether its journal is still there.
  """
  @spec run(map(), String.t(), [String.t()] | nil) :: map()
  def run(state, tasks_dir, only \\ nil) do
    ids =
      case File.ls(tasks_dir) do
        {:ok, names} -> Enum.filter(names, &File.dir?(Path.join(tasks_dir, &1)))
        {:error, _} -> []
      end

    ids = if only, do: Enum.filter(ids, &(&1 in only)), else: ids

    state =
      ids
      |> Enum.sort()
      |> Enum.reduce(state, fn id, state -> task(state, id, Path.join(tasks_dir, id)) end)

    if File.dir?(tasks_dir) do
      update_in(state["tasks"], fn tasks ->
        Map.new(tasks, fn {id, t} ->
          {id, Map.put(t, "pruned", not File.dir?(Path.join(tasks_dir, id)))}
        end)
      end)
    else
      state
    end
  end

  ## One task

  defp task(state, id, dir) do
    lines = complete_lines(Path.join(dir, "calls.jsonl"))
    known = state["tasks"][id]

    if known == nil and lines == [] do
      # Nothing happened yet: no note until it calls something.
      state
    else
      t = known || new_task()
      t = Map.merge(t, info(Path.join(dir, "task.json")))
      fresh = Enum.drop(lines, t["lines"])
      decisions = if fresh == [], do: %{}, else: decisions(Path.join(dir, "decisions.jsonl"))

      {state, t} =
        Enum.reduce(fresh, {state, t}, fn line, {state, t} ->
          t = Map.update!(t, "lines", &(&1 + 1))

          case JSON.decode(line) do
            {:ok, %{"tool" => tool} = call} when is_binary(tool) ->
              call(state, t, id, call, decisions)

            _ ->
              {state, t}
          end
        end)

      put_in(state, ["tasks", id], t)
    end
  end

  defp new_task do
    %{
      "lines" => 0,
      "tab" => nil,
      "driver" => nil,
      "objective" => nil,
      "started" => nil,
      "calls" => 0,
      "ran" => 0,
      "approved" => 0,
      "denied" => 0,
      "refused" => 0,
      "sites" => [],
      "steps" => [],
      "pruned" => false
    }
  end

  # Only whole lines: the gate may be writing the last one right now.
  defp complete_lines(path) do
    case File.read(path) do
      {:ok, raw} -> raw |> String.split("\n") |> Enum.drop(-1) |> Enum.reject(&(&1 == ""))
      {:error, _} -> []
    end
  end

  defp decisions(path) do
    for line <- complete_lines(path),
        {:ok, %{"id" => id} = record} <- [JSON.decode(line)],
        is_binary(id),
        into: %{},
        do: {id, record}
  end

  # The driver and the (already redacted) request, when the agent wrote them.
  defp info(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{} = info} <- JSON.decode(raw) do
      for {key, value} <- Map.take(info, ["driver", "objective"]),
          is_binary(value) and value != "",
          into: %{},
          do: {key, value}
    else
      _ -> %{}
    end
  end

  ## One call

  defp call(state, t, task_id, call, decisions) do
    tool = call["tool"]
    {server, name} = split(tool)
    at = if is_binary(call["at"]), do: call["at"]
    date = date(at)
    browser? = server == "browser"
    gate = if is_binary(call["decision"]), do: call["decision"], else: "unrecorded"
    ids = call["decisions"] |> List.wrap() |> Enum.filter(&is_binary/1)
    last = ids |> Enum.map(&decisions[&1]) |> Enum.reject(&is_nil/1) |> List.last()
    reported = if browser?, do: reported_page(call["result"]), else: :none

    t =
      t
      |> Map.update!("calls", &(&1 + 1))
      |> Map.update("started", at, &(&1 || at))
      |> then(&if(gate in @gates, do: Map.update!(&1, gate, fn n -> n + 1 end), else: &1))

    state = touch(state, "tools", tool, date, %{"seen" => 1})

    {state, t} =
      if browser? and name in @looks do
        page =
          case reported do
            {:page, key} -> key
            :none -> t["tab"]
          end

        state = if page, do: page_count(state, page, date, "looked"), else: state
        {state, if(page, do: add_site(t, page), else: t)}
      else
        action(state, t, task_id, call, %{
          tool: tool,
          name: name,
          browser?: browser?,
          date: date,
          gate: gate,
          ids: ids,
          last: last,
          reported: reported
        })
      end

    t =
      case reported do
        {:page, key} -> Map.put(t, "tab", key)
        :none -> t
      end

    {state, t}
  end

  defp action(state, t, task_id, call, c) do
    url = get_in(call, ["args", "url"])
    navigation? = c.browser? and is_binary(url)

    acted =
      cond do
        navigation? -> Format.page_key(url)
        c.browser? -> t["tab"] || target_page(c.last)
        true -> nil
      end

    target = if c.browser? and not navigation? and acted, do: target(c.last)

    {state, subject, kind} =
      cond do
        target ->
          {key, label, role} = control(acted, target)

          state =
            touch(state, "controls", key, c.date, %{"seen" => 1}, %{
              "site" => site_of(acted),
              "page" => acted,
              "role" => role,
              "label" => label
            })

          {state, key, "control"}

        navigation? and acted ->
          {state, acted, "page"}

        true ->
          {state, c.tool, "tool"}
      end

    state = if acted, do: page_count(state, acted, c.date, "seen"), else: state
    t = if acted, do: add_site(t, acted), else: t

    led_to =
      case c.reported do
        {:page, key} when is_binary(key) and key != acted -> key
        _ -> nil
      end

    state = if led_to, do: page_count(state, led_to, c.date, nil), else: state
    t = if led_to, do: add_site(t, led_to), else: t

    answers = answers(c.last)
    class = class(call, c.last)
    key = Enum.join([subject, c.tool, answers, class, c.gate, "unchecked"], "|")

    path = %{
      "subject" => subject,
      "subject_kind" => kind,
      "site" => if(kind == "tool", do: nil, else: site_of(acted)),
      "tool" => c.tool,
      "verb" => String.replace_prefix(c.name, "browser_", ""),
      "answers" => answers,
      "class" => class,
      "gate" => c.gate,
      "outcome" => "unchecked"
    }

    state =
      state
      |> touch(
        "paths",
        key,
        c.date,
        %{"seen" => 1, "errors" => if(call["error"] == true, do: 1, else: 0)},
        path
      )
      |> update_in(["paths", key], fn p ->
        record = c.last || %{}

        p
        |> add_all("reason_codes", strings(record["reason_codes"]))
        |> add_all("models", strings([record["model"]]))
        |> add_all("versions", if(c.last, do: [versions(record)], else: []))
        |> add_all("tasks", [task_id])
        |> add_all("decisions", c.ids)
        |> add_all("led_to", List.wrap(led_to))
      end)

    {state, Map.update!(t, "steps", &(&1 ++ [key]))}
  end

  # A browser result starting `Page: <url>` says where the tab is now.
  defp reported_page("Page: " <> rest) do
    [url | _] = String.split(rest, ~r/\s/, parts: 2)
    {:page, Format.page_key(url)}
  end

  defp reported_page(_), do: :none

  defp target(%{"evidence" => %{"target" => %{} = target}}), do: target
  defp target(_), do: nil

  defp target_page(record) do
    case target(record) do
      %{"page" => page} when is_binary(page) -> Format.page_key(page)
      _ -> nil
    end
  end

  # A control: what the page reported about the element acted on.
  defp control(page, target) do
    role =
      Enum.find([target["role"], target["tag"]], "element", &(is_binary(&1) and &1 != ""))

    text =
      if(is_binary(target["text"]), do: target["text"], else: "")
      |> String.split()
      |> Enum.join(" ")
      |> String.slice(0, 80)
      |> String.trim()

    label = if text == "", do: "(no label)", else: text
    {"#{page}|#{role}|#{String.downcase(text)}", label, role}
  end

  defp answers(nil), do: "rules"

  defp answers(%{"answers" => %{} = answers}) do
    answers
    |> Enum.filter(fn {q, _} -> q =~ ~r/^[A-Za-z0-9_]+$/ end)
    |> Enum.sort()
    |> Enum.map_join(" ", fn {q, a} -> "#{q}=#{Format.bucket(if is_map(a), do: a["p"])}" end)
    |> case do
      "" -> "unanswered"
      answers -> answers
    end
  end

  defp answers(_), do: "unanswered"

  defp class(call, record) do
    cond do
      is_binary(call["class"]) -> call["class"]
      is_map(record) and is_binary(record["disposition"]) -> record["disposition"]
      true -> "unrecorded"
    end
  end

  defp versions(record) do
    ["policy_version", "questions_version", "evidence_schema"]
    |> Enum.map_join(" · ", &if(is_binary(record[&1]), do: record[&1], else: "unrecorded"))
  end

  ## Accumulating

  # Adds `counts` to a note's counts and widens its dates; `fields` are set
  # when the note is new and kept after (a control keeps its first label).
  defp touch(state, group, key, date, counts, fields \\ %{}, span \\ @seen) do
    update_in(state, [group], fn notes ->
      note =
        Map.get_lazy(notes, key, fn ->
          Map.merge(fields, %{"first_seen" => nil, "last_seen" => nil})
        end)

      note =
        Enum.reduce(counts, note, fn {name, n}, note -> Map.update(note, name, n, &(&1 + n)) end)

      Map.put(notes, key, dates(note, date, span))
    end)
  end

  # A page and its site: one more action (`"seen"`) or look (`"looked"`), or
  # (`nil`) only reached as where an action led. Reaching a page makes sure
  # its note is there to link to, but dates it only when nothing else does
  # (`TinyAxe.Vault.Notes`).
  defp page_count(state, page, date, counter) do
    counts = Map.merge(%{"seen" => 0, "looked" => 0}, if(counter, do: %{counter => 1}, else: %{}))
    span = if counter, do: @seen, else: @reached

    state
    |> touch("sites", site_of(page), date, counts, %{}, span)
    |> touch("pages", page, date, counts, %{"site" => site_of(page)}, span)
  end

  defp dates(note, nil, _span), do: note

  defp dates(note, date, {first, last}) do
    note
    |> Map.update(first, date, &if(&1 == nil or date < &1, do: date, else: &1))
    |> Map.update(last, date, &if(&1 == nil or date > &1, do: date, else: &1))
  end

  defp add_site(t, page), do: add_all(t, "sites", [site_of(page)])

  defp add_all(map, name, values),
    do: Map.update(map, name, Enum.sort(Enum.uniq(values)), &Enum.sort(Enum.uniq(&1 ++ values)))

  defp strings(list), do: list |> List.wrap() |> Enum.filter(&(is_binary(&1) and &1 != ""))

  @doc "A page key's site key: everything before the path."
  def site_of(page), do: page |> String.split("/", parts: 2) |> hd()

  @doc "A gate tool name as `{server, tool}`; `nil` server when it has none."
  def split(tool) do
    case String.split(tool, "__", parts: 2) do
      [server, name] when server != "" and name != "" -> {server, name}
      _ -> {nil, tool}
    end
  end

  defp date(nil), do: nil

  defp date(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> dt |> DateTime.to_date() |> Date.to_iso8601()
      _ -> nil
    end
  end
end
