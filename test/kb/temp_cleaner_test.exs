defmodule KB.TempCleanerTest do
  use ExUnit.Case, async: true

  alias KB.TempCleaner

  test "sweep removes old kb_ingest_ files" do
    tmp_dir = System.tmp_dir!()
    old_file = Path.join(tmp_dir, "kb_ingest_old_test_#{System.unique_integer([:positive])}.bin")
    File.write!(old_file, "old content")

    # Set file mtime to 25 hours ago
    old_time = System.os_time(:second) - 25 * 60 * 60
    File.touch!(old_file, old_time)

    on_exit(fn -> File.rm(old_file) end)

    TempCleaner.sweep()

    refute File.exists?(old_file)
  end

  test "sweep keeps recent kb_ingest_ files" do
    tmp_dir = System.tmp_dir!()

    recent_file =
      Path.join(tmp_dir, "kb_ingest_recent_test_#{System.unique_integer([:positive])}.bin")

    File.write!(recent_file, "recent content")

    on_exit(fn -> File.rm(recent_file) end)

    TempCleaner.sweep()

    assert File.exists?(recent_file)
  end

  test "sweep ignores non-kb files" do
    tmp_dir = System.tmp_dir!()
    other_file = Path.join(tmp_dir, "other_file_#{System.unique_integer([:positive])}.bin")
    File.write!(other_file, "other content")

    # Even if old
    old_time = System.os_time(:second) - 25 * 60 * 60
    File.touch!(other_file, old_time)

    on_exit(fn -> File.rm(other_file) end)

    TempCleaner.sweep()

    assert File.exists?(other_file)
  end
end
