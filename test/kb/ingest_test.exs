defmodule KB.IngestTest do
  # async: false because it swaps the global :arcana embedder config.
  use KB.DataCase, async: false

  alias KB.Repo

  defmodule FailingEmbedder do
    @behaviour Arcana.Embedder

    @impl true
    def embed(_text, _opts \\ []), do: {:error, :boom}

    @impl true
    def embed_batch(_texts, _opts \\ []), do: {:error, {:request_failed, :timeout}}

    @impl true
    def dimensions(_opts \\ []), do: 4096
  end

  setup do
    prev = Application.get_env(:arcana, :embedder)
    Application.put_env(:arcana, :embedder, FailingEmbedder)
    on_exit(fn -> Application.put_env(:arcana, :embedder, prev) end)
    :ok
  end

  test "deletes the document and stores no chunks when embedding fails" do
    source_id = Ecto.UUID.generate()

    assert {:error, {:embedding_failed, _}} =
             KB.Ingest.ingest("some text that will be chunked and embedded",
               repo: Repo,
               source_id: source_id,
               collection: "kb"
             )

    # No orphaned document is left behind for the failed attempt...
    docs = Repo.query!("SELECT count(*) FROM arcana_documents WHERE source_id = $1", [source_id])
    assert docs.rows == [[0]]

    # ...and no partial chunks were written (all-or-nothing).
    chunks =
      Repo.query!(
        "SELECT count(*) FROM arcana_chunks c " <>
          "JOIN arcana_documents d ON d.id = c.document_id WHERE d.source_id = $1",
        [source_id]
      )

    assert chunks.rows == [[0]]
  end
end
