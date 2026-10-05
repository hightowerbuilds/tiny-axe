defmodule TinyAxe.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Before the TUI takes over the terminal: make sure Ollama is up.
    if Application.get_env(:tiny_axe, :start_tui, false), do: prepare_ollama()

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
        # Counts calls that leave the machine and keeps the subscriptions' usage.
        TinyAxe.Escalation,
        # The user's MCP servers, one supervised connection each (TinyAxe.MCP).
        {Registry, keys: :unique, name: TinyAxe.MCP.Registry},
        {DynamicSupervisor, name: TinyAxe.MCP.Supervisor, strategy: :one_for_one},
        # The tool gate, and its MCP endpoint on 127.0.0.1 (a port the OS picks).
        TinyAxe.Tools.Gate,
        {Bandit,
         plug: TinyAxe.Tools.GatePlug,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         thousand_island_options: [supervisor_options: [name: TinyAxe.Tools.GateHTTP]]},
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

    result = Supervisor.start_link(children, strategy: :one_for_one, name: TinyAxe.Supervisor)

    # Connecting to MCP servers can take a while; the TUI doesn't wait for it.
    if Application.get_env(:tiny_axe, :start_tui, false),
      do:
        Task.start(fn ->
          TinyAxe.MCP.start_configured()
          if TinyAxe.Browser.available?(), do: TinyAxe.Browser.start()
        end)

    result
  end

  # Starts Ollama if it isn't running, and checks the model is downloaded. What
  # happened is left in :startup_notes for the TUI to show once it's open.
  defp prepare_ollama do
    url = Application.get_env(:tiny_axe, :ollama_url, "http://localhost:11434")

    unless TinyAxe.OllamaServer.up?(url),
      do: IO.puts(:stderr, "tiny-axe: Ollama isn't running, so starting it…")

    notes =
      case TinyAxe.OllamaServer.ensure_running() do
        {:ok, :already_running} ->
          model_notes(url)

        {:ok, {:started, how, ms}} ->
          [
            "Ollama wasn't running, so tiny-axe started it (#{how}, ready in #{Float.round(ms / 1000, 1)}s)"
            | model_notes(url)
          ]

        {:error, reason} ->
          IO.puts(:stderr, "tiny-axe: #{reason}")
          ["✗ #{reason}. Requests will fail until Ollama is running (try `ollama serve`)."]
      end

    # Orders that may have gone through while tiny-axe wasn't watching.
    notes = notes ++ TinyAxe.Purchases.uncertain()

    Application.put_env(:tiny_axe, :startup_notes, notes)
  end

  defp model_notes(url) do
    models =
      [Application.get_env(:tiny_axe, :model), Application.get_env(:tiny_axe, :decider_model)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    for model <- models,
        TinyAxe.OllamaServer.has_model?(url, model) == false,
        do: "✗ the model #{model} isn't downloaded; run `ollama pull #{model}`"
  end
end
