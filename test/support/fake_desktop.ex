defmodule TinyAxe.FakeDesktop do
  @moduledoc """
  Stands in for the desktop's programs in tests (`TinyAxe.Appearance.Runner`),
  so no test changes the real theme, fonts or windows. A test sets a function
  with `script/1`; it gets `(program, args)` and returns `{output, status}`.
  Every call is sent to the test process as `{:desktop, program, args}`.
  Unscripted, every program "fails" with status 1.
  """

  @behaviour TinyAxe.Appearance.Runner

  def script(fun) when is_function(fun, 2) do
    Application.put_env(:tiny_axe, :fake_desktop, {self(), fun})
  end

  def reset, do: Application.delete_env(:tiny_axe, :fake_desktop)

  @impl true
  def cmd(program, args) do
    case Application.get_env(:tiny_axe, :fake_desktop) do
      {owner, fun} ->
        send(owner, {:desktop, program, args})
        fun.(program, args)

      nil ->
        {"", 1}
    end
  end
end
