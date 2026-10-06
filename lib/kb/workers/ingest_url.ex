defmodule KB.Workers.IngestUrl do
  use Oban.Worker, queue: :ingestion, max_attempts: 5

  alias KB.Sources
  alias KB.Parsers.Html
  alias KB.Tagger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case Sources.get_source(args["source_id"]) do
      nil -> {:cancel, :source_deleted}
      source -> ingest(source)
    end
  end

  defp ingest(source) do
    with {:ok, source} <- Sources.update_source_if_present(source, %{status: "processing"}),
         {:ok, html} <- fetch_url(source.url),
         {:ok, parsed} <- Html.parse(html),
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
        Sources.update_source_if_present(source, %{
          status: "failed",
          error: duplicate_error(content_hash)
        })

        {:cancel, :duplicate_content}

      {:error, reason} ->
        Sources.update_source_if_present(source, %{
          status: "failed",
          error: inspect(reason)
        })

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
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, exception} ->
        {:error, {:request_failed, exception}}
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
    case String.trim(value) do
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
