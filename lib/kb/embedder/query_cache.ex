defmodule KB.Embedder.QueryCache do
  @moduledoc """
  Remembers the embeddings of recent search queries.

  Query embedding latency depends on outside providers and jumps from 0.2 s
  to over a second from one call to the next. A repeated query, such as a
  QA set run twice or an agent retrying a search, gets its embedding from
  here instead, at once and without spending a request.

  Entries are keyed by the exact query text. The table holds at most
  `@max_entries`; past that, the oldest entries are dropped. Each embedding
  is stored as 4-byte floats, 16 KB for 4,096 dimensions, so the cache stays
  under about 16 MB.
  """

  use GenServer

  @table __MODULE__
  @max_entries 1_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The cached embedding for `text`, or `nil`."
  def get(text) do
    case :ets.lookup(@table, text) do
      [{^text, binary, _seq}] -> for <<value::float-32-native <- binary>>, do: value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Caches `embedding` for `text`."
  def put(text, embedding) do
    GenServer.cast(
      __MODULE__,
      {:put, text, for(v <- embedding, into: <<>>, do: <<v::float-32-native>>)}
    )
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])
    {:ok, 0}
  end

  @impl true
  def handle_cast({:put, text, binary}, seq) do
    :ets.insert(@table, {text, binary, seq})
    oldest = seq - @max_entries

    if oldest >= 0,
      do: :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", oldest}], [true]}])

    {:noreply, seq + 1}
  end
end
