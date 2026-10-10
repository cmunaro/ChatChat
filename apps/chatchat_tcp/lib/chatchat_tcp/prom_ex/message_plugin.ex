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
      ] ++ collection_metrics()
    )
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
