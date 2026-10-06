defmodule KB.MCP.Plug do
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    runtime_opts =
      Anubis.Server.Transport.StreamableHTTP.Plug.init(Keyword.put(opts, :server, KB.MCP.Server))

    Anubis.Server.Transport.StreamableHTTP.Plug.call(conn, runtime_opts)
  end
end
