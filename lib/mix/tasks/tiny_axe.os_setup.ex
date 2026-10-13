defmodule Mix.Tasks.TinyAxe.OsSetup do
  @shortdoc "Show the commands that install tiny-axe's root helper"
  @moduledoc """
  tiny-axe's root actions (install or remove packages, a system update,
  system services) go through one helper, `/usr/local/bin/tiny-axe-root`,
  which a sudoers rule lets you run without a password, and nothing else
  (`TinyAxe.Desktop.Root`). tiny-axe never installs it itself:

      mix tiny_axe.os_setup            # status, and the two commands to run if it isn't set up
      mix tiny_axe.os_setup --remove   # the commands that take it out again

  Run the commands yourself (in tiny-axe, prefix them with `!`); sudo asks
  for your password once. Run this again after updating tiny-axe: an
  installed helper that differs from the shipped one isn't used.
  """

  use Mix.Task

  alias TinyAxe.Desktop.Root

  @impl true
  def run(["--remove"]) do
    Mix.shell().info("""
    To take tiny-axe's root helper out:

      sudo rm /etc/sudoers.d/tiny-axe /usr/local/bin/tiny-axe-root
    """)
  end

  def run([]) do
    Mix.Task.run("app.config")

    case Root.status() do
      :ready ->
        Mix.shell().info("tiny-axe's root helper is set up: #{Root.installed_path()}")

      {:missing, why} ->
        Mix.shell().info("""
        #{why}.

        To set it up, run these two commands yourself (sudo asks for your password):

          #{Enum.join(Root.setup(), "\n  ")}

        The first installs the helper (it allows only: install or remove official
        packages, a system update, system services, a snapshot). The second checks
        and installs the sudoers rule that lets you run that one file without a
        password. Read both files first if you like; they're in the folder named above.
        """)
    end
  end
end
