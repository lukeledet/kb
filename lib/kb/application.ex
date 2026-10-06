defmodule KB.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:kb, :port, 4000)

    children = [
      KB.Repo,
      {Oban, Application.fetch_env!(:kb, Oban)},
      {KB.MCP.Server, transport: {:streamable_http, [start: true]}},
      {Bandit, plug: KB.Router, port: port},
      {Task.Supervisor, name: KB.TaskSupervisor},
      KB.Embedder.QueryCache,
      KB.Search.Stats,
      KB.TempCleaner
    ]

    opts = [strategy: :one_for_one, name: KB.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
