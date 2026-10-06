defmodule KB.Parsers.HtmlTest do
  use ExUnit.Case, async: true

  alias KB.Parsers.Html

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures"])

  test "extracts content from article element" do
    html = File.read!(Path.join(@fixtures_dir, "sample_page.html"))
    {:ok, %{title: title, text: text}} = Html.parse(html)

    assert title == "Shape Up: Stop Running in Circles"
    assert text =~ "Shape Up"
    assert text =~ "product development methodology"
    assert text =~ "six-week build cycles"
    assert text =~ "Shaping is the pre-work"
    refute text =~ "tracking"
    refute text =~ "Copyright 2024"
    refute text =~ "Related Posts"
  end

  test "falls back to main element" do
    html = File.read!(Path.join(@fixtures_dir, "no_article.html"))
    {:ok, %{title: title, text: text}} = Html.parse(html)

    assert title == "Blog Post"
    assert text =~ "Main Content Area"
    assert text =~ "primary content"
    refute text =~ "Footer text"
  end

  test "falls back to role=main" do
    html = File.read!(Path.join(@fixtures_dir, "role_main.html"))
    {:ok, %{text: text}} = Html.parse(html)

    assert text =~ "Content with role=main"
    assert text =~ "accessibility"
    refute text =~ "Footer"
  end

  test "strips script, style, nav, footer, header, aside, form" do
    html = """
    <html>
    <head><title>Test</title></head>
    <body>
      <script>var x = 1;</script>
      <style>.red { color: red; }</style>
      <nav>Navigation</nav>
      <header>Header content</header>
      <article>
        <p>Real content here.</p>
        <form><input type="text" /></form>
      </article>
      <aside>Sidebar</aside>
      <footer>Footer</footer>
    </body>
    </html>
    """

    {:ok, %{text: text}} = Html.parse(html)
    assert text =~ "Real content here"
    refute text =~ "var x = 1"
    refute text =~ ".red"
    refute text =~ "Navigation"
    refute text =~ "Header content"
    refute text =~ "Sidebar"
    refute text =~ "Footer"
  end

  test "falls back to largest div when no article/main" do
    html = """
    <html>
    <head><title>Div Page</title></head>
    <body>
      <div>Small div</div>
      <div>
        <p>This is a much larger div with lots of content.</p>
        <p>It has multiple paragraphs of information.</p>
        <p>And should be selected as the main content area.</p>
      </div>
    </body>
    </html>
    """

    {:ok, %{text: text}} = Html.parse(html)
    assert text =~ "much larger div"
    assert text =~ "main content area"
  end

  test "returns nil title when no title tag" do
    html = "<html><body><p>No title</p></body></html>"
    {:ok, %{title: title}} = Html.parse(html)
    assert title == nil
  end

  test "decodes entities in the title" do
    html =
      "<html><head><title>Hatchet &amp; Co &#x27;s &quot;guide&quot; &mdash; part&nbsp;1</title></head><body><p>x</p></body></html>"

    {:ok, %{title: title}} = Html.parse(html)
    assert title == ~s(Hatchet & Co 's "guide" — part 1)
  end

  test "collapses whitespace in the title" do
    html =
      "<html><head><title>\n  Spread   out\n  title\n</title></head><body><p>x</p></body></html>"

    {:ok, %{title: title}} = Html.parse(html)
    assert title == "Spread out title"
  end
end
