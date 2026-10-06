defmodule KB.Search.ParamsTest do
  use ExUnit.Case, async: true

  alias KB.Search.Params

  test "defaults to hybrid chunk search" do
    assert {:ok, "q", opts} = Params.parse(%{"query" => "q"})
    assert opts[:mode] == :hybrid
    assert opts[:group_by] == :chunk
    assert opts[:limit] == 10
    assert opts[:offset] == 0
    refute Keyword.has_key?(opts, :rerank)
  end

  test "reads every option, from string or atom keys" do
    assert {:ok, "q", opts} =
             Params.parse(%{
               query: "q",
               mode: "fulltext",
               group_by: "document",
               limit: 500,
               offset: 20,
               rerank: false,
               rerank_top_n: 15,
               collection: "wiki",
               collections: ["library", "wiki"],
               full_frontmatter: true,
               latency_budget_ms: 9_000,
               source_type: ["markdown", "text"],
               key_prefix: "concepts/",
               tags: "a, b",
               frontmatter: %{"type" => "concept"},
               updated_after: "2026-09-01"
             })

    assert opts[:mode] == :keyword
    assert opts[:group_by] == :document
    assert opts[:limit] == 100
    assert opts[:offset] == 20
    assert opts[:rerank] == false
    assert opts[:rerank_top_n] == 15
    assert opts[:collections] == ["wiki", "library"]
    assert opts[:full_frontmatter] == true
    assert opts[:latency_budget_ms] == 5_000
    assert opts[:source_types] == ["markdown", "text"]
    assert opts[:key_prefix] == "concepts/"
    assert opts[:tags] == ["a", "b"]
    assert opts[:frontmatter] == %{"type" => "concept"}
    assert opts[:updated_after] == ~U[2026-09-01 00:00:00Z]
  end

  test "rejects bad values instead of ignoring them" do
    assert {:error, "query field is required"} = Params.parse(%{})
    assert {:error, "query field is required"} = Params.parse(%{"query" => "   "})

    assert {:error, "mode must be one of" <> _} =
             Params.parse(%{"query" => "q", "mode" => "fuzzy"})

    assert {:error, "limit must be" <> _} = Params.parse(%{"query" => "q", "limit" => 0})

    assert {:error, "frontmatter must be" <> _} =
             Params.parse(%{"query" => "q", "frontmatter" => "x"})

    assert {:error, "updated_after must be" <> _} =
             Params.parse(%{"query" => "q", "updated_after" => "soon"})

    assert {:error, "rerank must be" <> _} = Params.parse(%{"query" => "q", "rerank" => "yes"})

    assert {:error, "latency_budget_ms must be" <> _} =
             Params.parse(%{"query" => "q", "latency_budget_ms" => 100})
  end
end
