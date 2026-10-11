defmodule ChatchatClient.ConnectionDiagnostics do
  @moduledoc false

  @disconnect_reasons [
    :intentional,
    :ping_failure,
    :peer_close,
    :socket_error,
    :protocol_suspension,
    :request_failure,
    :shutdown
  ]
  @failure_stages [:token, :connect_authenticate, :activate]
  @events Enum.map(@disconnect_reasons, &{:disconnect, &1}) ++
            [:reconnect_attempt, :reconnect_ok] ++
            Enum.map(@failure_stages, &{:reconnect_failed, &1})
  @indices @events |> Enum.with_index(1) |> Map.new()

  @interval_roles [:reconnect, :startup]
  @interval_bounds [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 60_000]
  @interval_fields 9
  def new, do: :atomics.new(length(@events) + 2 * @interval_fields, signed: false)

  def emit_interval(state, role, interval) when role in @interval_roles do
    :telemetry.execute([:chatchat, :client, :retry_interval], %{interval: interval, count: 1}, %{
      role: role
    })

    if observer = Map.get(state, :result_observer),
      do: send(observer, {:retry_interval, role, interval})

    :ok
  end

  def record_interval(counts, role, interval)
      when role in @interval_roles and is_integer(interval) and interval >= 0 do
    offset = interval_offset(role)
    :atomics.add(counts, offset + 1, 1)
    :atomics.add(counts, offset + 2, interval)

    for {bound, index} <- Enum.with_index(@interval_bounds, offset + 3),
        interval <= bound,
        do: :atomics.add(counts, index, 1)

    :ok
  end

  defp interval_offset(role),
    do: length(@events) + Enum.find_index(@interval_roles, &(&1 == role)) * @interval_fields

  def emit(state, event) when event in @events do
    metadata =
      case event do
        {:disconnect, reason} -> %{event: :disconnect, reason: reason}
        {:reconnect_failed, stage} -> %{event: :reconnect_failed, stage: stage}
        event -> %{event: event}
      end

    :telemetry.execute([:chatchat, :client, :connection], %{count: 1}, metadata)

    if observer = Map.get(state, :result_observer),
      do: send(observer, {:connection_diagnostic, event})

    :ok
  end

  def record(counts, event) when event in @events do
    :atomics.add(counts, Map.fetch!(@indices, event), 1)
  end

  def snapshot(counts) do
    disconnects = Map.new(@disconnect_reasons, &{&1, get(counts, {:disconnect, &1})})
    failures = Map.new(@failure_stages, &{&1, get(counts, {:reconnect_failed, &1})})

    %{
      disconnects: disconnects,
      reconnects: %{
        attempted: get(counts, :reconnect_attempt),
        ok: get(counts, :reconnect_ok),
        failed: failures |> Map.values() |> Enum.sum()
      },
      retry_intervals_ms:
        Map.new(@interval_roles, fn role ->
          offset = interval_offset(role)

          {role,
           %{
             count: :atomics.get(counts, offset + 1),
             sum: :atomics.get(counts, offset + 2),
             buckets:
               Map.new(Enum.with_index(@interval_bounds, offset + 3), fn {bound, index} ->
                 {bound, :atomics.get(counts, index)}
               end)
           }}
        end),
      reconnect_failures: failures
    }
  end

  defp get(counts, event), do: :atomics.get(counts, Map.fetch!(@indices, event))
end
