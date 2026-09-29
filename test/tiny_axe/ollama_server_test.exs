defmodule TinyAxe.OllamaServerTest do
  use ExUnit.Case, async: true

  alias TinyAxe.OllamaServer

  # A stand-in Ollama on a random local port: /api/version and /api/tags.
  defp fake_ollama(models \\ ["gemma4:e4b-it-qat"]) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    tags = JSON.encode!(%{models: Enum.map(models, &%{name: &1})})

    pid =
      spawn(fn ->
        serve = fn serve ->
          case :gen_tcp.accept(listen) do
            {:ok, socket} ->
              {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
              body = if request =~ "/api/tags", do: tags, else: ~s({"version":"0.0.0"})

              :gen_tcp.send(
                socket,
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
                  body
              )

              :gen_tcp.close(socket)
              serve.(serve)

            {:error, _} ->
              :ok
          end
        end

        serve.(serve)
      end)

    :gen_tcp.controlling_process(listen, pid)
    on_exit(fn -> :gen_tcp.close(listen) end)
    "http://127.0.0.1:#{port}"
  end

  # A local port nothing is listening on.
  defp closed_port do
    {:ok, s} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(s)
    :gen_tcp.close(s)
    "http://127.0.0.1:#{port}"
  end

  test "an Ollama that already answers is left alone" do
    url = fake_ollama()
    start = fn -> flunk("shouldn't start anything") end
    assert {:ok, :already_running} = OllamaServer.ensure_running(url: url, start: start)
  end

  test "a local Ollama that isn't running is started, then waited for" do
    url = closed_port()
    me = self()
    # The "start" brings up a server on that port, the way `ollama serve` would.
    %URI{port: port} = URI.parse(url)

    start = fn ->
      send(me, :started)

      spawn(fn ->
        {:ok, l} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])
        {:ok, s} = :gen_tcp.accept(l)
        {:ok, _} = :gen_tcp.recv(s, 0, 2_000)
        :gen_tcp.send(s, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}")
        :gen_tcp.close(s)
        Process.sleep(1_000)
      end)

      {:ok, "fake start"}
    end

    assert {:ok, {:started, "fake start", ms}} =
             OllamaServer.ensure_running(url: url, start: start)

    assert_received :started
    assert ms < 5_000
  end

  test "an Ollama that never comes up is reported, not waited on forever" do
    url = closed_port()

    assert {:error, reason} =
             OllamaServer.ensure_running(url: url, start: fn -> {:ok, "noop"} end, wait_ms: 500)

    assert reason =~ "didn't answer within"
  end

  test "an address on another machine is never started" do
    start = fn -> flunk("shouldn't start a remote Ollama") end

    assert {:error, reason} =
             OllamaServer.ensure_running(url: "http://192.0.2.1:11434", start: start)

    assert reason =~ "isn't this machine"
  end

  test "reports whether a model is downloaded" do
    url = fake_ollama(["gemma4:e4b-it-qat", "qwen3.5:4b"])
    assert OllamaServer.has_model?(url, "gemma4:e4b-it-qat")
    refute OllamaServer.has_model?(url, "gemma4:12b-it-qat")
    assert OllamaServer.has_model?(closed_port(), "anything") == :unknown
  end
end
