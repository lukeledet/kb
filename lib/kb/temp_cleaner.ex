defmodule KB.TempCleaner do
  use Task, restart: :temporary

  @max_age_seconds 24 * 60 * 60

  def start_link(_opts) do
    Task.start_link(__MODULE__, :sweep, [])
  end

  def sweep do
    tmp_dir = System.tmp_dir!()
    now = System.os_time(:second)

    case File.ls(tmp_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, "kb_ingest_"))
        |> Enum.each(fn file ->
          path = Path.join(tmp_dir, file)

          with {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix) do
            if now - mtime > @max_age_seconds do
              File.rm(path)
            end
          end
        end)

      {:error, _} ->
        :ok
    end
  end
end
