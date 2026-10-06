defmodule KB.Repo.Migrations.AddObanPro do
  use Ecto.Migration

  # Historical no-op. This once ran Oban.Pro.Migration.up() for the Smart
  # engine, but the app never used a Pro feature: the queues were always
  # static and the workers only used core Oban (uniqueness with keys, custom
  # backoff). Oban Pro was swapped for core Oban's default Basic engine, and
  # the oban_pro dependency was dropped so the repo builds for anyone.
  #
  # Databases that already ran the Pro migration keep the extra tables
  # (oban_producers, oban_crons, oban_queues) and the generated columns on
  # oban_jobs; the Basic engine ignores all of them, and they can be dropped
  # by hand. Fresh databases never needed any of it: the core Oban migrations
  # (AddOban, UpdateObanToV14) create everything this app uses.
  def up, do: :ok

  def down, do: :ok
end
