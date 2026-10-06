defmodule KB.Parsers.Epub do
  def parse(epub_path) when is_binary(epub_path) do
    with {:ok, files} <- unzip(epub_path),
         {:ok, opf_path} <- find_opf(files),
         {:ok, opf_content} <- Map.fetch(files, opf_path),
         {:ok, opf_doc} <- Floki.parse_document(opf_content),
         metadata <- extract_metadata(opf_doc),
         spine_ids <- extract_spine(opf_doc),
         manifest <- extract_manifest(opf_doc),
         spine_paths <- resolve_spine_paths(spine_ids, manifest, opf_path),
         texts <- extract_texts(spine_paths, files) do
      text = Enum.join(texts, "\n\n---\n\n")
      {:ok, %{text: text, metadata: metadata}}
    end
  end

  defp unzip(path) do
    charlist_path = String.to_charlist(path)

    case :zip.unzip(charlist_path, [:memory]) do
      {:ok, entries} ->
        files =
          Map.new(entries, fn {name, content} ->
            {to_string(name), to_string(content)}
          end)

        {:ok, files}

      {:error, reason} ->
        {:error, {:unzip_failed, reason}}
    end
  end

  defp find_opf(files) do
    case Map.get(files, "META-INF/container.xml") do
      nil ->
        {:error, :missing_container_xml}

      container_xml ->
        case Floki.parse_document(container_xml) do
          {:ok, doc} ->
            case Floki.find(doc, "rootfile") do
              [rootfile | _] ->
                case Floki.attribute(rootfile, "full-path") do
                  [path | _] -> {:ok, path}
                  [] -> {:error, :missing_rootfile_path}
                end

              [] ->
                {:error, :missing_rootfile}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp extract_metadata(opf_doc) do
    title =
      case Floki.find(opf_doc, "dc|title, dc\\:title, title") do
        [el | _] -> el |> Floki.text() |> String.trim()
        [] -> nil
      end

    author =
      case Floki.find(opf_doc, "dc|creator, dc\\:creator, creator") do
        [el | _] -> el |> Floki.text() |> String.trim()
        [] -> nil
      end

    %{title: title, author: author}
  end

  defp extract_spine(opf_doc) do
    opf_doc
    |> Floki.find("spine itemref")
    |> Enum.flat_map(fn el -> Floki.attribute(el, "idref") end)
  end

  defp extract_manifest(opf_doc) do
    opf_doc
    |> Floki.find("manifest item")
    |> Map.new(fn item ->
      id = item |> Floki.attribute("id") |> List.first("")
      href = item |> Floki.attribute("href") |> List.first("")
      {id, href}
    end)
  end

  defp resolve_spine_paths(spine_ids, manifest, opf_path) do
    opf_dir = Path.dirname(opf_path)

    Enum.flat_map(spine_ids, fn id ->
      case Map.get(manifest, id) do
        nil -> []
        href -> [Path.join(opf_dir, href) |> normalize_path()]
      end
    end)
  end

  defp normalize_path(path) do
    path
    |> String.split("/")
    |> Enum.reduce([], fn
      ".", acc -> acc
      "..", [_ | rest] -> rest
      "..", [] -> []
      segment, acc -> [segment | acc]
    end)
    |> Enum.reverse()
    |> Enum.join("/")
  end

  defp extract_texts(spine_paths, files) do
    Enum.flat_map(spine_paths, fn path ->
      case Map.get(files, path) do
        nil -> []
        content -> [extract_text_from_xhtml(content)]
      end
    end)
  end

  defp extract_text_from_xhtml(xhtml) do
    case Floki.parse_document(xhtml) do
      {:ok, doc} ->
        doc
        |> Floki.filter_out("style")
        |> Floki.filter_out("script")
        |> Floki.find("body")
        |> case do
          [body | _] -> body
          [] -> doc
        end
        |> Floki.text(sep: "\n")
        |> String.replace(~r/[ \t]+/, " ")
        |> String.replace(~r/\n{3,}/, "\n\n")
        |> String.trim()

      _ ->
        ""
    end
  end
end
