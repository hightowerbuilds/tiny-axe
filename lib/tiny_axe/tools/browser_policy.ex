defmodule TinyAxe.Tools.BrowserPolicy do
  @moduledoc """
  The risk class of a browser action, decided by tiny-axe from what the action
  would actually do, never by the model. Before a click, a keypress or typing,
  the gate inspects the target on the page (`browser_inspect`, a tool agents
  never see): is it a link, a form's submit button, a payment or password
  field? What does the button say, where does the form send?

    * a link, or a search form (GET) — like opening a page: read, unless the
      URL carries a lot of data (a long query string could be the agent sending
      something out), then outward
    * a form that would POST, a "Send" / "Post" / "Delete" button, accepting a
      dialog, uploading a file — outward: the user approves each one
    * a payment form, or "Place order" / "Buy now" / "Pay" / "Subscribe" —
      commit: the purchase gate (refused until it exists)
    * typing into a password or card field — refused, always
    * "Add to cart", "Next", "Show more" and the like — local
    * other buttons — Jev judges: "would this send something, or spend
      money?"; no answer counts as the stricter class
    * logins, 2FA, CAPTCHAs — a handoff: the user does it in the window

  Returns `{class, reason}`; the reason is shown to the user when they're asked.
  """

  alias TinyAxe.Decider

  @commit ~r/\b(place (your )?order|buy( it)? now|buy|pay( now)?|purchase|complete (your )?(order|purchase)|confirm (order|purchase|payment)|subscribe|1-click|one-click|book now|donate)\b/i
  @outward ~r/\b(send|post|publish|submit|share|reply|comment|tweet|delete|remove|unsubscribe|follow|sign ?up|register|save|confirm|apply|invite|upload|report|vote|like|transfer|log ?in|sign ?in)\b/i

  # Undoable on the site, whatever Jev thinks: real Jev scored "Add to cart" as
  # possibly spending money, which would block every shopping task. Purchase
  # words are checked first, so "Buy now" is never caught here.
  @local ~r/\b(add to (cart|bag|basket|trolley|wish ?list)|view (cart|bag|basket)|continue shopping|next|previous|back|show (more|less|all)|load more|see more|read more|expand|collapse|close|dismiss|menu|filter|sort( by)?|search|accept( all)? cookies|reject( all)? cookies)\b/i

  # Longer than this, a URL's query string may be data on its way out.
  @long_query 200

  @type inspect_fun :: (String.t() | nil -> map() | nil)

  @spec classify(String.t(), map(), inspect_fun()) ::
          {TinyAxe.Tools.Policy.class() | :handoff, String.t() | nil}
  def classify(tool, args, inspect)

  def classify(tool, %{"url" => url}, _inspect)
      when tool in ["browser_navigate", "browser_read", "browser_tab_new"],
      do: url_class(url)

  def classify("browser_handoff", args, _inspect),
    do: {:handoff, args["reason"] || "the agent needs you in the browser"}

  def classify("browser_inspect", _args, _inspect),
    do: {:refused, "that's for tiny-axe's gate only"}

  def classify("browser_file_upload", args, _inspect),
    do: {:outward, "uploads #{Enum.join(List.wrap(args["paths"]), ", ")} to the page"}

  def classify("browser_handle_dialog", %{"accept" => true}, inspect) do
    case inspect.(nil) do
      %{"dialog" => %{"message" => message}} ->
        {:outward, ~s(answers OK to the page's dialog: "#{message}")}

      _ ->
        {:outward, "answers OK to the page's dialog"}
    end
  end

  def classify("browser_click", %{"ref" => ref}, inspect), do: inspect.(ref) |> click()

  def classify("browser_type", %{"ref" => ref} = args, inspect) do
    case {inspect.(ref), args["submit"] == true} do
      {%{"sensitive" => true}, _} -> refused_sensitive()
      {%{"form" => %{} = form} = meta, true} -> submission(form, meta)
      _ -> {:local, nil}
    end
  end

  def classify("browser_fill_form", %{"fields" => fields}, inspect) do
    if Enum.any?(List.wrap(fields), &match?(%{"sensitive" => true}, inspect.(&1["ref"]))),
      do: refused_sensitive(),
      else: {:local, nil}
  end

  def classify("browser_press_key", %{"key" => key}, inspect) do
    case {String.downcase(key), inspect.(nil)} do
      {"enter", %{"form" => %{} = form} = meta} -> submission(form, meta)
      _ -> {:local, nil}
    end
  end

  # Typing, selecting, hovering, closing a tab: all undoable on the page.
  def classify(tool, _args, _inspect)
      when tool in ~w(browser_select_option browser_hover browser_tab_close browser_handle_dialog browser_tab_new),
      do: {:local, nil}

  def classify(_tool, _args, _inspect), do: {:read, nil}

  ## Clicks

  defp click(nil), do: {:outward, "tiny-axe couldn't see what this would click"}

  # Choosing an option (a saved card, a size, a delivery slot) changes nothing
  # until a form is sent, whatever its label says ("Pay with PayPal").
  defp click(%{"type" => type, "isSubmit" => false}) when type in ["radio", "checkbox"],
    do: {:local, nil}

  defp click(%{"href" => href, "isSubmit" => false}) when is_binary(href), do: url_class(href)
  defp click(%{"isSubmit" => true, "form" => %{} = form} = meta), do: submission(form, meta)

  defp click(%{"text" => label} = meta) do
    cond do
      label =~ @commit -> {:commit, ~s(clicks "#{label}")}
      label =~ @outward -> {:outward, ~s(clicks "#{label}" on #{host(meta["page"])})}
      label =~ @local -> {:local, nil}
      true -> double_check(meta)
    end
  end

  defp submission(form, meta) do
    label = meta["text"] || ""
    name = if form["label"] in [nil, ""], do: "a form", else: ~s(the form "#{form["label"]}")
    where = host(form["action"])

    cond do
      form["hasPayment"] ->
        {:commit, "submits #{name}, which has payment fields"}

      label =~ @commit ->
        {:commit, ~s(submits #{name} with "#{label}")}

      form["hasPassword"] ->
        {:outward, "signs in: submits #{name} to #{where}"}

      form["method"] == "get" ->
        url_class(form["action"])

      true ->
        {:outward, "submits #{name} to #{where} (#{String.upcase(form["method"] || "post")})"}
    end
  end

  # Buttons whose words say nothing: Jev judges; no answer is the stricter class.
  defp double_check(meta) do
    label = meta["text"] || "(no label)"

    questions = %{
      spends: %{
        type: :noul,
        instructions: "Would clicking this spend money or commit to a purchase or subscription?"
      },
      sends: %{
        type: :noul,
        instructions:
          "Would clicking this send something to the website or to someone, or change " <>
            "something stored there (post, submit, sign up, delete, save)?"
      }
    }

    state = %{page: meta["page"], button: label, element: "#{meta["tag"]} #{meta["role"]}"}

    case Decider.decide(state, questions) do
      {:ok, answers} ->
        spends = Decider.p(answers, :spends)
        sends = Decider.p(answers, :sends)

        cond do
          spends == nil or sends == nil ->
            {:outward, ~s(clicks "#{label}"; tiny-axe couldn't check what it does)}

          spends >= 0.3 ->
            {:commit, ~s(clicks "#{label}", which may spend money)}

          sends >= 0.5 ->
            {:outward, ~s(clicks "#{label}", which may send or change something)}

          true ->
            {:local, nil}
        end

      {:error, _} ->
        {:outward, ~s(clicks "#{label}"; tiny-axe couldn't check what it does)}
    end
  end

  defp url_class(url) do
    query = (URI.parse(url || "").query || "") |> String.length()

    if query > @long_query,
      do: {:outward, "opens #{host(url)} with #{query} characters of data in the address"},
      else: {:read, nil}
  end

  defp refused_sensitive,
    do: {:refused, "tiny-axe never types into password or card fields; the user does that"}

  defp host(url) do
    case URI.parse(url || "") do
      %URI{host: host} when is_binary(host) -> host
      _ -> "the page"
    end
  end
end
