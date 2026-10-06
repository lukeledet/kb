defmodule KB.MCP.Server do
  use Anubis.Server,
    name: "kb",
    version: "0.1.0",
    capabilities: [:tools]

  component(KB.MCP.Tools.SearchTool)
  component(KB.MCP.Tools.IngestUrlTool)
  component(KB.MCP.Tools.IngestFileTool)
  component(KB.MCP.Tools.ListSourcesTool)
  component(KB.MCP.Tools.GetSourceTool)
  component(KB.MCP.Tools.DeleteSourceTool)
  component(KB.MCP.Tools.UpdateTagsTool)
  component(KB.MCP.Tools.ListTagsTool)
  component(KB.MCP.Tools.GetChunksTool)
  component(KB.MCP.Tools.FindRelatedTool)
  component(KB.MCP.Tools.StatsTool)
  component(KB.MCP.Tools.GetDocumentTool)
  component(KB.MCP.Tools.MultiGetTool)
  component(KB.MCP.Tools.UpsertDocumentTool)
  component(KB.MCP.Tools.DeleteDocumentTool)
  component(KB.MCP.Tools.CollectionStatusTool)
  component(KB.MCP.Tools.BacklinksTool)
  component(KB.MCP.Tools.OutlinksTool)
  component(KB.MCP.Tools.LinkReportTool)

  @impl true
  def init(_client_info, frame) do
    {:ok, frame}
  end
end
