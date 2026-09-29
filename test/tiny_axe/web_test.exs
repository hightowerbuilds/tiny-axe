defmodule TinyAxe.WebTest do
  use ExUnit.Case, async: true

  alias TinyAxe.Web

  test "parses DuckDuckGo Lite results, unwrapping redirects and dropping ads" do
    html = """
    <table>
      <tr><td><a class="result-link" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fhexdocs.pm%2Fex_ratatui&amp;rut=abc">ExRatatui docs</a></td></tr>
      <tr><td class="result-snippet">Elixir bindings for <b>ratatui</b>.</td></tr>
      <tr><td><span class="link-text">hexdocs.pm/ex_ratatui</span></td></tr>
      <tr><td><a class="result-link" href="https://duckduckgo.com/y.js?ad_domain=x">Sponsored</a></td></tr>
      <tr><td class="result-snippet">Buy things.</td></tr>
      <tr><td><a class="result-link" href="https://github.com/mcass19/ex_ratatui">GitHub</a></td></tr>
    </table>
    """

    assert [
             %{
               url: "https://hexdocs.pm/ex_ratatui",
               title: "ExRatatui docs",
               snippet: "Elixir bindings for ratatui."
             },
             %{url: "https://github.com/mcass19/ex_ratatui", title: "GitHub", snippet: ""}
           ] = Web.parse_duckduckgo(html)
  end

  test "decodes Bing's click-tracking links" do
    target = "https://ai.google.dev/gemma/docs/releases"
    encoded = Base.url_encode64(target, padding: false)
    tracked = "https://www.bing.com/ck/a?!&&p=abc&ptn=3&u=a1#{encoded}&ntb=1"

    assert Web.unwrap_bing(tracked) == target
    assert Web.unwrap_bing("https://example.com/") == "https://example.com/"
  end

  test "extracts readable text without navigation, scripts or repeated lines" do
    html = """
    <html><head><title>Gemma releases</title><script>var x = 1;</script></head>
    <body>
      <nav><ul><li>Home</li><li>Docs</li></ul></nav>
      <main>
        <h1>Gemma <code>4</code></h1>
        <ul><li><p>Released April 2, 2026.</p></li></ul>
        <p>Apache 2.0 license.</p>
      </main>
      <footer><p>© Google</p></footer>
    </body></html>
    """

    page = Web.extract(html, "https://example.com")
    assert page.title == "Gemma releases"
    assert page.text == "Gemma 4\nReleased April 2, 2026.\nApache 2.0 license."
  end

  test "falls back to all text when a page doesn't use paragraphs or lists" do
    rows = Enum.map_join(1..20, "", &"<div><span>Row #{&1}: some app-rendered text</span></div>")
    page = Web.extract("<html><body><div id=app>#{rows}</div></body></html>", "https://x")
    assert page.text =~ "Row 1: some app-rendered text\nRow 2:"
  end
end
