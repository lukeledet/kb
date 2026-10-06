defmodule KB.MixProject do
  use Mix.Project

  def project do
    [
      app: :kb,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {KB.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:pgvector, "~> 0.4"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.0"},
      {:plug, "~> 1.18"},
      {:req, "~> 0.7"},
      {:floki, "~> 0.38"},
      {:arcana, "~> 4.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:anubis_mcp, "~> 2.0"},
      {:oban, "~> 2.24"},
      {:decimal, "~> 3.1"},
      {:yaml_elixir, "~> 2.12"}
    ]
  end

  defp releases do
    [
      kb: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
