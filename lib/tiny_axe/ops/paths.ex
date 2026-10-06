defmodule TinyAxe.Ops.Paths do
  @moduledoc """
  Path resolution, display, and mutation boundaries shared by planning and execution.
  Checks are evaluated against the current location each time; changing folders
  never makes a hidden home-directory path writable.
  """

  alias TinyAxe.Files

  @doc "Where file operations may happen, besides the project: `config :tiny_axe, :fs_root`, or home."
  @spec root() :: String.t()
  def root, do: Path.expand(Application.get_env(:tiny_axe, :fs_root) || System.user_home!())

  @doc """
  Resolves a path the user or model gave: `~` means `root/0` (the home folder,
  unless configured otherwise, as tests do), and relative paths are relative
  to the current folder (`TinyAxe.Location`).
  """
  @spec resolve(String.t()) :: String.t()
  def resolve(path), do: TinyAxe.Location.resolve(path)

  @doc "Whether operations may change `abs`: inside the root or project, and not hidden there."
  @spec changeable?(String.t()) :: boolean()
  def changeable?(abs) do
    abs = Path.expand(abs)
    (inside?(abs, root()) or inside?(abs, Files.root())) and not hidden?(abs)
  end

  @doc """
  Whether a path is, or is inside, a hidden folder. Measured from the home
  folder whatever the current folder is, so `cd ~/.config` can't make
  `~/.config/app` look ordinary (outside home, from the project).
  """
  @spec hidden?(String.t()) :: boolean()
  def hidden?(abs) do
    abs = Path.expand(abs)
    base = if abs == root() or inside?(abs, root()), do: root(), else: Files.root()

    abs
    |> Path.relative_to(base)
    |> Path.split()
    |> Enum.any?(&String.starts_with?(&1, "."))
  end

  @doc "Whether an expanded absolute path is strictly below an expanded boundary."
  @spec inside?(String.t(), String.t()) :: boolean()
  def inside?(abs, base), do: abs != base and String.starts_with?(abs, base <> "/")

  @doc "A path as the user would write it: `~/…` under `root/0`."
  @spec show(String.t()) :: String.t()
  def show(abs) do
    home = root()

    if abs == home or String.starts_with?(abs, home <> "/"),
      do: "~" <> String.replace_prefix(abs, home, ""),
      else: abs
  end
end
