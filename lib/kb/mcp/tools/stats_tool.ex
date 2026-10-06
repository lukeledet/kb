defmodule KB.MCP.Tools.StatsTool do
  @moduledoc """
  Get aggregate statistics about the knowledge base, and how recent searches
  went: how many degraded and why, latency, and each embedding backend's speed
  """
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.Sources

  schema do
  end

  @impl true
  def execute(_params, frame) do
    response = Jason.encode!(Map.put(Sources.stats(), :search, KB.Search.Stats.snapshot()))
    {:reply, Response.text(Response.tool(), response), frame}
  end
end
