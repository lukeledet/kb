defmodule KB.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/health" do
    body = Jason.encode!(%{status: "ok", version: "0.1.0"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  forward "/mcp", to: KB.MCP.Plug
  forward "/api", to: KB.API.Router

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not_found"}))
  end
end
