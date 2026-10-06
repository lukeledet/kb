defmodule KB.Parsers.EpubTest do
  use ExUnit.Case, async: true

  alias KB.Parsers.Epub

  setup do
    epub_path = create_test_epub()
    on_exit(fn -> File.rm(epub_path) end)
    {:ok, epub_path: epub_path}
  end

  test "parses epub and extracts text in spine order", %{epub_path: epub_path} do
    {:ok, %{text: text, metadata: metadata}} = Epub.parse(epub_path)

    assert metadata.title == "Test Book"
    assert metadata.author == "Test Author"

    assert text =~ "Chapter One"
    assert text =~ "This is the first chapter content."
    assert text =~ "Chapter Two"
    assert text =~ "This is the second chapter content."

    # Chapters should appear in spine order
    ch1_pos = :binary.match(text, "Chapter One") |> elem(0)
    ch2_pos = :binary.match(text, "Chapter Two") |> elem(0)
    assert ch1_pos < ch2_pos
  end

  test "returns error for non-epub file" do
    tmp = Path.join(System.tmp_dir!(), "not_an_epub.epub")
    File.write!(tmp, "not a zip file")
    on_exit(fn -> File.rm(tmp) end)

    assert {:error, _} = Epub.parse(tmp)
  end

  defp create_test_epub do
    container_xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    content_opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>Test Book</dc:title>
        <dc:creator>Test Author</dc:creator>
      </metadata>
      <manifest>
        <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
        <item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
      </manifest>
      <spine>
        <itemref idref="ch1"/>
        <itemref idref="ch2"/>
      </spine>
    </package>
    """

    chapter1 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>Chapter 1</title></head>
    <body>
      <h1>Chapter One</h1>
      <p>This is the first chapter content.</p>
      <p>It has multiple paragraphs of text.</p>
    </body>
    </html>
    """

    chapter2 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>Chapter 2</title></head>
    <body>
      <h1>Chapter Two</h1>
      <p>This is the second chapter content.</p>
      <p>The story continues here.</p>
    </body>
    </html>
    """

    files = [
      {~c"META-INF/container.xml", container_xml},
      {~c"OEBPS/content.opf", content_opf},
      {~c"OEBPS/chapter1.xhtml", chapter1},
      {~c"OEBPS/chapter2.xhtml", chapter2}
    ]

    epub_path =
      Path.join(System.tmp_dir!(), "test_book_#{System.unique_integer([:positive])}.epub")

    {:ok, _} = :zip.create(String.to_charlist(epub_path), files)
    epub_path
  end
end
