defmodule KB.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias KB.Router

  @opts Router.init([])

  test "GET /health returns 200 with status ok" do
    conn =
      conn(:get, "/health")
      |> Router.call(@opts)

    assert conn.status == 200
    assert %{"status" => "ok", "version" => "0.1.0"} = Jason.decode!(conn.resp_body)
  end

  test "unknown route returns 404" do
    conn =
      conn(:get, "/nonexistent")
      |> Router.call(@opts)

    assert conn.status == 404
  end
end
