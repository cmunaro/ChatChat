defmodule ChatchatTcp.PromEx.MessagePlugin do
  use PromEx.Plugin

  alias ChatchatTcp.Presence
  alias ChatchatTcp.PromEx.RuntimeCollector

  @impl true
  def event_metrics(_options) do
    Event.build(
      :chatchat_message_results,
      [
        counter([:chatchat, :messages, :results, :total],
          event_name: [:chatchat, :message, :result],
          measurement: :count,
          tags: [:status, :reason],
          description: "Confirmed receipt/commit, retryable failure, or permanent rejection."
        ),
        counter([:chatchat, :inbox, :receipts, :total],
          event_name: [:chatchat, :inbox, :receipt],
          measurement: :count,
          description: "Authorized durable receipt ACKs for stored messages."
        ),
        counter([:chatchat, :tcp, :connections, :total],
          event_name: [:chatchat, :tcp, :connection, :opened],
          measurement: :count,
          description: "Accepted TCP connections."
        )
      ] ++ collection_metrics() ++ diagnostic_metrics()
    )
  end

  @buckets [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_000, 5_000, 10_000]

  defp diagnostic_metrics do
    [
      distribution([:chatchat, :delivery, :stage, :duration, :milliseconds],
        event_name: [:chatchat, :delivery, :stage],
        measurement: :duration,
        tags: [:stage, :phase, :outcome],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @buckets],
        description: "Delivery stage duration; queue/schedule exclude worker execution."
      ),
      counter([:chatchat, :delivery, :stage, :total],
        event_name: [:chatchat, :delivery, :stage],
        measurement: :count,
        tags: [:stage, :phase, :outcome],
        description: "Observed delivery stage outcomes."
      ),
      counter([:chatchat, :tcp, :disconnections, :total],
        event_name: [:chatchat, :tcp, :connection, :closed],
        measurement: :count,
        tags: [:reason],
        description: "TCP connection closures by bounded reason."
      ),
      last_value([:chatchat, :presence, :heartbeat, :last_success_timestamp_seconds],
        event_name: [:chatchat, :presence, :heartbeat],
        measurement: :last_success,
        description: "Last confirmed refresh of this node's Redis heartbeat."
      ),
      distribution([:chatchat, :presence, :work, :duration, :milliseconds],
        event_name: [:chatchat, :presence, :work],
        measurement: :duration,
        tags: [:role, :outcome],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @buckets],
        description: "Bounded presence work latency including admission and queueing."
      ),
      counter([:chatchat, :presence, :work, :total],
        event_name: [:chatchat, :presence, :work],
        measurement: :count,
        tags: [:role, :outcome],
        description: "Presence work outcomes, including overload."
      ),
      distribution([:chatchat, :redis, :pipeline, :duration, :milliseconds],
        event_name: [:redix, :pipeline, :stop],
        measurement: :duration,
        tags: [:role, :operation, :outcome],
        tag_values: &redis_tags/1,
        drop: &other_redis?/1,
        unit: {:native, :millisecond},
        reporter_options: [buckets: @buckets],
        description: "TCP Redis round-trip latency, including failed calls."
      ),
      counter([:chatchat, :redis, :pipeline, :failures, :total],
        event_name: [:redix, :pipeline, :stop],
        measurement: fn _measurements -> 1 end,
        tags: [:role, :operation],
        tag_values: &redis_tags/1,
        drop: fn metadata -> other_redis?(metadata) or metadata[:kind] != :error end,
        description: "TCP Redis pipeline failures."
      )
    ]
  end

  defp other_redis?(metadata),
    do: is_nil(redis_role(metadata))

  defp redis_role(metadata) do
    name = metadata[:connection_name] || get_in(metadata, [:extra_metadata, :connection_name])
    ChatchatTcp.PresenceRedis.role(name)
  end

  defp redis_tags(metadata) do
    operation =
      case metadata[:commands] do
        [["GET" | _]] -> :get
        [["EXISTS" | _]] -> :exists
        [["EVALSHA" | _]] -> :script
        [["EVAL" | _]] -> :script
        [_] -> :other
        _ -> :pipeline
      end

    %{
      role: redis_role(metadata),
      operation: operation,
      outcome: if(metadata[:kind] == :error, do: :error, else: :ok)
    }
  end

  defp collection_metrics do
    [
      last_value([:chatchat, :runtime, :collection, :last_success_timestamp_seconds],
        event_name: [:chatchat, :runtime, :collection],
        measurement: :last_success,
        tags: [:source],
        description: "Unix time of the last successful source collection."
      ),
      last_value([:chatchat, :runtime, :collection, :success],
        event_name: [:chatchat, :runtime, :collection],
        measurement: :success,
        tags: [:source],
        description: "Whether the latest source collection succeeded."
      ),
      counter([:chatchat, :runtime, :collection, :failures, :total],
        event_name: [:chatchat, :runtime, :collection, :failed],
        measurement: :count,
        tags: [:source],
        description: "Failed or timed-out source collections."
      )
    ]
  end

  @impl true
  def polling_metrics(_options) do
    fields = [
      {[:tcp, :connected, :clients], :connected_clients, "Authenticated local connections."},
      {[:delivery, :active, :workers], :active_workers, "Active bounded inbox workers."},
      {[:delivery, :pending, :receivers], :pending_receivers,
       "Coalesced pending inbox receivers."},
      {[:delivery, :loaded, :bytes], :loaded_bytes, "Reserved inbox page bytes."},
      {[:delivery, :attempts], :attempts, "Active sender ownership attempts."},
      {[:delivery, :receipts], :receipts, "Outstanding session-scoped receiver receipts."},
      {[:delivery, :fallback, :workers], :workers,
       "Active routing, fallback, and delete workers."},
      {[:delivery, :waiting], :waiting, "Waiting routing/fallback attempts."},
      {[:postgres, :undelivered, :messages], :postgres_undelivered_messages,
       "Pending PostgreSQL message rows."}
    ]

    metrics =
      Enum.map(fields, fn {name, field, description} ->
        last_value([:chatchat | name],
          event_name: [:chatchat, :runtime, :snapshot],
          measurement: field,
          description: description
        )
      end)

    Polling.build(:chatchat_delivery_capacity, 5_000, {__MODULE__, :execute_poll, []}, metrics,
      detach_on_error: false
    )
  end

  def execute_poll do
    :telemetry.execute(
      [:chatchat, :runtime, :snapshot],
      %{connected_clients: Presence.connection_count()},
      %{}
    )

    RuntimeCollector.emit_health(:connections, 1, System.system_time(:second))
    RuntimeCollector.poll()
  end
end
