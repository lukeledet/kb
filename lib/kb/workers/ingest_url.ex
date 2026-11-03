defmodule KB.Workers.IngestUrl do
  use Oban.Worker, queue: :ingestion, max_attempts: 5

  alias KB.Sources
  alias KB.Parsers.{Html, Pdf}
  alias KB.Tagger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case Sources.get_source(args["source_id"]) do
      nil -> {:cancel, :source_deleted}
      source -> run(source)
    end
  end

  # A raise, such as a database error inside the insert, would skip the
  # failure handling in ingest/1 and leave the source "processing" for good.
  # Record it, then re-raise so Oban keeps the stacktrace and still retries.
  defp run(source) do
    ingest(source)
  rescue
    exception ->
      Sources.mark_failed(source.id, Exception.message(exception))
      reraise exception, __STACKTRACE__
  end

  defp ingest(source) do
    with {:ok, source} <- Sources.update_source_if_present(source, %{status: "processing"}),
         {:ok, body, content_type} <- fetch_url(source.url),
         {:ok, parsed} <- parse_page(body, content_type),
         content_hash <- hash_content(parsed.text),
         {:ok, source} <- save_page(source, parsed, content_hash),
         source <- Tagger.maybe_auto_tag(source, parsed.text),
         {:ok, document} <- ingest_text(parsed.text, source),
         {:ok, _source} <-
           Sources.update_source_if_present(source, %{
             status: "completed",
             arcana_document_id: document.id,
             chunk_count: document.chunk_count,
             error: nil
           }) do
      :ok
    else
      # Deleted mid-flight (a --force re-ingest, or a manual delete). There is
      # nothing left to record the failure against, so cancel rather than burn
      # the retry budget failing the same way five times.
      {:error, :source_deleted} ->
        {:cancel, :source_deleted}

      # Another source already holds this exact text. Retrying fetches the same
      # page and hits the same clash, so record why and stop.
      {:error, {:duplicate_content, content_hash}} ->
        Sources.mark_failed(source.id, duplicate_error(content_hash))
        {:cancel, :duplicate_content}

      {:error, reason} ->
        Sources.mark_failed(source.id, inspect(reason))
        {:error, reason}
    end
  end

  defp fetch_url(url) do
    req_opts = [url: url, receive_timeout: 30_000, max_redirects: 5]

    req_opts =
      case Application.get_env(:kb, :req_options) do
        nil -> req_opts
        extra -> Keyword.merge(req_opts, extra)
      end

    case Req.get(req_opts) do
      {:ok, %Req.Response{status: 200, body: body} = response} when is_binary(body) ->
        {:ok, body, List.first(Req.Response.get_header(response, "content-type"), "")}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, exception} ->
        {:error, {:request_failed, exception}}
    end
  end

  # A URL can point at a PDF as well as a web page. Trust the file signature
  # over the header, since servers often send PDFs as application/octet-stream.
  defp parse_page(body, content_type) do
    if Pdf.pdf?(body) or String.starts_with?(content_type, "application/pdf") do
      parse_pdf(body)
    else
      parse_html(body)
    end
  end

  defp parse_pdf(body) do
    case Pdf.parse(body) do
      {:ok, text} -> {:ok, %{title: nil, text: KB.Text.sanitize(text)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_html(body) do
    case Html.parse(body) do
      {:ok, parsed} -> {:ok, %{parsed | text: KB.Text.sanitize(parsed.text)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp save_page(source, parsed, content_hash) do
    case Sources.update_source_if_present(source, page_attrs(source, parsed, content_hash)) do
      {:error, %Ecto.Changeset{errors: errors}} = error ->
        if Keyword.has_key?(errors, :content_hash),
          do: {:error, {:duplicate_content, content_hash}},
          else: error

      result ->
        result
    end
  end

  defp duplicate_error(content_hash) do
    case Sources.find_by_content_hash(content_hash) do
      nil -> "Page content matches another source"
      existing -> "Page content matches source #{existing.id} (#{existing.title})"
    end
  end

  defp hash_content(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  # Applied before ingest_text/2 so the chunks are tagged with the page's real
  # title rather than the URL we defaulted to at creation time.
  defp page_attrs(source, parsed, content_hash) do
    attrs = %{content_hash: content_hash}

    case clean(parsed[:title]) do
      nil ->
        attrs

      title ->
        if Sources.placeholder_title?(source), do: Map.put(attrs, :title, title), else: attrs
    end
  end

  defp clean(nil), do: nil

  defp clean(value) when is_binary(value) do
    case value |> KB.Text.sanitize() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp ingest_text(text, source) do
    KB.Ingest.ingest(text,
      repo: KB.Repo,
      source_id: source.id,
      metadata: %{title: source.title, url: source.url},
      collection: "kb"
    )
  end
end
