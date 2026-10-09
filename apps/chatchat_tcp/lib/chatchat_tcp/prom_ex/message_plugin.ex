defmodule ChatchatTcp.PromEx.MessagePlugin do
  use PromEx.Plugin

  alias ChatchatBroker.Storage.MessagesStore
  alias ChatchatTcp.{Delivery, MessageDelivery, Presence}

  @impl true
  def event_metrics(_options) do
    Event.build(:chatchat_message_results, [
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
    ])
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
    snapshot = Delivery.metric_snapshot() |> Map.merge(MessageDelivery.metric_snapshot())

    snapshot =
      Map.merge(snapshot, %{
        connected_clients: Presence.connection_count(),
        postgres_undelivered_messages: MessagesStore.count_undelivered()
      })

    :telemetry.execute([:chatchat, :runtime, :snapshot], snapshot, %{})
  end
end
