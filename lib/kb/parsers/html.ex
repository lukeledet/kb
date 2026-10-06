defmodule KB.Parsers.Html do
  @strip_tags ~w(script style nav footer header aside form)

  def parse(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        title = extract_title(document)
        text = extract_content(document)
        {:ok, %{title: title, text: text}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_title(document) do
    case Floki.find(document, "title") do
      [title_el | _] -> title_el |> Floki.text() |> decode_entities() |> normalize_title()
      [] -> nil
    end
  end

  # The parser treats <title> as raw text, so entities inside it survive
  # undecoded ("The startup&#x27;s guide") — unlike body text, which is decoded
  # during parsing. Running the string back through the parser reuses that same
  # decoder instead of maintaining an entity table here.
  defp decode_entities(text) do
    case Floki.parse_fragment(text) do
      {:ok, fragment} -> Floki.text(fragment)
      {:error, _} -> text
    end
  end

  defp normalize_title(text) do
    text
    |> String.replace(" ", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp extract_content(document) do
    cleaned = strip_elements(document)

    content_root =
      find_content_element(cleaned, "article") ||
        find_content_element(cleaned, "main") ||
        find_content_element(cleaned, "[role=main]") ||
        find_largest_div(cleaned) ||
        find_content_element(cleaned, "body") ||
        cleaned

    content_root
    |> Floki.text(sep: "\n")
    |> normalize_whitespace()
  end

  defp strip_elements(document) do
    Enum.reduce(@strip_tags, document, fn tag, doc ->
      Floki.filter_out(doc, tag)
    end)
  end

  defp find_content_element(document, selector) do
    case Floki.find(document, selector) do
      [element | _] -> element
      [] -> nil
    end
  end

  defp find_largest_div(document) do
    document
    |> Floki.find("div")
    |> Enum.max_by(fn div -> div |> Floki.text() |> String.length() end, fn -> nil end)
  end

  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
