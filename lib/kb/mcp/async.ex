defmodule KB.MCP.Async do
  @moduledoc """
  Runs blocking tool work outside the shared `KB.MCP.Server` process.

  Anubis serializes every session's tool calls through a single server
  GenServer, and the Streamable HTTP transport abandons its `GenServer.call`
  after 30s. A tool body that blocks longer than that leaves the server
  process still working on a request nobody is waiting for, so every later
  call — including calls from brand new sessions — queues behind it and times
  out too. MCP then stays down until the app restarts.

  Tools that touch the network or run heavy queries call `run/2` so the work
  happens in a task the server can walk away from, with a budget below the
  transport's timeout to leave room to report a clean error.
  """

  @default_timeout 25_000

  @doc """
  Runs `fun` in a supervised task, returning `{:error, :timeout}` if it
  outlives `timeout` (default #{@default_timeout}ms).

  The task is unlinked, so a crash surfaces as `{:error, {:exit, reason}}`
  rather than taking the MCP server down with it.
  """
  def run(fun, timeout \\ @default_timeout) when is_function(fun, 0) do
    task = Task.Supervisor.async_nolink(KB.TaskSupervisor, fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}}
      nil -> {:error, :timeout}
    end
  end
end
