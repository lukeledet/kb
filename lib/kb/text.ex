defmodule KB.Text do
  @moduledoc """
  Cleans extracted text before it is stored.

  Parsers return whatever bytes the source held. A PDF or a pasted
  transcript can carry a NUL byte, which a Postgres `text` column rejects,
  and stray control characters that only add noise to chunks.
  """

  # C0 control characters, except tab, newline, form feed, and carriage
  # return. pdftotext separates pages with a form feed.
  @controls ~r/[\x00-\x08\x0B\x0E-\x1F]/

  @doc """
  Returns `text` as valid UTF-8 with NUL and other control characters removed.

  Invalid byte sequences become U+FFFD. Tab, newline, form feed, and carriage
  return are kept.

      iex> KB.Text.sanitize("a\\u0000b\\tc")
      "ab\\tc"
  """
  @spec sanitize(binary()) :: String.t()
  def sanitize(text) when is_binary(text) do
    text
    |> String.replace_invalid()
    |> String.replace(@controls, "")
  end
end
