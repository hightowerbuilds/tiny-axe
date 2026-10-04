defmodule TinyAxe.Agent.CodexDriver do
  @moduledoc """
  Codex's agent loop (`codex exec`) on the user's ChatGPT subscription, with
  tiny-axe's gate as its only tools: Codex's own shell, browser, computer use,
  apps and plugins are switched off, and the gate is added as an HTTP MCP
  server whose token Codex reads from an environment variable (Phase 4).

  Codex reports whole messages, not tokens, so its answer arrives at the end.
  It costs about 12k tokens a turn of its own prompt (Phase 3).
  """

  alias TinyAxe.Agent
  alias TinyAxe.Model.{CLI, CodexCLI}

  @spec run(map(), map(), TinyAxe.Model.choice(), (term() -> any())) ::
          {:ok, String.t()} | {:error, term()}
  def run(request, task, {:codex, model}, notify) do
    with :ok <- CodexCLI.ensure_subscription() do
      prompt =
        "Instructions for this task:\n\n#{request.system}\n\n---\n\n#{Agent.prompt_text(request)}"

      t0 = System.monotonic_time(:millisecond)

      result =
        CLI.run(
          exe(),
          args(model, task.url),
          prompt,
          &CodexCLI.handle/2,
          %{text: nil, usage: nil, error: nil},
          timeout: Application.get_env(:tiny_axe, :agent_timeout, :timer.minutes(30)),
          env: [{"TINYAXE_GATE_TOKEN", task.token}]
        )

      :telemetry.execute(
        [:tiny_axe, :model, :call],
        %{ms: System.monotonic_time(:millisecond) - t0},
        %{
          kind: :agent,
          ok: match?({:exited, 0, _, _}, result),
          backend: :codex,
          remote: true
        }
      )

      case result do
        {:exited, status, acc, noise} ->
          with {:ok, text} <- CodexCLI.outcome(acc, status, noise) do
            notify.({:delta, text})
            {:ok, text}
          end

        {:error, :not_installed} ->
          {:error, {:not_installed, :codex}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  def args(model, url) do
    effort = Application.get_env(:tiny_axe, :agent_effort, "medium")

    ["exec", "-m", model, "-c", ~s(model_reasoning_effort="#{effort}")] ++
      CodexCLI.off_flags() ++
      ["-c", ~s(mcp_servers.tinyaxe.url="#{url}")] ++
      ["-c", ~s(mcp_servers.tinyaxe.bearer_token_env_var="TINYAXE_GATE_TOKEN")] ++
      ~w(--ephemeral --skip-git-repo-check -s read-only --ignore-rules --json -)
  end

  defp exe, do: Application.get_env(:tiny_axe, :codex_cli, "codex")
end
