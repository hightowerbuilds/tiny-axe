defmodule Mix.Tasks.TinyAxe.Install do
  @shortdoc "Build tiny-axe and install a `tiny-axe` command you can run anywhere"
  @moduledoc """
  Builds a release and installs it for the current user:

    * the release goes to `~/.local/share/tiny-axe/release`, replacing any
      earlier one (it carries its own Erlang runtime; no repo or `mix` needed)
    * a `tiny-axe` launcher goes to `~/.local/bin`, which opens tiny-axe in
      whatever folder you run it from
    * settings live in `~/.config/tiny-axe/env`; if that file doesn't exist and
      this repo has a `.env`, it's copied there (readable only by you)

      mix tiny_axe.install

  Afterwards, in any folder:

      tiny-axe
      tiny-axe --model gemma4:12b-it-qat --decider local
      tiny-axe --dir ~/code/app

  Code checks run the `elixir` command in a sandbox; outside this repo mise
  doesn't know which Elixir to use, so the launcher puts the Elixir and
  Erlang this repo uses (from `mise where`) first on its PATH.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    data = Path.join(System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"), "tiny-axe")
    config = Path.join(System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config"), "tiny-axe")
    bin = Path.expand("~/.local/bin")
    release = Path.join(data, "release")

    Mix.shell().info("Building the release (MIX_ENV=prod)…")
    # Built next to its final place (same filesystem), then swapped in whole.
    File.mkdir_p!(data)
    build = Path.join(data, "release.new")
    File.rm_rf!(build)

    {_, status} =
      System.cmd("mix", ["release", "tiny_axe", "--overwrite", "--path", build],
        env: [{"MIX_ENV", "prod"}],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("mix release failed (exit #{status})")

    # Swap in the new release only once it has built.
    File.rm_rf!(release)
    File.rename!(build, release)

    File.mkdir_p!(bin)
    launcher = Path.join(bin, "tiny-axe")
    # Removed first, so an old symlink (e.g. to this repo's bin/tiny-axe) is
    # replaced rather than written through.
    File.rm(launcher)
    extra_path = elixir_paths()
    File.write!(launcher, launcher(release, extra_path))
    File.chmod!(launcher, 0o755)

    # The installed copy runs from its own trimmed runtime, which is where code
    # checks broke before; check one for real before calling the install done.
    self_check!(release, extra_path)

    File.mkdir_p!(config)
    env_file = Path.join(config, "env")

    settings =
      cond do
        File.exists?(env_file) ->
          "kept your settings in #{env_file}"

        File.regular?(".env") ->
          File.cp!(".env", env_file)
          File.chmod!(env_file, 0o600)
          "copied .env to #{env_file} (readable only by you)"

        true ->
          File.write!(env_file, "# TYPESAFE_API_KEY=\n")
          File.chmod!(env_file, 0o600)
          "created #{env_file}; add TYPESAFE_API_KEY=… there to use Jev"
      end

    Mix.shell().info("""

    Installed tiny-axe:
      release   #{release}
      launcher  #{launcher}
      settings  #{settings}

    Run `tiny-axe` in any folder.#{on_path_hint(bin)}
    """)
  end

  @smoke """
  code = "```elixir\\ndefmodule Smoke do\\n  @doc \\"\\"\\"\\n      iex> Smoke.two()\\n      2\\n  \\"\\"\\"\\n  def two, do: 2\\nend\\n```"
  case TinyAxe.CodeCheck.run(code) do
    {:ran, %{status: :passed}} -> IO.puts("SELF_CHECK passed")
    {:skipped, reason} -> IO.puts("SELF_CHECK skipped " <> reason)
    other -> IO.puts("SELF_CHECK failed " <> inspect(other))
  end
  """

  defp self_check!(release, extra_path) do
    path = Enum.join(extra_path ++ [System.get_env("PATH", "")], ":")

    {out, _} =
      System.cmd(Path.join(release, "bin/tiny_axe"), ["eval", @smoke],
        env: [{"PATH", path}],
        stderr_to_stdout: true
      )

    case Regex.run(~r/SELF_CHECK (passed|skipped|failed)(.*)/, out) do
      [_, "passed", _] ->
        Mix.shell().info("Self-check: code checks work in the installed copy.")

      [_, "skipped", why] ->
        Mix.shell().info("Self-check: code checks are skipped (#{String.trim(why)}).")

      _ ->
        Mix.raise("Self-check failed: code checks don't work in the installed copy.\n\n#{out}")
    end
  end

  # The Elixir and Erlang that mise gives this repo, for sandboxed code checks.
  defp elixir_paths do
    for tool <- ~w(elixir erlang),
        {path, 0} <- [System.cmd("mise", ["where", tool], stderr_to_stdout: true)],
        dir = Path.join(String.trim(path), "bin"),
        File.dir?(dir),
        do: dir
  rescue
    ErlangError -> []
  end

  defp launcher(release, extra_path) do
    path =
      if extra_path == [], do: "", else: ~s(export PATH="#{Enum.join(extra_path, ":")}:$PATH"\n)

    """
    #!/usr/bin/env bash
    # tiny-axe launcher, installed by `mix tiny_axe.install`.
    # Opens tiny-axe in the current folder (or --dir).
    set -euo pipefail

    usage() {
      echo "usage: tiny-axe [--dir FOLDER] [--model OLLAMA_MODEL] [--decider jev|local]"
    }

    dir="$PWD"
    while [ $# -gt 0 ]; do
      case "$1" in
        --dir) dir="$2"; shift 2 ;;
        --model) export TINY_AXE_MODEL="$2"; shift 2 ;;
        --decider) export TINY_AXE_DECIDER="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
      esac
    done

    if [ ! -d "$dir" ]; then
      echo "tiny-axe: $dir is not a folder" >&2
      exit 2
    fi
    export TINY_AXE_DIR="$(cd "$dir" && pwd)"

    # Sandboxed code checks run `elixir`; use the one tiny-axe was built with.
    #{path}
    exec "#{release}/bin/tiny_axe" start
    """
  end

  defp on_path_hint(bin) do
    in_path? = System.get_env("PATH", "") |> String.split(":") |> Enum.member?(bin)

    if in_path?,
      do: "",
      else: "\n(#{bin} isn't on your PATH yet; add it to use `tiny-axe` by name.)"
  end
end
