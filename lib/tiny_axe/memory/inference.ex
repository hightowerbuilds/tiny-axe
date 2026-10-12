defmodule TinyAxe.Memory.Inference do
  @moduledoc "Foreground work interrupts this app's background memory inference."
  use GenServer

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, nil, name: Keyword.get(opts, :name, __MODULE__))

  def foreground(fun, server \\ __MODULE__) do
    # Also usable by standalone scripts without the application supervisor.
    if GenServer.whereis(server) do
      ref = GenServer.call(server, :foreground, :infinity)

      try do
        fun.()
      after
        if GenServer.whereis(server), do: GenServer.cast(server, {:release, ref})
      end
    else
      fun.()
    end
  end

  def background(server \\ __MODULE__), do: GenServer.call(server, :background)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, %{foreground: %{}, background: nil}}
  end

  @impl true
  def handle_call(:foreground, {pid, _}, s) do
    if s.background, do: Process.exit(elem(s.background, 1), :kill)
    ref = Process.monitor(pid)
    {:reply, ref, %{s | foreground: Map.put(s.foreground, ref, pid)}}
  end

  def handle_call(:background, {pid, _}, %{foreground: fg, background: nil} = s)
      when map_size(fg) == 0 do
    # A coordinator crash must stop its inference task as well.
    Process.link(pid)
    ref = Process.monitor(pid)
    {:reply, :ok, %{s | background: {ref, pid}}}
  end

  def handle_call(:background, _, s), do: {:reply, :busy, s}

  @impl true
  def handle_cast({:release, ref}, s) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{s | foreground: Map.delete(s.foreground, ref)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, s) do
    bg =
      case s.background do
        {^ref, _} -> nil
        other -> other
      end

    {:noreply, %{s | foreground: Map.delete(s.foreground, ref), background: bg}}
  end

  def handle_info({:EXIT, _, _}, s), do: {:noreply, s}

  @impl true
  def terminate(_, s) do
    if s.background, do: Process.exit(elem(s.background, 1), :kill)
    :ok
  end
end
