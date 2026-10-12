defmodule TinyAxe.TUI.AccountFlow do
  @moduledoc """
  Making (or signing in to) the user's tiny-axe account, in a popup, the
  first time tiny-axe opens (`TinyAxe.Account`). While the account is
  required (`config :tiny_axe, :site, required: true`), there's no way past
  it but making one or signing in; ctrl+c still quits.

  The model helps with the username: from what the user says they'd like to
  be called, it suggests names, and the site says which are free. The
  password is typed straight into `TinyAxe.Account` a keystroke at a time;
  this flow (and so the TUI's state) only holds how many dots to show.

  `key/2` and `paste/2` take input; `result/2` takes what a job came back
  with. Each returns `{:cont, flow}`, `{:run, flow, job}` (the TUI runs
  `perform/1` on `job` in a task and hands its answer to `result/2`),
  `{:done, message}` or `{:cancel, message}`.
  """

  alias TinyAxe.Account

  defstruct step: :welcome,
            buffer: "",
            suggestions: [],
            username: nil,
            # Dots to show for the field being typed into.
            mask: 0,
            error: nil,
            note: nil,
            # What's being waited for, shown while a job runs.
            busy: nil,
            required: true

  @type t :: %__MODULE__{}

  def new(opts \\ []) do
    Account.start_entry()
    %__MODULE__{required: Keyword.get(opts, :required, Account.required?())}
  end

  @doc "The question on screen and how it's answered: `{question, kind}`."
  def step(%__MODULE__{step: step}), do: Map.fetch!(steps(), step)

  defp steps do
    %{
      welcome:
        {"tiny-axe keeps your chats on your own page of its website, where you can search them. Let's set up your account.",
         :choice},
      about:
        {"What would you like to be called? A name or a nickname is fine: I'll suggest usernames from it.",
         :text},
      pick: {"Pick a username, or type one of your own", :text},
      password: {"Choose a password (at least 12 characters)", :secret},
      again: {"Type it again", :secret},
      username: {"Your username", :text},
      signin_password: {"Your password", :secret}
    }
  end

  def choices(%__MODULE__{step: :welcome}),
    do: [{"1", "Make a new account"}, {"2", "I already have an account"}]

  def choices(_flow), do: []

  ## Input

  def key(%__MODULE__{busy: busy} = flow, _key) when busy != nil, do: {:cont, flow}

  def key(%__MODULE__{} = flow, "esc"), do: back(flow)

  def key(%__MODULE__{step: :welcome} = flow, "1"),
    do: {:cont, %{flow | step: :about, error: nil, note: nil}}

  def key(%__MODULE__{step: :welcome} = flow, "2"),
    do: {:cont, %{flow | step: :username, error: nil, note: nil}}

  def key(%__MODULE__{step: :welcome} = flow, _key), do: {:cont, flow}

  # A suggestion by its number, while nothing's typed. It was free a moment ago.
  def key(%__MODULE__{step: :pick, buffer: ""} = flow, <<d>>) when d in ?1..?9 do
    case Enum.at(flow.suggestions, d - ?1) do
      nil -> {:cont, flow}
      name -> {:cont, to_password(flow, name)}
    end
  end

  def key(%__MODULE__{} = flow, "enter"), do: submit(flow)

  def key(%__MODULE__{} = flow, key) do
    case step(flow) do
      {_, :secret} ->
        Account.entry_key(field(flow), key)
        {:cont, %{flow | mask: Account.entry_length(field(flow)), error: nil}}

      {_, :text} ->
        {:cont, %{flow | buffer: edit(flow.buffer, key), error: nil}}

      _ ->
        {:cont, flow}
    end
  end

  def paste(%__MODULE__{busy: nil} = flow, text) do
    case step(flow) do
      {_, :secret} ->
        Account.entry_paste(field(flow), text)
        %{flow | mask: Account.entry_length(field(flow))}

      {_, :text} ->
        %{flow | buffer: flow.buffer <> String.replace(text, ~r/[\r\n]/, " ")}

      _ ->
        flow
    end
  end

  def paste(flow, _text), do: flow

  defp edit(buffer, "backspace"), do: String.slice(buffer, 0..-2//1)
  defp edit(buffer, <<_::utf8>> = char) when byte_size(buffer) < 200, do: buffer <> char
  defp edit(buffer, _key), do: buffer

  defp field(%{step: :again}), do: :again
  defp field(_flow), do: :password

  defp submit(%{step: :about, buffer: about} = flow) do
    if String.trim(about) == "",
      do: {:cont, %{flow | error: "Type a name or a nickname (or a username you'd like)."}},
      else: run(%{flow | busy: "thinking of usernames…"}, {:suggest, about})
  end

  defp submit(%{step: :pick, buffer: typed} = flow) do
    cond do
      String.trim(typed) == "" ->
        {:cont, %{flow | error: "Pick a number, or type a username."}}

      not Account.valid?(typed) ->
        {:cont, %{flow | error: "A username is #{Account.rule()}."}}

      true ->
        run(
          %{flow | busy: "checking #{Account.normalize(typed)}…"},
          {:check, Account.normalize(typed)}
        )
    end
  end

  defp submit(%{step: :password} = flow) do
    case Account.entry_problem(:password) do
      nil -> {:cont, %{flow | step: :again, mask: 0, error: nil}}
      problem -> {:cont, %{flow | error: problem}}
    end
  end

  defp submit(%{step: :again} = flow) do
    case Account.entry_problem(:again) do
      nil ->
        run(%{flow | busy: "making #{flow.username}…"}, {:create, flow.username})

      problem ->
        Account.start_entry()
        {:cont, %{flow | step: :password, mask: 0, error: problem <> " Choose it again."}}
    end
  end

  defp submit(%{step: :username, buffer: typed} = flow) do
    if Account.valid?(typed),
      do:
        {:cont,
         %{
           flow
           | step: :signin_password,
             username: Account.normalize(typed),
             buffer: "",
             mask: 0,
             error: nil
         }},
      else: {:cont, %{flow | error: "A username is #{Account.rule()}."}}
  end

  defp submit(%{step: :signin_password} = flow) do
    if flow.mask == 0,
      do: {:cont, %{flow | error: "Type your password."}},
      else: run(%{flow | busy: "signing in as #{flow.username}…"}, {:sign_in, flow.username})
  end

  defp submit(flow), do: {:cont, flow}

  defp back(%{step: :welcome, required: true} = flow),
    do: {:cont, %{flow | note: "tiny-axe needs an account to start. ctrl+c quits."}}

  defp back(%{step: :welcome}), do: {:cancel, "No account made. /account sets one up."}

  defp back(%{step: step} = flow) when step in [:about, :username],
    do: {:cont, reset(flow, :welcome)}

  defp back(%{step: :pick} = flow), do: {:cont, reset(flow, :about)}

  defp back(%{step: step} = flow) when step in [:password, :again],
    do: {:cont, reset(flow, :pick)}

  defp back(%{step: :signin_password} = flow), do: {:cont, reset(flow, :username)}

  defp reset(flow, step) do
    Account.start_entry()
    %{flow | step: step, buffer: "", mask: 0, error: nil, note: nil}
  end

  defp to_password(flow, name) do
    Account.start_entry()
    %{flow | step: :password, username: name, buffer: "", mask: 0, error: nil, note: nil}
  end

  defp run(flow, job), do: {:run, %{flow | error: nil}, job}

  ## Jobs, run by the TUI in a task

  @doc "Does a job: what the model suggests, what the site says."
  def perform({:suggest, about}), do: Account.suggest(about)
  def perform({:check, name}), do: {name, Account.check(name)}
  def perform({:create, username}), do: Account.create(username)
  def perform({:sign_in, username}), do: Account.sign_in(username)

  @doc "Takes what a job came back with."
  def result(%__MODULE__{step: step} = flow, answer) when step in [:about, :pick] do
    flow = %{flow | busy: nil}

    case answer do
      {:ok, []} ->
        {:cont,
         %{
           flow
           | step: :pick,
             buffer: "",
             suggestions: [],
             note: "No free names came to mind; type one of your own."
         }}

      {:ok, names} ->
        {:cont, %{flow | step: :pick, buffer: "", suggestions: names}}

      {:error, reason} ->
        {:cont,
         %{
           flow
           | step: :pick,
             buffer: "",
             suggestions: [],
             note: "#{reason}. Type a username of your own."
         }}

      {name, :available} ->
        {:cont, to_password(flow, name)}

      {name, :taken} ->
        run(
          %{flow | note: "#{name} is taken.", busy: "thinking of others…"},
          {:suggest, "#{name} (taken; suggest names close to it)"}
        )

      {_name, {:invalid, reason}} ->
        {:cont, %{flow | error: "A username is #{reason}."}}

      {_name, {:error, reason}} ->
        {:cont, %{flow | error: "Couldn't check it: #{reason}. Press enter to try again."}}
    end
  end

  def result(%__MODULE__{step: :again} = flow, answer) do
    flow = %{flow | busy: nil}

    case answer do
      {:ok, name} ->
        {:done,
         "✓ Your account is #{name} on #{Account.site_url()}. Sign in there with it to see what tiny-axe learns."}

      {:taken, _message} ->
        run(
          %{
            flow
            | step: :pick,
              note: "#{flow.username} was just taken.",
              busy: "thinking of others…"
          },
          {:suggest, "#{flow.username} (taken)"}
        )

      {:error, reason} ->
        {:cont, %{reset(flow, :password) | error: reason}}
    end
  end

  def result(%__MODULE__{step: :signin_password} = flow, answer) do
    flow = %{flow | busy: nil}

    case answer do
      {:ok, name} -> {:done, "✓ Signed in as #{name} on #{Account.site_url()}."}
      {:error, reason} -> {:cont, %{flow | mask: 0, error: reason}}
    end
  end

  def result(flow, _answer), do: {:cont, %{flow | busy: nil}}
end
