ExUnit.start()

# This run's own state and trash folders (config/test.exs), removed afterwards.
ExUnit.after_suite(fn _ ->
  File.rm_rf(Application.get_env(:tiny_axe, :state_dir))
  File.rm_rf(Application.get_env(:tiny_axe, :trash_dir))
end)
