defmodule ChatchatClient.ReconnectBackoffTest do
  use ExUnit.Case, async: true
  alias ChatchatClient.{ConnectionDiagnostics, ReconnectBackoff}

  test "exponential jitter stays inside finite bounds even after long outages" do
    for failures <- [0, 1, 2, 3, 4, 5, 50_000] do
      ceiling = min(1_000 * Integer.pow(2, min(failures, 5)), 30_000)
      delays = for _ <- 1..200, do: ReconnectBackoff.delay(failures)
      assert Enum.all?(delays, &(&1 >= div(ceiling * 4, 5) and &1 <= ceiling))
      assert length(Enum.uniq(delays)) > 1
    end
  end

  test "aggregate retry intervals retain bounded buckets and an explicit overflow" do
    counts = ConnectionDiagnostics.new()

    for ms <- [800, 1_500, 30_000, 70_000],
        do: ConnectionDiagnostics.record_interval(counts, :reconnect, ms)

    ConnectionDiagnostics.record_interval(counts, :startup, 1_000)
    intervals = ConnectionDiagnostics.snapshot(counts).retry_intervals_ms
    assert intervals.reconnect.count == 4
    assert intervals.reconnect.sum == 102_300
    assert intervals.reconnect.buckets[1_000] == 1
    assert intervals.reconnect.buckets[30_000] == 3
    assert intervals.reconnect.buckets[60_000] == 3
    assert intervals.startup.count == 1
    assert Jason.decode!(Jason.encode!(intervals))["reconnect"]["buckets"]["1000"] == 1
  end
end
