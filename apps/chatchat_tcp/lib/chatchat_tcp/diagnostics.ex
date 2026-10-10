defmodule ChatchatTcp.Diagnostics do
  @moduledoc false

  def now, do: System.monotonic_time()

  def elapsed(nil, _stage, _phase, _outcome), do: :ok

  def elapsed(started, stage, phase, outcome) do
    :telemetry.execute(
      [:chatchat, :delivery, :stage],
      %{duration: max(now() - started, 0), count: 1},
      %{stage: stage, phase: phase, outcome: outcome}
    )
  end

  def measure(stage, phase, operation) do
    started = now()

    try do
      result = operation.()
      outcome = if match?({:error, _}, result), do: :error, else: :ok
      elapsed(started, stage, phase, outcome)
      result
    catch
      kind, reason ->
        elapsed(started, stage, phase, :exception)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def connection_closed(reason) do
    :telemetry.execute([:chatchat, :tcp, :connection, :closed], %{count: 1}, %{reason: reason})
  end
end
