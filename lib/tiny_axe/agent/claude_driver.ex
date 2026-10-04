defmodule TinyAxe.Agent.ClaudeDriver do
  @moduledoc """
  Claude Code's own agent loop (`claude -p`) on the user's subscription, with
  tiny-axe's gate as its only tools:

    * `--setting-sources local` from an empty folder: no user settings, hooks
      or plugins (`--safe-mode` would also switch off MCP; Phase 3)
    * `--tools ""`: none of Claude Code's own tools
    * `--strict-mcp-config --mcp-config <the gate only>` and
      `--allowedTools mcp__tinyaxe`: the gate's tools, nothing else

  The gate's address and token are in a file only this user can read,
  removed afterwards. Claude's text streams to the TUI as it works; the
  answer is its final message. API keys never reach it, and a run that
  reports any key source but the subscription is stopped (`TinyAxe.Model.CLI`,
  `TinyAxe.Model.ClaudeCLI`).
  """

  alias TinyAxe.Agent
  alias TinyAxe.Model.{ClaudeCLI, CLI}
  alias TinyAxe.Tools.Gate

  @spec run(map(), map(), TinyAxe.Model.choice(), (term() -> any())) ::
          {:ok, String.t()} | {:error, term()}
  def run(request, task, {:claude, model}, notify) do
    config = write_config(task)
    t0 = System.monotonic_time(:millisecond)

    try do
      handle = fn event, acc -> ClaudeCLI.handle(event, acc, &notify.({:delta, &1})) end
      acc = %{text: [], model: nil, result: nil, quota: nil, error: nil}

      result =
        CLI.run(
          exe(),
          args(model, config, request.system),
          Agent.prompt_text(request),
          handle,
          acc,
          timeout: Application.get_env(:tiny_axe, :agent_timeout, :timer.minutes(30)),
          # Longer than the gate waits for the user's approval (10 minutes).
          env: [{"MCP_TOOL_TIMEOUT", "900000"}]
        )

      telemetry(System.monotonic_time(:millisecond) - t0, result)

      case result do
        {:stopped, %{error: error}} ->
          {:error, error}

        {:exited, status, acc, noise} ->
          if acc.quota,
            do:
              :telemetry.execute([:tiny_axe, :model, :quota], %{}, %{
                backend: :claude,
                quota: acc.quota
              })

          ClaudeCLI.outcome(acc, status, noise, nil)

        {:error, :not_installed} ->
          {:error, {:not_installed, :claude}}

        {:error, reason} ->
          {:error, reason}
      end
    after
      File.rm(config)
    end
  end

  @doc false
  def args(model, config, system) do
    ["-p", "--model", model, "--setting-sources", "local", "--tools", ""] ++
      ["--strict-mcp-config", "--mcp-config", config, "--allowedTools", "mcp__tinyaxe"] ++
      [
        "--no-session-persistence",
        "--effort",
        Application.get_env(:tiny_axe, :agent_effort, "medium")
      ] ++
      ["--system-prompt", system] ++
      ~w(--output-format stream-json --include-partial-messages --verbose)
  end

  defp write_config(task) do
    path =
      Path.join(System.tmp_dir!(), "tiny_axe_gate_#{System.unique_integer([:positive])}.json")

    File.write!(path, "")
    File.chmod!(path, 0o600)
    File.write!(path, JSON.encode!(Gate.mcp_config(task)))
    path
  end

  # Counted like every model call that leaves the machine.
  defp telemetry(ms, result) do
    :telemetry.execute([:tiny_axe, :model, :call], %{ms: ms}, %{
      kind: :agent,
      ok: match?({:exited, 0, _, _}, result),
      backend: :claude,
      remote: true
    })
  end

  defp exe, do: Application.get_env(:tiny_axe, :claude_cli, "claude")
end
