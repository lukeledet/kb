defmodule KB.TextTest do
  use ExUnit.Case, async: true

  doctest KB.Text

  alias KB.Text

  test "removes NUL and other control characters" do
    assert Text.sanitize("a\u0000b\u0001c\u001Fd\u000Be") == "abcde"
  end

  test "keeps tab, newline, form feed, and carriage return" do
    assert Text.sanitize("a\tb\nc\fd\r\n") == "a\tb\nc\fd\r\n"
  end

  test "replaces invalid UTF-8 with U+FFFD" do
    assert Text.sanitize(<<"a", 0xFF, "b">>) == "a�b"
  end

  test "leaves clean text alone" do
    text = "Plain text with ünïcödé and emoji 🙂."
    assert Text.sanitize(text) == text
  end
end
