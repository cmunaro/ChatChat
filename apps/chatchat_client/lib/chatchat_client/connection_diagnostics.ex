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

  def new, do: :atomics.new(length(@events), signed: false)

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
      reconnect_failures: failures
    }
  end

  defp get(counts, event), do: :atomics.get(counts, Map.fetch!(@indices, event))
end
