defmodule TinyAxe.Usage do
  @moduledoc """
  Token use by Claude Haiku, Jev and the local model (Gemma), for `/token`
  (`docs/plan-token-dashboard.md`).

  Every call reports itself with `emit/6`: a `[:tiny_axe, :usage]` event
  with its tokens (`input`, `output`, `cache_read`, `cache_write`) and what
  it was (`backend`: `:claude`, `:jev` or `:ollama`; `kind`: `:answer`,
  `:agent`, `:subagent`, `:decision`, `:local`; the model; whether it worked;
  how long it took). Never any prompt or answer text, and no prices.

  This process appends each to `<state_dir>/usage.jsonl`, one JSON line per
  call, tagged with this launch's session. The file is the record: totals
  are read back from it (`summary/0` reads only what's new since it last
  looked), so a crash loses at most the call in flight, and every tiny-axe
  open at once counts towards today and the week. At start, lines older than
  90 days are dropped. In memory it keeps the last 8 days.

  "Today" and the hours are local time.
  """

  use GenServer

  require Logger

  @handler "tiny-axe-usage"
  @keep_days 90
  @memory_days 8
  @backends [:claude, :jev, :ollama]
  @kinds ~w(answer agent subagent decision local)a

  @doc """
  Options (for tests): `:name` (default this module), `:path`, `:session`,
  and `listen: false` for a copy that's given calls directly rather than
  hearing everyone's.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Reports one call. `tokens` may have `:input`, `:output`, `:cache_read` and
  `:cache_write` (missing ones count as 0). Safe to call whether or not this
  process is running.
  """
  @spec emit(atom(), atom(), String.t() | nil, map(), boolean(), non_neg_integer()) :: :ok
  def emit(backend, kind, model, tokens, ok, ms) when backend in @backends do
    measurements =
      Map.new([:input, :output, :cache_read, :cache_write], fn k -> {k, count(tokens[k])} end)

    :telemetry.execute([:tiny_axe, :usage], measurements, %{
      backend: backend,
      kind: kind,
      model: model,
      ok: ok == true,
      ms: ms || 0
    })
  end

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_), do: 0

  @doc "Where the record is."
  def path, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "usage.jsonl")

  @doc """
  Totals for this session, today and the last 7 days, by backend; today's
  tokens by local hour, by backend; and Claude's latest usage windows.
  """
  @spec summary(GenServer.server()) :: map()
  def summary(server \\ __MODULE__), do: GenServer.call(server, :summary)

  @doc "The file this process records to (set when it started)."
  def file(server \\ __MODULE__), do: GenServer.call(server, :file)

  ## Server

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, path())

    handler =
      if Keyword.get(opts, :listen, true) do
        id = "#{@handler}-#{inspect(self())}"
        :telemetry.attach(id, [:tiny_axe, :usage], &__MODULE__.handle_telemetry/4, self())
        id
      end

    prune(path)

    {:ok,
     catch_up(%{
       path: path,
       handler: handler,
       offset: 0,
       entries: [],
       session: Keyword.get(opts, :session, session())
     })}
  end

  @impl true
  def terminate(_reason, %{handler: nil}), do: :ok
  def terminate(_reason, state), do: :telemetry.detach(state.handler)

  @doc false
  def handle_telemetry(_event, measurements, meta, server),
    do: GenServer.cast(server, {:record, measurements, meta})

  @impl true
  def handle_cast({:record, m, meta}, state) do
    line =
      JSON.encode!(%{
        at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        session: state.session,
        backend: meta.backend,
        kind: meta.kind,
        model: meta.model,
        ok: meta.ok,
        ms: meta.ms,
        input: m.input,
        output: m.output,
        cache_read: m.cache_read,
        cache_write: m.cache_write
      })

    File.mkdir_p!(Path.dirname(state.path))

    case File.write(state.path, line <> "\n", [:append]) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("tiny-axe usage: not recorded (#{inspect(reason)})")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:file, _from, state), do: {:reply, state.path, state}

  def handle_call(:summary, _from, state) do
    state = catch_up(state)
    {:reply, summarize(state), state}
  end

  ## The record

  # Reads whole lines added since `offset` (other tiny-axe instances' too).
  # A file that's shorter than what was read was replaced: read it afresh.
  defp catch_up(state) do
    state =
      case File.stat(state.path) do
        {:ok, %{size: size}} when size < state.offset -> %{state | offset: 0, entries: []}
        _ -> state
      end

    case File.open(state.path, [:read, :binary]) do
      {:ok, io} ->
        try do
          {:ok, _} = :file.position(io, state.offset)
          data = IO.binread(io, :eof)
          data = if is_binary(data), do: data, else: ""

          case :binary.matches(data, "\n") do
            [] ->
              trim(state)

            matches ->
              {last, 1} = List.last(matches)
              whole = binary_part(data, 0, last + 1)
              new = whole |> String.split("\n", trim: true) |> Enum.flat_map(&decode/1)
              trim(%{state | offset: state.offset + last + 1, entries: state.entries ++ new})
          end
        after
          File.close(io)
        end

      {:error, _} ->
        trim(state)
    end
  end

  defp decode(line) do
    with {:ok, %{"at" => at} = e} <- JSON.decode(line),
         {:ok, time, _} <- DateTime.from_iso8601(at),
         backend when backend != nil <- known(e["backend"], @backends) do
      [
        %{
          at: time,
          session: e["session"],
          backend: backend,
          kind: known(e["kind"], @kinds) || :answer,
          ok: e["ok"] != false,
          input: count(e["input"]),
          output: count(e["output"]),
          cache_read: count(e["cache_read"]),
          cache_write: count(e["cache_write"])
        }
      ]
    else
      _ -> []
    end
  end

  defp known(name, atoms) when is_binary(name),
    do: Enum.find(atoms, &(Atom.to_string(&1) == name))

  defp known(_name, _atoms), do: nil

  defp trim(state) do
    cutoff = DateTime.add(DateTime.utc_now(), -@memory_days * 86_400)
    %{state | entries: Enum.filter(state.entries, &(DateTime.compare(&1.at, cutoff) == :gt))}
  end

  # Lines older than @keep_days go, once at start; the file is rewritten
  # whole (a temporary file, then renamed) only if any did.
  defp prune(path) do
    with {:ok, data} <- File.read(path) do
      cutoff = DateTime.add(DateTime.utc_now(), -@keep_days * 86_400)
      lines = String.split(data, "\n", trim: true)

      kept =
        Enum.filter(lines, fn line ->
          case decode(line) do
            [%{at: at}] -> DateTime.compare(at, cutoff) == :gt
            [] -> false
          end
        end)

      if length(kept) != length(lines) do
        tmp = path <> ".tmp"
        File.write!(tmp, Enum.map(kept, &(&1 <> "\n")))
        File.rename!(tmp, path)
      end
    end

    :ok
  end

  ## Totals

  defp summarize(state) do
    now = DateTime.utc_now()
    week_cutoff = DateTime.add(now, -7 * 86_400)
    today = local_date(now)

    session = Enum.filter(state.entries, &(&1.session == state.session))
    day = Enum.filter(state.entries, &(local_date(&1.at) == today))
    week = Enum.filter(state.entries, &(DateTime.compare(&1.at, week_cutoff) == :gt))

    %{
      session: totals(session),
      today: totals(day),
      week: totals(week),
      hours: hours(day),
      quota: TinyAxe.Escalation.stats().quota[:claude]
    }
  end

  defp totals(entries) do
    Map.new(@backends, fn backend ->
      mine = Enum.filter(entries, &(&1.backend == backend))
      sum = fn key -> mine |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum() end

      {backend,
       %{
         calls: length(mine),
         errors: Enum.count(mine, &(not &1.ok)),
         input: sum.(:input),
         output: sum.(:output),
         cache_read: sum.(:cache_read),
         cache_write: sum.(:cache_write),
         by_kind: mine |> Enum.frequencies_by(& &1.kind)
       }}
    end)
  end

  # Today's tokens (in and out) by local hour, 0..23, for each backend.
  defp hours(day) do
    Map.new(@backends, fn backend ->
      by_hour =
        day
        |> Enum.filter(&(&1.backend == backend))
        |> Enum.group_by(
          &local_hour(&1.at),
          &(&1.input + &1.output + &1.cache_read + &1.cache_write)
        )

      {backend, Enum.map(0..23, &Enum.sum(Map.get(by_hour, &1, [])))}
    end)
  end

  defp local(%DateTime{} = t) do
    t |> DateTime.to_naive() |> NaiveDateTime.to_erl() |> :calendar.universal_time_to_local_time()
  end

  defp local_date(t), do: t |> local() |> elem(0)
  defp local_hour(t), do: t |> local() |> elem(1) |> elem(0)

  defp session do
    TinyAxe.History.session()
  catch
    :exit, _ -> "unknown"
  end
end
