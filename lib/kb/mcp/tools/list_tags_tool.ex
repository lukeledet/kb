defmodule KB.MCP.Tools.ListTagsTool do
  @moduledoc "List all tags used across sources with their counts"
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias KB.Sources

  schema do
  end

  @impl true
  def execute(_params, frame) do
    tags = Sources.list_tags()
    response = Jason.encode!(%{tags: tags})
    {:reply, Response.text(Response.tool(), response), frame}
  end
end
