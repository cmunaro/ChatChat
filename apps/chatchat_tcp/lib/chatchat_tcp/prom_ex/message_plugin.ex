defmodule ChatchatTcp.PromEx.MessagePlugin do
  use PromEx.Plugin

  alias ChatchatBroker.Storage.MessagesStore
  alias ChatchatTcp.{Delivery, Presence, RedisKeys}

  @poll_rate 5_000

  @impl true
  def event_metrics(_opts) do
    Event.build(
      :chatchat_message_event_metrics,
      [
        counter(
          [:chatchat, :messages, :admitted, :total],
          event_name: [:chatchat, :message, :admitted],
          measurement: :count,
          description: "Number of messages admitted into Redis."
        ),
        counter(
          [:chatchat, :tcp, :connections, :total],
          event_name: [:chatchat, :tcp, :connection, :opened],
          measurement: :count,
          description: "Number of accepted TCP connections."
        ),
        counter(
          [:chatchat, :messages, :delivered, :total],
          event_name: [:chatchat, :message, :delivery, :stop],
          measurement: :count,
          description: "Number of messages dispatched to a connected client.",
          tags: [:source],
          keep: fn metadata -> metadata.result == :ok end
        ),
        counter(
          [:chatchat, :messages, :deferred, :total],
          event_name: [:chatchat, :message, :delivery, :stop],
          measurement: :count,
          description: "Number of deliveries deferred because the receiver disconnected.",
          tags: [:source],
          keep: fn metadata -> metadata.result == :deferred end
        ),
        counter(
          [:chatchat, :message, :delivery, :failures, :total],
          event_name: [:chatchat, :message, :delivery, :stop],
          measurement: :count,
          description: "Number of failed message delivery attempts.",
          tags: [:source, :reason],
          keep: fn metadata -> metadata.result == :error end
        ),
        distribution(
          [:chatchat, :message, :delivery, :duration, :milliseconds],
          event_name: [:chatchat, :message, :delivery, :stop],
          measurement: :duration,
          description: "Time spent dispatching a message to local client processes.",
          tags: [:source],
          unit: {:native, :millisecond},
          reporter_options: [buckets: [1, 2, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]]
        ),
        sum(
          [:chatchat, :messages, :persisted, :total],
          event_name: [:chatchat, :message, :persistence, :stop],
          measurement: :persisted,
          description: "Number of messages persisted to PostgreSQL."
        ),
        counter(
          [:chatchat, :message, :persistence, :failures, :total],
          event_name: [:chatchat, :message, :persistence, :failure],
          measurement: :count,
          description: "Number of failed persistence operations.",
          tags: [:reason]
        ),
        distribution(
          [:chatchat, :message, :persistence, :batch, :size],
          event_name: [:chatchat, :message, :persistence, :stop],
          measurement: :batch_size,
          description: "Number of successfully persisted messages per persistence pass.",
          reporter_options: [buckets: [0, 1, 5, 10, 25, 50, 100, 250, 500]]
        ),
        distribution(
          [:chatchat, :message, :persistence, :duration, :milliseconds],
          event_name: [:chatchat, :message, :persistence, :stop],
          measurement: :duration,
          description: "Duration of a persistence pass.",
          unit: {:native, :millisecond},
          reporter_options: [buckets: [1, 2, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]]
        )
      ]
    )
  end

  @impl true
  def polling_metrics(_opts) do
    Polling.build(
      :chatchat_backlog_polling_metrics,
      @poll_rate,
      {__MODULE__, :execute_poll, []},
      [
        last_value([:chatchat, :tcp, :connected, :clients],
          event_name: [:chatchat, :runtime, :snapshot],
          measurement: :connected_clients,
          description: "Number of authenticated TCP client connections."
        ),
        last_value([:chatchat, :delivery, :active, :workers],
          event_name: [:chatchat, :runtime, :snapshot],
          measurement: :active_workers,
          description: "Number of active delivery workers."
        ),
        last_value([:chatchat, :delivery, :pending, :receivers],
          event_name: [:chatchat, :runtime, :snapshot],
          measurement: :pending_receivers,
          description: "Number of receivers waiting for another delivery pass."
        ),
        last_value([:chatchat, :redis, :pending, :messages],
          event_name: [:chatchat, :runtime, :snapshot],
          measurement: :redis_pending_messages,
          description: "Number of undelivered messages held in Redis."
        ),
        last_value([:chatchat, :postgres, :undelivered, :messages],
          event_name: [:chatchat, :runtime, :snapshot],
          measurement: :postgres_undelivered_messages,
          description: "Number of undelivered messages held in PostgreSQL."
        ),
        last_value([:chatchat, :process, :mailbox, :messages],
          event_name: [:chatchat, :process, :mailbox, :snapshot],
          measurement: :messages,
          description: "Number of messages waiting in a core process mailbox.",
          tags: [:process]
        )
      ],
      detach_on_error: false
    )
  end

  @doc false
  def execute_poll do
    %{active_workers: active_workers, pending_receivers: pending_receivers} =
      Delivery.metric_snapshot()

    :telemetry.execute(
      [:chatchat, :runtime, :snapshot],
      %{
        connected_clients: Presence.connection_count(),
        active_workers: active_workers,
        pending_receivers: pending_receivers,
        redis_pending_messages: redis_pending_messages(),
        postgres_undelivered_messages: MessagesStore.count_undelivered()
      },
      %{}
    )

    emit_mailbox_metrics()
  end

  defp emit_mailbox_metrics do
    for {name, process} <- [
          admission: ChatchatTcp.MessageAdmission,
          delivery: ChatchatTcp.Delivery,
          persistence: ChatchatTcp.Persistence
        ] do
      messages =
        case Process.whereis(process) do
          nil -> 0
          pid -> pid |> Process.info(:message_queue_len) |> elem(1)
        end

      :telemetry.execute(
        [:chatchat, :process, :mailbox, :snapshot],
        %{messages: messages},
        %{process: name}
      )
    end

    :ok
  end

  defp redis_pending_messages do
    {:ok, [sending, persisting]} =
      Redix.pipeline(ChatchatTcp.Redis, [
        ["ZCARD", RedisKeys.sending_deadlines()],
        ["SCARD", RedisKeys.persisting_set()]
      ])

    sending + persisting
  end
end
