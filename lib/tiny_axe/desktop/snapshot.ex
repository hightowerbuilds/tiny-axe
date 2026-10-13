defmodule TinyAxe.Desktop.Snapshot do
  @moduledoc """
  Recovery points for the desktop's config: a git repository in tiny-axe's
  state folder (`<state_dir>/config-snapshots`) whose work tree is
  `~/.config`, tracking only the desktop's own config folders (`tracked/0`:
  Hyprland, Omarchy, the terminals, editors' and tools' configs, user
  services). Browser profiles, credentials and everything else in
  `~/.config` are never copied in.

  Changes that can touch any file (a command run outside the sandbox, see
  `TinyAxe.Desktop.OsRun`) take one before and one after, and record the
  pair for `/look undo` (`TinyAxe.Desktop.Undo`). Restoring puts each file
  back as it was before, but only if it still holds what the change left
  (a file edited since is left alone and named); a file the change added is
  moved aside into `<state_dir>/config-set-aside/`, never deleted.

  A run that's interrupted (tiny-axe crashed or was killed while it ran) is
  found at the next start (`recover_interrupted/0`) and turned into an undo
  record, so `/look undo` can put things back.
  """

  @tracked ~w(hypr omarchy ghostty alacritty kitty foot btop tmux nvim helix zed fontconfig
              gtk-3.0 gtk-4.0 systemd autostart environment.d wireplumber fcitx5 voxtype
              lazygit mise imv herdr opencode uwsm waybar mako walker swayosd hyprmon starship.toml
              xdg-terminals.list mimeapps.list user-dirs.dirs)

  # Not pulse/: it holds PulseAudio's auth cookie.
  @doc "The folders and files under `~/.config` that snapshots track."
  def tracked, do: @tracked

  def root do
    Application.get_env(:tiny_axe, :desktop, [])
    |> Keyword.get(:config_root, "~/.config")
    |> Path.expand()
  end

  def git_dir, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "config-snapshots")
  defp aside_dir, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "config-set-aside")
  defp runs_dir, do: Path.join(TinyAxe.Ops.Journal.state_dir(), "os-runs")

  @doc "Takes a snapshot: `{:ok, commit}` or `{:error, why}`."
  @spec take(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def take(label) do
    with :ok <- ensure_repo(),
         {:ok, _} <- git(["add", "-A", "."]),
         {:ok, _} <- git(["commit", "-q", "--allow-empty", "--no-verify", "-m", label]),
         {:ok, sha} <- git(["rev-parse", "HEAD"]) do
      {:ok, String.trim(sha)}
    end
  end

  @doc "The tracked files that differ between two snapshots, as `{status, path}`."
  @spec changed(String.t(), String.t()) :: [{String.t(), String.t()}]
  def changed(from, to) do
    case git(["diff", "--name-status", "--no-renames", from, to]) do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true),
            [status, path] <- [String.split(line, "\t", parts: 2)],
            do: {status, path}

      {:error, _} ->
        []
    end
  end

  @doc """
  Puts the files `from`..`to` changed back as they were at `from`.
  Returns `%{restored: [path], set_aside: [path], skipped: [path]}`
  (skipped: edited again since `to`, so left alone).
  """
  @spec restore(String.t(), String.t(), keyword()) :: map()
  def restore(from, to, opts \\ []) do
    stamp = DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()
    only = Keyword.get(opts, :only, "")

    from
    |> changed(to)
    |> Enum.filter(fn {_, path} -> String.starts_with?(path, only) end)
    |> Enum.reduce(%{restored: [], set_aside: [], skipped: []}, fn
      {status, path}, acc ->
        cond do
          not unchanged_since?(to, path, status) ->
            Map.update!(acc, :skipped, &[path | &1])

          status == "A" ->
            dest = Path.join([aside_dir(), stamp, path])
            File.mkdir_p!(Path.dirname(dest))

            case File.rename(Path.join(root(), path), dest) do
              :ok -> Map.update!(acc, :set_aside, &[path | &1])
              {:error, _} -> Map.update!(acc, :skipped, &[path | &1])
            end

          true ->
            case git(["checkout", from, "--", path]) do
              {:ok, _} -> Map.update!(acc, :restored, &[path | &1])
              {:error, _} -> Map.update!(acc, :skipped, &[path | &1])
            end
        end
    end)
    |> Map.new(fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  # The file in the work tree is still what the change left at `to`.
  defp unchanged_since?(to, path, "D"),
    do: not File.exists?(Path.join(root(), path)) or same?(to, path)

  defp unchanged_since?(to, path, _status), do: same?(to, path)

  defp same?(to, path) do
    case git(["diff", "--quiet", to, "--", path]) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  After a run that changed Hyprland's config (`from`..`to` touched `hypr/`):
  Hyprland reloads, and if it reports errors it didn't have before
  (`errors_before`), the `hypr/` files are put back and it reloads again.
  `:ok`, `{:reverted, errors}` or `:untouched`.
  """
  @spec guard_hyprland(String.t(), String.t(), String.t()) ::
          :ok | :untouched | {:reverted, String.t()}
  def guard_hyprland(errors_before, from, to) do
    alias TinyAxe.Desktop.ConfigFiles

    if Enum.any?(changed(from, to), fn {_, path} -> String.starts_with?(path, "hypr/") end) do
      ConfigFiles.reload_hyprland()

      case ConfigFiles.config_errors() do
        errors when errors in ["", errors_before] ->
          :ok

        errors ->
          restore(from, to, only: "hypr/")
          ConfigFiles.reload_hyprland()
          {:reverted, errors}
      end
    else
      :untouched
    end
  end

  ## Runs that might be interrupted

  @doc """
  Records that a run is starting (before it changes anything), so a crash
  midway is found at the next start. Returns an id for `finished/1`.
  """
  @spec started(String.t(), String.t()) :: String.t()
  def started(request, before) do
    id = "#{System.os_time(:millisecond)}-#{System.unique_integer([:positive])}"
    File.mkdir_p!(runs_dir())

    File.write!(
      Path.join(runs_dir(), id <> ".json"),
      JSON.encode!(%{"request" => request, "before" => before})
    )

    id
  end

  @doc "The run ended (however it ended): it's no longer interrupted."
  @spec finished(String.t()) :: :ok
  def finished(id) do
    File.rm(Path.join(runs_dir(), id <> ".json"))
    :ok
  end

  @doc """
  Runs found unfinished at start: each gets an "after" snapshot of how
  things are now and becomes an undo record. Returns a line per run for
  the transcript.
  """
  @spec recover_interrupted() :: [String.t()]
  def recover_interrupted do
    with {:ok, files} <- File.ls(runs_dir()) do
      for file <- Enum.sort(files), String.ends_with?(file, ".json") do
        path = Path.join(runs_dir(), file)

        line =
          with {:ok, text} <- File.read(path),
               {:ok, %{"request" => request, "before" => before}} <- JSON.decode(text),
               {:ok, now} <- take("after an interrupted run: #{request}") do
            TinyAxe.Desktop.Undo.push_snapshot(request, before, now)

            "⚠ a desktop change was interrupted (“#{request}”); `/look undo` puts " <>
              "~/.config back as it was before it"
          else
            _ -> "⚠ a desktop change was interrupted, and its record couldn't be read"
          end

        File.rm(path)
        line
      end
    else
      _ -> []
    end
  end

  ## git

  defp ensure_repo do
    dir = git_dir()

    cond do
      File.exists?(Path.join(dir, "HEAD")) ->
        write_exclude(dir)

      true ->
        File.mkdir_p!(dir)

        with {:ok, _} <- cmd(["init", "-q", "--bare", dir]),
             {:ok, _} <- git(["config", "core.bare", "false"]),
             {:ok, _} <- git(["config", "status.showUntrackedFiles", "no"]) do
          write_exclude(dir)
        end
    end
  end

  # Everything ignored, then the tracked folders let back in, minus what
  # isn't config (backups, logs, caches, databases) and anything named like
  # a secret.
  defp write_exclude(dir) do
    lines =
      ["/*"] ++
        Enum.map(@tracked, &"!/#{&1}") ++
        ~w(*.bak *.bak.* *.log *.sqlite* *.db *.cache cache/ Cache/ node_modules/ *.tiny-axe-tmp
           *cookie* *token* *secret* *credential* *password* *.key *.pem *.gpg *.p12 .env .env.*
           *-runtime)

    File.mkdir_p!(Path.join(dir, "info"))
    File.write!(Path.join(dir, "info/exclude"), Enum.join(lines, "\n") <> "\n")
    :ok
  end

  defp git(args), do: cmd(["--git-dir", git_dir(), "--work-tree", root() | args])

  defp cmd(args) do
    base = [
      "-c",
      "user.name=tiny-axe",
      "-c",
      "user.email=tiny-axe@localhost",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "core.autocrlf=false"
    ]

    case System.cmd("git", base ++ args,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, "git exited #{status}: #{String.trim(out)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
