defmodule KB.RaceTest do
  use ExUnit.Case, async: true

  alias KB.Race

  defp after_ms(ms, result), do: fn -> Process.sleep(ms) && result end

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {div(us, 1000), result}
  end

  test "returns the first success" do
    {ms, result} =
      timed(fn ->
        Race.first_ok([{0, after_ms(300, {:ok, :slow})}, {0, after_ms(10, {:ok, :fast})}])
      end)

    assert result == {:ok, :fast}
    assert ms < 200
  end

  test "starts a scheduled attempt only when the earlier one is slow" do
    test = self()

    hedge = fn ->
      send(test, :hedge_started)
      {:ok, :hedge}
    end

    assert Race.first_ok([{0, after_ms(10, {:ok, :first})}, {200, hedge}]) == {:ok, :first}
    refute_receive :hedge_started, 300

    {ms, result} =
      timed(fn -> Race.first_ok([{0, after_ms(1_000, {:ok, :first})}, {50, hedge}]) end)

    assert result == {:ok, :hedge}
    assert ms < 500
  end

  test "brings the next attempt forward when one fails" do
    {ms, result} =
      timed(fn ->
        Race.first_ok([{0, fn -> {:error, :boom} end}, {5_000, fn -> {:ok, :second} end}])
      end)

    assert result == {:ok, :second}
    assert ms < 1_000
  end

  test "returns the last error when every attempt fails" do
    assert Race.first_ok([{0, fn -> {:error, :one} end}, {10, fn -> {:error, :two} end}]) ==
             {:error, :two}
  end

  test "treats a crash as a failed attempt" do
    assert {:error, %RuntimeError{}} = Race.first_ok([{0, fn -> raise "boom" end}])
  end

  test "gives up at the timeout" do
    {ms, result} = timed(fn -> Race.first_ok([{0, after_ms(1_000, {:ok, :late})}], 100) end)
    assert result == {:error, :timeout}
    assert ms < 500
  end
end
