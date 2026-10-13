defmodule TinyAxe.Desktop.Root do
  @moduledoc """
  Root actions, through one root-owned helper (`priv/root/tiny-axe-root`,
  installed as `/usr/local/bin/tiny-axe-root`) that a sudoers rule lets the
  user run without a password, and nothing else. The user chose its verbs
  (2026-10-12): install and remove packages, a system update, and system
  services; package changes take a snapper snapshot first.

  tiny-axe never installs the helper or touches `/etc` itself: `setup/0`
  writes the two files to tiny-axe's state folder and returns the `sudo`
  commands for the user to run (`mix tiny_axe.os_setup` prints them).

  Before every use, `status/0` checks the installed helper is the one
  shipped (same content), owned by root and not writable by anyone else,
  and that sudo runs it without a password. Arguments are checked here as
  well as in the helper, and the user approves every run (`risk: :ask`).
  """

  @installed "/usr/local/bin/tiny-axe-root"
  @sudoers "/etc/sudoers.d/tiny-axe"
  @timeout :timer.minutes(30)

  @package ~r/^[a-z0-9@_+][a-z0-9@._+-]{0,127}$/
  @unit ~r/^[A-Za-z0-9@_][A-Za-z0-9@._:-]{0,127}$/

  def installed_path, do: Application.get_env(:tiny_axe, :root_helper, @installed)

  # Tests use a stand-in that runs the helper without root (in its dry-run mode).
  defp sudo, do: Application.get_env(:tiny_axe, :sudo, "sudo")

  @doc "The helper as shipped with this tiny-axe."
  def shipped_path, do: Application.app_dir(:tiny_axe, "priv/root/tiny-axe-root")

  @doc """
  `:ready`, or `{:missing, why}` in words for the user, with what to do.
  """
  @spec status() :: :ready | {:missing, String.t()}
  def status do
    path = installed_path()

    owner = Application.get_env(:tiny_axe, :root_helper_owner, 0)

    with {:ok, %File.Stat{uid: ^owner, mode: mode}} <- File.stat(path),
         true <- Bitwise.band(mode, 0o022) == 0 || :writable,
         true <- same_content?(path) || :outdated,
         true <- sudo_ok?(path) || :no_sudo do
      :ready
    else
      {:ok, %File.Stat{}} ->
        {:missing, "#{path} isn't owned by root" <> setup_hint()}

      {:error, _} ->
        {:missing, "the root helper isn't set up" <> setup_hint()}

      :writable ->
        {:missing, "#{path} is writable by others, so tiny-axe won't use it" <> setup_hint()}

      :outdated ->
        {:missing, "the installed root helper differs from this tiny-axe's" <> setup_hint()}

      :no_sudo ->
        {:missing, "sudo asks for a password for the root helper" <> setup_hint()}
    end
  end

  defp setup_hint,
    do: " (`mix tiny_axe.os_setup` in the tiny-axe repo shows the two commands to run)"

  defp same_content?(path) do
    with {:ok, a} <- File.read(path),
         {:ok, b} <- File.read(shipped_path()),
         do: a == b,
         else: (_ -> false)
  end

  defp sudo_ok?(path) do
    case System.cmd(sudo(), ["-n", "-l", path], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "Checks a verb and its arguments: `:ok` or `{:error, why}`."
  @spec check(String.t(), [String.t()]) :: :ok | {:error, String.t()}
  def check(verb, args) do
    case {verb, args} do
      {v, pkgs} when v in ["install", "remove"] and pkgs != [] and length(pkgs) <= 20 ->
        case Enum.reject(pkgs, &Regex.match?(@package, &1)) do
          [] -> :ok
          bad -> {:error, "not package names: #{Enum.join(bad, ", ")}"}
        end

      {"update", []} ->
        :ok

      {"service", [action, unit]} ->
        cond do
          action not in ~w(start stop restart enable disable) ->
            {:error, "not a service action: #{action}"}

          not Regex.match?(@unit, unit) ->
            {:error, "not a unit name: #{unit}"}

          true ->
            :ok
        end

      {"snapshot", [desc]} when is_binary(desc) ->
        :ok

      _ ->
        {:error,
         "the root helper takes: install|remove <packages>, update, service <action> <unit>, snapshot <description>"}
    end
  end

  @doc """
  Runs the helper through `sudo -n` (never a password prompt). Returns
  `{:ok, output}` or `{:error, why}`. Updates can take a while: it's
  stopped after 30 minutes.
  """
  @spec run(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def run(verb, args) do
    with :ok <- check(verb, args),
         :ready <- status() do
      task =
        Task.async(fn ->
          System.cmd(sudo(), ["-n", installed_path(), verb | args], stderr_to_stdout: true)
        end)

      case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {out, 0}} -> {:ok, String.trim(out)}
        {:ok, {out, status}} -> {:error, "the root helper exited #{status}: #{tail(out)}"}
        nil -> {:error, "the root helper was stopped after 30 minutes"}
      end
    else
      {:error, why} -> {:error, why}
      {:missing, why} -> {:error, why}
    end
  end

  defp tail(out), do: out |> String.trim() |> String.slice(-600..-1//1)

  @doc """
  Writes the helper and a sudoers rule for this user to tiny-axe's state
  folder and returns the commands that install them (run by the user).
  """
  @spec setup() :: [String.t()]
  def setup do
    dir = Path.join(TinyAxe.Ops.Journal.state_dir(), "root-setup")
    File.mkdir_p!(dir)
    helper = Path.join(dir, "tiny-axe-root")
    rule = Path.join(dir, "sudoers-tiny-axe")
    user = System.get_env("USER") || "root"
    File.cp!(shipped_path(), helper)

    File.write!(rule, """
    # tiny-axe: lets #{user} run tiny-axe's root helper without a password, and nothing else.
    # The helper checks its own arguments; tiny-axe asks before every run.
    #{user} ALL=(root) NOPASSWD: #{@installed}
    """)

    [
      "sudo install -m 755 -o root -g root #{helper} #{@installed}",
      "sudo visudo -cf #{rule} && sudo install -m 440 -o root -g root #{rule} #{@sudoers}"
    ]
  end
end
