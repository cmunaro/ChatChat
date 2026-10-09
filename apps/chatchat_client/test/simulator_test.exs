defmodule ChatchatClient.SimulatorTest do
  use ExUnit.Case, async: true

  alias ChatchatClient.Simulator

  test "counts startup failures by their preserved reason" do
    state = %{startup_failures: 1, startup_failures_by_reason: %{"timeout" => 1}}

    assert {:noreply, updated} =
             Simulator.handle_info({:client_start_failed, 42, "connection refused"}, state)

    assert updated.startup_failures == 2

    assert updated.startup_failures_by_reason == %{
             "timeout" => 1,
             "connection refused" => 1
           }
  end

  test "asynchronous result accounting separates confirmation, failure and rejection" do
    counts = :atomics.new(5, signed: false)
    state = %{result_counts: counts}

    for status <- [:ok, :failed, :rejected, :ok] do
      assert {:noreply, ^state} =
               ChatchatClient.SimulatedClient.handle_info({:delivery_result, status}, state)
    end

    assert Enum.map(1..5, &:atomics.get(counts, &1)) == [0, 2, 1, 1, 0]
  end
end
