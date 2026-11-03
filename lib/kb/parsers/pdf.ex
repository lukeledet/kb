defmodule KB.Parsers.Pdf do
  @moduledoc """
  Extracts text from PDF bytes with `Arcana.Parser`, which reads from a file.
  """

  @doc """
  Returns true when `content` starts with the PDF file signature.
  """
  def pdf?(<<"%PDF-", _rest::binary>>), do: true
  def pdf?(_content), do: false

  @doc """
  Writes `content` to a temporary file, parses it, and removes the file.

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  def parse(content) when is_binary(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "kb_pdf_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}.pdf"
      )

    try do
      File.write!(path, content)
      Arcana.Parser.parse(path)
    after
      File.rm(path)
    end
  end
end
