defmodule KB.Race do
  @moduledoc """
  Runs attempts at the same job on a schedule and takes the first success.

  Embedding and reranking calls to OpenRouter usually answer in half a
  second but sometimes take ten. The cure is to send another attempt when
  the first is slow, or to race two backends from the start, and use
  whichever answers first.

  Each attempt runs in its own unlinked process under `KB.TaskSupervisor`
  and reports back by message. A losing attempt is never killed: killing an
  HTTP request mid-flight stalled Finch's connection pool on production. It
  finishes on its own, and its late answer is dropped. The caller's mailbox
  may receive it after `first_ok/2` returns; callers here are short-lived
  tasks, so it goes nowhere.
  """

  @type attempt :: {start_after_ms :: non_neg_integer(), (-> {:ok, term()} | {:error, term()})}

  @doc """
  Starts each attempt at its scheduled time and returns the first
  `{:ok, _}`.

  A failed attempt brings the next scheduled one forward, so a fast error
  doesn't wait out the schedule. When every attempt has failed, returns the
  last error. After `timeout` milliseconds, returns `{:error, :timeout}`.
  """
  @spec first_ok([attempt()], timeout()) :: {:ok, term()} | {:error, term()}
  def first_ok(attempts, timeout \\ :infinity) do
    now = now()
    deadline = if timeout == :infinity, do: nil, else: now + timeout

    schedule =
      attempts
      |> Enum.map(fn {after_ms, fun} -> {now + after_ms, fun} end)
      |> Enum.sort_by(&elem(&1, 0))

    loop(make_ref(), schedule, deadline, 0, nil)
  end

  defp loop(ref, schedule, deadline, in_flight, error) do
    now = now()
    {due, later} = Enum.split_while(schedule, fn {at, _fun} -> at <= now end)

    # Nothing running and nothing due: a failure brings the next one forward.
    {due, later} =
      if in_flight == 0 and due == [] and later != [],
        do: {[hd(later)], tl(later)},
        else: {due, later}

    Enum.each(due, fn {_at, fun} -> start(ref, fun) end)
    in_flight = in_flight + length(due)

    cond do
      deadline != nil and now >= deadline ->
        {:error, :timeout}

      in_flight == 0 ->
        error || {:error, :no_attempts}

      true ->
        wake = [deadline | Enum.map(Enum.take(later, 1), &elem(&1, 0))] |> Enum.reject(&is_nil/1)

        receive do
          {^ref, {:ok, _} = ok} -> ok
          {^ref, result} -> loop(ref, later, deadline, in_flight - 1, result)
        after
          wait_ms(wake, now) -> loop(ref, later, deadline, in_flight, error)
        end
    end
  end

  defp wait_ms([], _now), do: :infinity
  defp wait_ms(times, now), do: max(Enum.min(times) - now, 0)

  defp start(ref, fun) do
    caller = self()

    {:ok, _pid} =
      Task.Supervisor.start_child(KB.TaskSupervisor, fn ->
        send(caller, {ref, run(fun)})
      end)
  end

  defp run(fun) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      other -> {:error, {:unexpected, other}}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
