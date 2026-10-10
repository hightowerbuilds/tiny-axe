defmodule TinyAxe.Browser.TaskEval.ScriptedDriver do
  @moduledoc """
  Plays a task's written steps through the gate, over HTTP with the task's
  token, the way an agent's MCP client would; no model is involved. Offline
  runs (`--driver scripted`) and the harness's tests use it, so the gate,
  the browser, the fixture sites and the scoring all run for real.

  Steps (`site` is a fixture site's name; elements are found by role and
  name in a fresh snapshot, then named by their ref):

      {:go, site, path}
      {:click, role, name}                 # or {:click, role, name, nth}, counting from 1
      {:type, role, name, text}            # or {:type, role, name, text, :submit}, or nth
      {:select, name, value}               # a combobox
      {:dialog, accept?}
      {:wait, ms}
      {:post, site, path, params}          # straight to the site, past the gate (tests only)
      {:verify, claim}                     # browser_verify on the latest action that sent something
      {:say, text}                         # the final reply

  Returns `{:ok, reply}`, or `{:error, why}` when a step can't be done (an
  element isn't there); a refused call is not an error, just its result.
  """

  @spec run([tuple()], map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(steps, ctx) do
    steps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, ""}, fn {step, n}, {:ok, said} ->
      case step(step, ctx) do
        :ok -> {:cont, {:ok, said}}
        {:say, text} -> {:cont, {:ok, text}}
        {:error, why} -> {:halt, {:error, "step #{n} #{inspect(step)}: #{why}"}}
      end
    end)
  end

  defp step({:go, site, path}, ctx),
    do: call(ctx, "browser_navigate", %{url: ctx.urls[site] <> path})

  defp step({:click, role, name}, ctx), do: step({:click, role, name, 1}, ctx)

  defp step({:click, role, name, nth}, ctx) do
    with {:ok, ref} <- ref(ctx, role, name, nth),
         do: call(ctx, "browser_click", %{ref: ref, element: name})
  end

  defp step({:type, role, name, text}, ctx) do
    with {:ok, ref} <- ref(ctx, role, name),
         do: call(ctx, "browser_type", %{ref: ref, text: text})
  end

  defp step({:type, role, name, text, nth}, ctx) when is_integer(nth) do
    with {:ok, ref} <- ref(ctx, role, name, nth),
         do: call(ctx, "browser_type", %{ref: ref, text: text})
  end

  defp step({:type, role, name, text, :submit}, ctx) do
    with {:ok, ref} <- ref(ctx, role, name),
         do: call(ctx, "browser_type", %{ref: ref, text: text, submit: true})
  end

  defp step({:select, name, value}, ctx) do
    with {:ok, ref} <- ref(ctx, "combobox", name),
         do: call(ctx, "browser_select_option", %{ref: ref, values: [value]})
  end

  defp step({:dialog, accept}, ctx), do: call(ctx, "browser_handle_dialog", %{accept: accept})

  defp step({:wait, ms}, _ctx) do
    Process.sleep(ms)
    :ok
  end

  defp step({:post, site, path, params}, ctx) do
    Req.post!(ctx.urls[site] <> path, form: params, redirect: false, retry: false)
    :ok
  end

  defp step({:verify, claim}, ctx) do
    case gate(ctx, "browser_verify", %{claimed_outcome: claim}, "") do
      {:ok, _result} -> :ok
      {:error, why} -> {:error, why}
    end
  end

  defp step({:say, text}, _ctx), do: {:say, text}

  # One call through the gate; whatever it returns (refusals too) is its result.
  defp call(ctx, tool, args) do
    case gate(ctx, tool, args) do
      {:ok, _result} -> :ok
      {:error, why} -> {:error, why}
    end
  end

  defp gate(ctx, tool, args, prefix \\ nil) do
    response =
      Req.post(ctx.gate.url,
        json: %{
          jsonrpc: "2.0",
          id: System.unique_integer([:positive]),
          method: "tools/call",
          params: %{name: (prefix || "#{ctx.server}__") <> tool, arguments: args}
        },
        headers: %{"authorization" => "Bearer #{ctx.gate.token}"},
        receive_timeout: 120_000,
        retry: false
      )

    case response do
      {:ok, %{status: 200, body: %{"result" => result}}} -> {:ok, result}
      {:ok, %{status: status}} -> {:error, "the gate answered #{status}"}
      {:error, reason} -> {:error, "the gate couldn't be reached: #{inspect(reason)}"}
    end
  end

  # The element's ref in a fresh snapshot, by role and accessible name (the
  # nth such element, counting from 1).
  defp ref(ctx, role, name, nth \\ 1) do
    with {:ok, result} <- gate(ctx, "browser_snapshot", %{}) do
      snapshot = result["content"] |> Enum.map_join("\n", &(&1["text"] || ""))

      case Regex.scan(~r/#{role} "#{Regex.escape(name)}"[^\n]*\[ref=(\w+)\]/, snapshot) do
        found when length(found) >= nth -> {:ok, found |> Enum.at(nth - 1) |> List.last()}
        _ -> {:error, ~s(no #{role} "#{name}" (number #{nth}\) on the page)}
      end
    end
  end
end
