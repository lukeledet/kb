defmodule KB.Sources.SourceTest do
  use KB.DataCase, async: true

  alias KB.Sources.Source

  describe "changeset/2" do
    test "valid with required fields" do
      cs = Source.changeset(%Source{}, %{title: "Test", source_type: "url"})
      assert cs.valid?
    end

    test "valid with all fields" do
      cs =
        Source.changeset(%Source{}, %{
          title: "Shape Up",
          url: "https://example.com/shape-up",
          source_type: "url",
          tags: ["product-dev", "basecamp"],
          metadata: %{"author" => "Ryan Singer"}
        })

      assert cs.valid?
    end

    test "invalid without title" do
      cs = Source.changeset(%Source{}, %{source_type: "url"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).title
    end

    test "invalid without source_type" do
      cs = Source.changeset(%Source{}, %{title: "Test"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).source_type
    end

    test "invalid with unknown source_type" do
      cs = Source.changeset(%Source{}, %{title: "Test", source_type: "video"})
      refute cs.valid?
      assert "is invalid" in errors_on(cs).source_type
    end

    test "invalid with unknown status" do
      cs = Source.changeset(%Source{}, %{title: "Test", source_type: "url", status: "unknown"})
      refute cs.valid?
      assert "is invalid" in errors_on(cs).status
    end

    test "valid source_types" do
      for type <- ~w(url pdf epub text transcript) do
        cs = Source.changeset(%Source{}, %{title: "Test", source_type: type})
        assert cs.valid?, "expected #{type} to be valid"
      end
    end

    test "valid statuses" do
      for status <- ~w(pending processing completed failed) do
        cs = Source.changeset(%Source{}, %{title: "Test", source_type: "url", status: status})
        assert cs.valid?, "expected #{status} to be valid"
      end
    end

    test "can insert into database" do
      cs = Source.changeset(%Source{}, %{title: "Test", source_type: "url"})
      assert {:ok, source} = Repo.insert(cs)
      assert source.id
      assert source.status == "pending"
      assert source.tags == []
      assert source.chunk_count == 0
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
