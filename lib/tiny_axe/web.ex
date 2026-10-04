defmodule TinyAxe.Web do
  @moduledoc """
  Keyless web search and page reading.

    * `search/2` scrapes DuckDuckGo Lite, falling back to Brave Search and then
      Bing. DuckDuckGo and Brave sometimes challenge or rate-limit scripted
      requests; Bing always answers but returns junk for niche technical terms,
      so it goes last. Google blocks scripted requests outright.
    * `fetch/2` downloads a page and extracts its readable text. Pages that only
      render with JavaScript are read in tiny-axe's browser (`TinyAxe.Browser`)
      when it's running, or else in a one-off headless Chrome.
  """

  @type result :: %{title: String.t(), url: String.t(), snippet: String.t()}
  @type page :: %{url: String.t(), title: String.t(), text: String.t()}

  @user_agent "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) " <>
                "Chrome/140.0 Safari/537.36"
  @max_body 3_000_000
  # Less readable text than this usually means the page renders with JavaScript.
  @min_text 400

  @doc """
  Searches the web, trying each engine in turn until one returns results.

  Options: `:limit` (default 8), `:engines`, and `:accept?`, a function given
  the results that returns false to move on to the next engine.
  """
  @spec search(String.t(), keyword()) :: {:ok, [result()], atom()} | {:error, term()}
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 8)
    engines = Keyword.get(opts, :engines, [:duckduckgo, :brave, :bing])
    # Lets the caller reject off-topic results so the next engine gets a try.
    accept? = Keyword.get(opts, :accept?, fn _results -> true end)

    Enum.reduce_while(engines, {:error, :no_engines}, fn engine, _acc ->
      with {:ok, [_ | _] = results} <- search_engine(engine, query),
           results = Enum.take(results, limit),
           {:accept, true} <- {:accept, accept?.(results)} do
        {:halt, {:ok, results, engine}}
      else
        {:accept, false} -> {:cont, {:error, {engine, :irrelevant}}}
        {:ok, []} -> {:cont, {:error, {engine, :no_results}}}
        {:error, reason} -> {:cont, {:error, {engine, reason}}}
      end
    end)
  end

  defp search_engine(:duckduckgo, query) do
    with {:ok, html} <- get("https://lite.duckduckgo.com/lite/", params: [q: query]) do
      {:ok, parse_duckduckgo(html)}
    end
  end

  defp search_engine(:brave, query) do
    with {:ok, html} <- get("https://search.brave.com/search", params: [q: query]) do
      {:ok, parse_brave(html)}
    end
  end

  defp search_engine(:bing, query) do
    with {:ok, html} <- get("https://www.bing.com/search", params: [q: query, setlang: "en"]) do
      {:ok, parse_bing(html)}
    end
  end

  # Each result spans several table rows: the link, then its snippet, then its URL.
  @doc false
  def parse_duckduckgo(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("tr")
    |> Enum.reduce([], fn row, acc ->
      case {Floki.find(row, "a.result-link"), Floki.find(row, "td.result-snippet"), acc} do
        {[link | _], _, acc} ->
          href = link |> Floki.attribute("href") |> List.first("") |> unwrap_duckduckgo()
          [%{url: href, title: text([link]), snippet: ""} | acc]

        {[], [_ | _] = snippet, [result | rest]} ->
          [%{result | snippet: text(snippet)} | rest]

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
    # Ads link through duckduckgo.com/y.js rather than to the destination.
    |> Enum.filter(fn r ->
      %URI{scheme: scheme, host: host} = URI.parse(r.url)
      scheme in ["http", "https"] and host != "duckduckgo.com" and r.title != ""
    end)
  end

  # DuckDuckGo links go through a redirect whose `uddg` parameter is the destination.
  @doc false
  def unwrap_duckduckgo(href) do
    case URI.parse(href) do
      %URI{path: "/l/", query: query} when is_binary(query) ->
        Map.get(URI.decode_query(query), "uddg", href)

      _ ->
        href
    end
  end

  @doc false
  def parse_brave(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("div[data-type=web]")
    |> Enum.map(fn r ->
      %{
        url: r |> Floki.find("a[href^=http]") |> Floki.attribute("href") |> List.first(),
        title: r |> Floki.find(".title") |> text(),
        snippet: r |> Floki.find(".generic-snippet .content, .snippet-description") |> text()
      }
    end)
    |> Enum.filter(&(&1.url && &1.title != ""))
  end

  @doc false
  def parse_bing(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("li.b_algo")
    |> Enum.map(fn r ->
      %{
        url: r |> Floki.find("h2 a") |> Floki.attribute("href") |> List.first() |> unwrap_bing(),
        title: r |> Floki.find("h2") |> text(),
        snippet: r |> Floki.find(".b_caption p, p") |> Enum.take(1) |> text()
      }
    end)
    |> Enum.filter(&(&1.url && &1.title != ""))
  end

  # Bing links go through a click tracker whose `u` parameter is "a1" plus the
  # base64url-encoded destination.
  @doc false
  def unwrap_bing("https://www.bing.com/ck/a?" <> query = url) do
    with %{"u" => "a1" <> encoded} <- URI.decode_query(query),
         {:ok, target} <- Base.url_decode64(encoded, padding: false),
         true <- String.starts_with?(target, "http") do
      target
    else
      _ -> url
    end
  end

  def unwrap_bing(url), do: url

  @spec fetch(String.t(), keyword()) :: {:ok, page()} | {:error, term()}
  def fetch(url, opts \\ []) do
    max_chars = Keyword.get(opts, :max_chars, 3_000)

    with {:ok, html} <- get(url, []) do
      page = extract(html, url)

      page =
        if String.length(page.text) < @min_text,
          do: rendered(url, page),
          else: page

      {:ok, %{page | text: truncate(page.text, max_chars)}}
    end
  end

  @doc "Extracts the title and readable text of an HTML page."
  @spec extract(String.t(), String.t()) :: page()
  def extract(html, url) do
    doc = Floki.parse_document!(html)
    title = doc |> Floki.find("title") |> Enum.take(1) |> text()

    body =
      doc
      |> Floki.filter_out(
        "script, style, noscript, svg, iframe, nav, header, footer, aside, form"
      )
      |> Floki.find("article, main, body")
      |> List.first()

    lines =
      (body || doc)
      |> Floki.find("h1, h2, h3, h4, p, li, pre, blockquote, td, dt, dd")
      |> Enum.map(&text([&1]))
      |> Enum.reject(&(&1 == ""))
      # Parents come before their children, so drop a line its parent already covered.
      |> Enum.reduce([], fn
        line, [prev | _] = acc -> if String.contains?(prev, line), do: acc, else: [line | acc]
        line, [] -> [line]
      end)
      |> Enum.reverse()

    text = Enum.join(lines, "\n")

    # App-style pages often keep most of their text in plain divs and spans.
    all_text =
      if body,
        do: body |> Floki.text(sep: "\n") |> String.replace(~r/\s*\n\s*/u, "\n") |> String.trim(),
        else: ""

    text =
      if String.length(text) < @min_text and String.length(text) * 4 < String.length(all_text),
        do: all_text,
        else: text

    %{url: url, title: title, text: text}
  end

  defp get(url, opts) do
    req =
      Req.new(
        url: url,
        params: Keyword.get(opts, :params, []),
        headers: [user_agent: @user_agent, accept_language: "en-US,en;q=0.9"],
        receive_timeout: 10_000,
        retry: false,
        decode_body: false,
        into: &capped_body/2
      )

    case Req.get(req) do
      {:ok, %Req.Response{status: 200} = resp} ->
        type = resp |> Req.Response.get_header("content-type") |> List.first("")

        if type =~ ~r/html|text\/plain/,
          do: {:ok, resp |> Req.Response.get_private(:body, []) |> IO.iodata_to_binary()},
          else: {:error, {:unsupported_content, type}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Stops downloading past @max_body, so a large PDF or video can't fill memory.
  defp capped_body({:data, data}, {req, resp}) do
    body = [Req.Response.get_private(resp, :body, []) | data]
    resp = Req.Response.put_private(resp, :body, body)
    if IO.iodata_length(body) > @max_body, do: {:halt, {req, resp}}, else: {:cont, {req, resp}}
  end

  # A page that renders with JavaScript: tiny-axe's own browser when it's
  # running (it redacts as it reads), else a one-off headless Chrome.
  defp rendered(url, page) do
    if TinyAxe.Browser.running?() do
      case TinyAxe.Browser.read(url) do
        {:ok, text} when byte_size(text) > 0 -> %{page | text: text}
        _ -> page
      end
    else
      case chrome_dump(url) do
        {:ok, html} -> extract(html, url)
        _ -> page
      end
    end
  end

  defp chrome_dump(url) do
    with chrome when chrome != nil <- chrome() do
      profile =
        Path.join(System.tmp_dir!(), "tiny_axe_chrome_#{System.unique_integer([:positive])}")

      try do
        args =
          ~w(25 #{chrome} --headless=new --disable-gpu --no-first-run --no-default-browser-check) ++
            ["--user-data-dir=#{profile}", "--dump-dom", url]

        case System.cmd("timeout", args, stderr_to_stdout: false) do
          {html, 0} -> {:ok, html}
          {_, status} -> {:error, {:chrome, status}}
        end
      after
        File.rm_rf(profile)
      end
    else
      nil -> {:error, :no_chrome}
    end
  end

  defp chrome do
    Enum.find_value(
      ~w(google-chrome-stable google-chrome chromium chromium-browser brave),
      &System.find_executable/1
    )
  end

  defp text(nodes) do
    nodes |> Floki.text() |> String.replace(~r/\s+/u, " ") |> String.trim()
  end

  defp truncate(s, max) do
    if String.length(s) <= max, do: s, else: String.slice(s, 0, max) <> " …"
  end
end
