defmodule TinyAxe.AccountTest do
  # The site is a Req.Test stub, owned by each test's process and shared with
  # TinyAxe.Account's (async: false); the keyring is the fake one.
  use ExUnit.Case, async: false

  alias TinyAxe.Account
  alias TinyAxe.TUI.AccountFlow

  @keyring Path.join(System.get_env("TMPDIR", "/tmp"), "tiny_axe_fake_keyring")

  setup do
    File.rm(Account.path())
    File.rm(Path.join(@keyring, "site"))
    Account.start_entry()
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    :ok
  end

  # The site: free names unless listed as taken; signup and device record
  # what they were sent.
  defp site(taken \\ ["luke"], test \\ self()) do
    Req.Test.stub(Account, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/username"} ->
          name = Plug.Conn.fetch_query_params(conn).query_params["name"]

          if name in taken,
            do: Req.Test.json(conn, %{username: name, available: false, reason: "taken"}),
            else: Req.Test.json(conn, %{username: name, available: true})

        {"POST", path} when path in ["/api/signup", "/api/device"] ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          sent = JSON.decode!(body)
          send(test, {:site, path, sent})

          cond do
            sent["username"] in taken and path == "/api/signup" ->
              conn
              |> Plug.Conn.put_status(409)
              |> Req.Test.json(%{error: "That username is taken."})

            sent["password"] == "wrong password!" ->
              conn
              |> Plug.Conn.put_status(401)
              |> Req.Test.json(%{error: "That username and password don't match."})

            true ->
              conn
              |> Plug.Conn.put_status(201)
              |> Req.Test.json(%{username: sent["username"], key: "key-for-" <> sent["username"]})
          end
      end
    end)
  end

  defp type(text, field \\ :password),
    do: for(<<c::utf8 <- text>>, do: Account.entry_key(field, <<c::utf8>>))

  describe "usernames" do
    test "the rule, and asking the site" do
      site()
      assert Account.valid?("Luke")
      refute Account.valid?("a")
      refute Account.valid?("luke smith")
      assert Account.check("LUKE") == :taken
      assert Account.check("lukeh") == :available
      assert {:invalid, _} = Account.check("-x")
    end

    test "the model suggests; only valid, free ones come back, three at most" do
      site(["luke", "lukeh"])

      chat = fn _messages, opts ->
        assert opts[:format]
        names = ["Luke", "lukeh", "luke h", "luke.h", "lh_1", "hightower", "extra"]
        {:ok, %{"message" => %{"content" => JSON.encode!(%{usernames: names})}}}
      end

      assert Account.suggest("Luke Hightower", chat: chat) ==
               {:ok, ["luke.h", "lh_1", "hightower"]}
    end

    test "a model that fails or rambles says so" do
      assert {:error, _} = Account.suggest("x", chat: fn _, _ -> {:error, :econnrefused} end)

      assert {:error, _} =
               Account.suggest("x",
                 chat: fn _, _ -> {:ok, %{"message" => %{"content" => "hello"}}} end
               )
    end
  end

  describe "making the account" do
    test "the password goes to the site once; the key to the keyring; nothing else keeps it" do
      site()
      type("correct horse battery")
      assert Account.entry_length(:password) == 21
      assert Account.create("Sam", "test install") == {:ok, "sam"}

      assert_received {:site, "/api/signup",
                       %{
                         "username" => "sam",
                         "password" => "correct horse battery",
                         "label" => "test install"
                       }}

      assert Account.current() == %{username: "sam", site: "http://site.test"}
      assert Account.key() == {:ok, "key-for-sam"}
      refute File.read!(Account.path()) =~ "correct horse"
      # Forgotten once used.
      assert Account.entry_length(:password) == 0
      # Never in the process's state as shown to anyone.
      refute inspect(:sys.get_status(Account)) =~ "correct horse"
    end

    test "a short password never leaves" do
      site()
      type("short")
      assert {:error, "A password needs at least 12 characters."} = Account.create("sam")
      refute_received {:site, _, _}
    end

    test "a taken name, and an unreachable site" do
      site()
      type("correct horse battery")
      assert {:taken, _} = Account.create("luke")

      Req.Test.stub(Account, &Req.Test.transport_error(&1, :econnrefused))
      type("correct horse battery")
      assert {:error, message} = Account.create("sam")
      assert message =~ "couldn't reach"
      assert Account.current() == nil
    end

    test "signing in from another install" do
      site()
      type("wrong password!")
      assert {:error, "That username and password don't match."} = Account.sign_in("luke")
      type("the right one, really")
      assert Account.sign_in("Luke") == {:ok, "luke"}
      assert Account.key() == {:ok, "key-for-luke"}
    end
  end

  describe "the flow" do
    defp keys(flow, keys) do
      Enum.reduce(keys, flow, fn key, flow ->
        {:cont, flow} = AccountFlow.key(flow, key)
        flow
      end)
    end

    defp chars(flow, text), do: keys(flow, for(<<c::utf8 <- text>>, do: <<c::utf8>>))

    test "new account: the model suggests, a suggestion is picked, the password is typed twice" do
      site()
      flow = AccountFlow.new(required: true) |> keys(["1"]) |> chars("Luke")
      assert {:run, flow, {:suggest, "Luke"} = job} = AccountFlow.key(flow, "enter")
      assert flow.busy

      # The job's answer, as the model and the site would give it.
      assert {:cont, flow} = AccountFlow.result(flow, {:ok, ["luke.h", "lh_1"]})
      assert flow.step == :pick and flow.suggestions == ["luke.h", "lh_1"]
      _ = job

      flow = keys(flow, ["2"])
      assert flow.step == :password and flow.username == "lh_1"

      flow = chars(flow, "correct horse battery")
      assert flow.mask == 21
      # The flow itself never holds the password.
      refute inspect(flow) =~ "horse"

      {:cont, flow} = AccountFlow.key(flow, "enter")
      assert flow.step == :again
      flow = chars(flow, "correct horse battery")
      assert {:run, flow, {:create, "lh_1"} = job} = AccountFlow.key(flow, "enter")
      assert {:done, message} = AccountFlow.result(flow, AccountFlow.perform(job))
      assert message =~ "lh_1"
      assert Account.current().username == "lh_1"
    end

    test "a typed name that's taken brings suggestions close to it" do
      site()
      flow = %AccountFlow{step: :pick, required: true} |> chars("luke")
      assert {:run, flow, {:check, "luke"} = job} = AccountFlow.key(flow, "enter")
      assert {:run, flow, {:suggest, about}} = AccountFlow.result(flow, AccountFlow.perform(job))
      assert about =~ "luke"
      assert flow.note == "luke is taken."
    end

    test "passwords that don't match start the password again" do
      flow =
        %AccountFlow{step: :password, username: "sam", required: true}
        |> chars("correct horse battery")

      {:cont, flow} = AccountFlow.key(flow, "enter")
      flow = chars(flow, "something else entirely")
      {:cont, flow} = AccountFlow.key(flow, "enter")
      assert flow.step == :password
      assert flow.error =~ "don't match"
      assert Account.entry_length(:password) == 0
    end

    test "while required, esc can't skip it; otherwise it can" do
      assert {:cont, %{note: note}} = AccountFlow.key(AccountFlow.new(required: true), "esc")
      assert note =~ "needs an account"
      assert {:cancel, _} = AccountFlow.key(AccountFlow.new(required: false), "esc")
    end

    test "signing in to an existing account" do
      site()
      flow = AccountFlow.new(required: true) |> keys(["2"]) |> chars("Luke")
      {:cont, flow} = AccountFlow.key(flow, "enter")
      assert flow.step == :signin_password
      flow = chars(flow, "the right one, really")
      assert {:run, flow, job} = AccountFlow.key(flow, "enter")
      assert {:done, message} = AccountFlow.result(flow, AccountFlow.perform(job))
      assert message =~ "Signed in as luke"
    end
  end

  describe "in the TUI" do
    alias ExRatatui.Event
    alias TinyAxe.TUI

    defp draw(state) do
      terminal = ExRatatui.init_test_terminal(100, 30)
      ExRatatui.draw(terminal, TUI.render(state, %ExRatatui.Frame{width: 100, height: 30}))
      ExRatatui.get_buffer_content(terminal)
    end

    defp press(state, code), do: elem(TUI.handle_event(%Event.Key{code: code, kind: "press", modifiers: []}, state), 1)

    # The job runs in a task; its answer comes back as a message.
    defp answer(state) do
      assert_receive {:account_flow, ref, _} = msg, 15_000
      assert ref == state.account_job
      elem(TUI.handle_info(msg, state), 1)
    end

    test "opens on the account, and the password shows only as dots" do
      site()
      {:ok, state} = TUI.mount(test_mode: {100, 30}, account_flow: AccountFlow.new(required: true))
      assert draw(state) =~ "your tiny-axe account"
      assert draw(state) =~ "Make a new account"

      # A request can't be typed past it: keys go to the flow.
      state = state |> press("1") |> press("S") |> press("a") |> press("m") |> press("enter")
      assert state.account_flow.busy
      # The model may not be there in tests; either way, the user can type a name.
      state = answer(state)
      assert state.account_flow.step == :pick

      state = Enum.reduce(String.graphemes("sam"), state, &press(&2, &1)) |> press("enter")
      state = answer(state)
      assert state.account_flow.step == :password

      state = Enum.reduce(String.graphemes("correct horse battery"), state, &press(&2, &1))
      screen = draw(state)
      assert screen =~ String.duplicate("•", 21)
      refute screen =~ "horse"
      refute inspect(state) =~ "horse"
    end
  end

end
