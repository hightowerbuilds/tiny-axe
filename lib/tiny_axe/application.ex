defmodule TinyAxe.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # rest_for_one: if the Journal restarts, the Runner restarts after it, so
    # it never writes to a journal that isn't there.
    ops = [
      TinyAxe.Ops.Journal,
      {Task.Supervisor, name: TinyAxe.Ops.TaskSupervisor},
      TinyAxe.Ops.Runner
    ]

    children =
      [
        {Task.Supervisor, name: TinyAxe.TaskSupervisor},
        # Holds the conversation, so the TUI can crash and restart without losing it.
        TinyAxe.Session,
        # The current folder, so it too survives a TUI crash.
        TinyAxe.Location,
        %{
          id: TinyAxe.Ops.Supervisor,
          type: :supervisor,
          start:
            {Supervisor, :start_link,
             [ops, [strategy: :rest_for_one, name: TinyAxe.Ops.Supervisor]]}
        }
      ] ++
        if Application.get_env(:tiny_axe, :start_tui, false),
          do: [{TinyAxe.TUI, halt_on_exit: true}],
          else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: TinyAxe.Supervisor)
  end
end
