defmodule KB.Test.FakeTagger do
  @moduledoc """
  Stands in for KB.Tagger in tests so ingestion never calls OpenRouter.

  Returns whatever a test put in `:fake_tags` (default: none).
  """

  def suggest(_text, _opts \\ []) do
    {:ok, Application.get_env(:kb, :fake_tags, [])}
  end
end
