defmodule TinyAxe.Clipboard do
  @moduledoc """
  Copies text to the system clipboard with `wl-copy` (Wayland), `xclip` or
  `xsel`, whichever is available.
  """

  @spec copy(String.t()) :: :ok | {:error, term()}
  def copy(text) do
    case tool() do
      nil ->
        {:error, :no_clipboard_tool}

      command ->
        tmp = Path.join(System.tmp_dir!(), "tiny_axe_clip_#{System.unique_integer([:positive])}")
        File.write!(tmp, text)

        try do
          # These tools stay running in the background to serve the clipboard;
          # with their output sent to /dev/null, System.cmd doesn't wait for them.
          case System.cmd("sh", ["-c", ~s(#{command} < "$1" > /dev/null 2>&1), "sh", tmp]) do
            {_, 0} -> :ok
            {_, status} -> {:error, {:exit, status}}
          end
        after
          File.rm(tmp)
        end
    end
  end

  defp tool do
    cond do
      System.get_env("WAYLAND_DISPLAY") && System.find_executable("wl-copy") -> "wl-copy"
      System.find_executable("xclip") -> "xclip -selection clipboard"
      System.find_executable("xsel") -> "xsel --clipboard --input"
      true -> nil
    end
  end
end
