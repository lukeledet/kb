Postgrex.Types.define(
  KB.PostgrexTypes,
  [Pgvector.Extensions.Vector, Pgvector.Extensions.Halfvec, Pgvector.Extensions.Sparsevec] ++
    Ecto.Adapters.Postgres.extensions(),
  []
)
