defmodule ChatchatTcp.Telemetry do
  @moduledoc false

  @spec delivery_stop(integer(), :postgres | :redis, boolean()) :: :ok
  def delivery_stop(started_at, source, true) do
    :telemetry.execute(
      [:chatchat, :message, :delivery, :stop],
      %{count: 1, duration: System.monotonic_time() - started_at},
      %{source: source, result: :ok, reason: :none}
    )
  end

  def delivery_stop(started_at, source, false) do
    :telemetry.execute(
      [:chatchat, :message, :delivery, :stop],
      %{count: 1, duration: System.monotonic_time() - started_at},
      %{source: source, result: :deferred, reason: :no_connection}
    )
  end

  @spec delivery_failure(:postgres | :redis | :unknown, atom()) :: :ok
  def delivery_failure(source, reason) do
    :telemetry.execute(
      [:chatchat, :message, :delivery, :stop],
      %{count: 1, duration: 0},
      %{source: source, result: :error, reason: reason}
    )
  end

  @spec persistence_stop(integer(), non_neg_integer()) :: :ok
  def persistence_stop(started_at, persisted) do
    :telemetry.execute(
      [:chatchat, :message, :persistence, :stop],
      %{
        duration: System.monotonic_time() - started_at,
        batch_size: persisted,
        persisted: persisted
      },
      %{}
    )
  end

  @spec persistence_failure(:postgres_unavailable | :redis_unavailable) :: :ok
  def persistence_failure(reason) do
    :telemetry.execute(
      [:chatchat, :message, :persistence, :failure],
      %{count: 1},
      %{reason: reason}
    )
  end
end
