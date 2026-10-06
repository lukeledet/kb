defmodule KB.TaggerTest do
  use KB.DataCase

  alias KB.Sources
  alias KB.Tagger

  setup do
    System.put_env("OPENROUTER_API_KEY", "test-key")
    :ok
  end

  defp stub_content(content) do
    Req.Test.stub(Tagger, fn conn ->
      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => content}}]})
    end)

    [plug: {Req.Test, Tagger}]
  end

  describe "suggest/2" do
    test "returns normalized tags from a JSON array" do
      opts = stub_content(~s(["Elixir", "Machine Learning", "elixir"]))

      assert {:ok, ["elixir", "machine-learning"]} = Tagger.suggest("some text", opts)
    end

    test "pulls the array out of surrounding prose or a fence" do
      opts = stub_content("```json\n[\"phoenix\"]\n```")

      assert {:ok, ["phoenix"]} = Tagger.suggest("some text", opts)
    end

    test "returns no tags when the model answers with nothing usable" do
      opts = stub_content("I could not determine any tags.")

      assert {:ok, []} = Tagger.suggest("some text", opts)
    end

    test "reports an API error" do
      Req.Test.stub(Tagger, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      assert {:error, {:api_error, 500, _}} =
               Tagger.suggest("some text", plug: {Req.Test, Tagger})
    end
  end

  describe "maybe_auto_tag/2" do
    setup do
      Application.put_env(:kb, :tagger, KB.Test.FakeTagger)
      Application.put_env(:kb, :fake_tags, ["elixir"])
      on_exit(fn -> Application.delete_env(:kb, :fake_tags) end)
      :ok
    end

    test "fills in tags when the source has none" do
      {:ok, source} = Sources.create_source(%{title: "Doc", source_type: "text"})

      assert %{tags: ["elixir"]} = Tagger.maybe_auto_tag(source, "text")
      assert Sources.get_source!(source.id).tags == ["elixir"]
    end

    test "leaves caller-supplied tags alone" do
      {:ok, source} = Sources.create_source(%{title: "Doc", source_type: "text", tags: ["mine"]})

      assert %{tags: ["mine"]} = Tagger.maybe_auto_tag(source, "text")
    end

    test "returns the source unchanged when suggestion finds nothing" do
      Application.put_env(:kb, :fake_tags, [])
      {:ok, source} = Sources.create_source(%{title: "Doc", source_type: "text"})

      assert %{tags: []} = Tagger.maybe_auto_tag(source, "text")
    end
  end
end
