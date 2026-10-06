defmodule KB.Workers.SyncDocument do
  @moduledoc """
  Indexes one version of a keyed document and swaps it in. See
  `KB.Documents.index/4`.

  Runs on its own `sync` queue so a page edit never waits behind a book in
  the `ingestion` queue. The text rides in the job args rather than a temp
  file, because temp files do not survive a redeploy.

  One job per version: a second upsert of text that is already queued or
  running joins the existing job instead of adding another.
  """

  use Oban.Worker,
    queue: :sync,
    max_attempts: 5,
    unique: [
      fields: [:args, :worker],
      keys: [:source_id, :content_hash],
      states: :incomplete,
      period: :infinity
    ]

  alias KB.Documents

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    %{"source_id" => source_id, "content_hash" => hash, "content" => content} = args

    case index(source_id, hash, content, args["attrs"] || %{}) do
      :ok ->
        :ok

      {:cancel, reason} ->
        {:cancel, reason}

      {:error, reason} ->
        Documents.record_failure(source_id, hash, reason, attempt >= max_attempts)
        {:error, reason}
    end
  end

  # A crash is a failed attempt like any other. Left to Oban, it would skip
  # record_failure/4 and leave the document "processing" for good.
  defp index(source_id, hash, content, attrs) do
    Documents.index(source_id, hash, content, attrs)
  rescue
    exception -> {:error, exception}
  end

  # A caller is often waiting on a page edit, so retry within seconds rather
  # than Oban's default of minutes: 10, 20, 40, then 80 seconds.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: 5 * Integer.pow(2, attempt)
end
