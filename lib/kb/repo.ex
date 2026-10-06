defmodule KB.Repo do
  use Ecto.Repo,
    otp_app: :kb,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_type, config) do
    config =
      Keyword.update(
        config,
        :after_connect,
        &set_hnsw_ef_search/1,
        fn _existing -> &set_hnsw_ef_search/1 end
      )

    {:ok, config}
  end

  defp set_hnsw_ef_search(conn) do
    Postgrex.query!(conn, "SET hnsw.ef_search = 100", [])
  end
end
