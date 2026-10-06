defmodule KB.MCP.AsyncTest do
  use ExUnit.Case, async: true

  # Two tests crash their task on purpose; their reports are expected noise.
  @moduletag :capture_log

  alias KB.MCP.Async

  describe "run/2" do
    test "returns the function's value" do
      assert Async.run(fn -> {:ok, :done} end) == {:ok, :done}
    end

    test "returns {:error, :timeout} when the work outlives its budget" do
      assert Async.run(fn -> Process.sleep(:infinity) end, 50) == {:error, :timeout}
    end

    test "caller survives work that crashes" do
      assert {:error, {:exit, _reason}} = Async.run(fn -> raise "boom" end)
      assert Process.alive?(self())
    end

    test "caller survives work that exits" do
      assert {:error, {:exit, _reason}} = Async.run(fn -> exit(:kaboom) end)
      assert Process.alive?(self())
    end

    test "abandoned work is killed rather than left running" do
      parent = self()

      Async.run(
        fn ->
          Process.send(parent, {:started, self()}, [])
          Process.sleep(:infinity)
        end,
        50
      )

      assert_receive {:started, worker}
      # The task must not outlive the timeout, or a stalled OpenRouter call
      # would keep burning a connection after the caller has given up.
      Process.sleep(50)
      refute Process.alive?(worker)
    end
  end
end
