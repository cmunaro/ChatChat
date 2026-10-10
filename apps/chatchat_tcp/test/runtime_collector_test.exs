defmodule ChatchatTcp.PromEx.RuntimeCollectorTest do
  use ExUnit.Case, async: false

  alias ChatchatTcp.PromEx.{MessagePlugin, RuntimeCollector}

  setup do
    owner = self()
    handler = make_ref()

    :telemetry.attach_many(
      handler,
      [
        [:chatchat, :runtime, :snapshot],
        [:chatchat, :runtime, :collection],
        [:chatchat, :runtime, :collection, :failed]
      ],
      &__MODULE__.forward_event/4,
      owner
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    supervisor = start_supervised!({Task.Supervisor, max_children: 3})

    sources =
      Map.new([:inbox, :sender, :postgres], fn source ->
        {source,
         fn ->
           send(owner, {:collect, source, self()})

           receive do
             {:return, snapshot} -> snapshot
             :crash -> exit(:collection_failed)
           end
         end}
      end)

    collector =
      start_supervised!(
        {RuntimeCollector, task_supervisor: supervisor, sources: sources, timeout: 200}
      )

    %{collector: collector, supervisor: supervisor}
  end

  def forward_event(event, measurements, metadata, owner) do
    send(owner, {:event, event, measurements, metadata})
  end

  test "stalled collections do not block fresh local connections or overlap", %{
    collector: collector,
    supervisor: supervisor
  } do
    MessagePlugin.execute_poll()
    assert_receive {:event, [:chatchat, :runtime, :snapshot], %{connected_clients: before}, %{}}
    assert_receive {:collect, :inbox, _}
    assert_receive {:collect, :sender, _}
    assert_receive {:collect, :postgres, _}

    {:ok, _} = Registry.register(ChatchatTcp.Presence.Registry, :metrics_test_connection, %{})
    MessagePlugin.execute_poll()

    assert_receive {:event, [:chatchat, :runtime, :snapshot], %{connected_clients: after_count},
                    %{}}

    assert after_count == before + 1
    :sys.get_state(collector)
    assert length(Task.Supervisor.children(supervisor)) == 3
    refute_receive {:collect, _, _}, 30
    Registry.unregister(ChatchatTcp.Presence.Registry, :metrics_test_connection)
  end

  test "success preserves gauges and a real zero; timeout keeps last success and recovers", %{
    collector: collector,
    supervisor: supervisor
  } do
    RuntimeCollector.poll()
    assert_receive {:collect, :postgres, postgres}
    assert_receive {:collect, :inbox, inbox}
    assert_receive {:collect, :sender, sender}
    send(postgres, {:return, %{postgres_undelivered_messages: 0}})
    send(inbox, {:return, %{active_workers: 2, pending_receivers: 3, loaded_bytes: 4}})
    send(sender, {:return, %{attempts: 5, receipts: 6, workers: 7, waiting: 8}})

    assert_receive {:event, [:chatchat, :runtime, :snapshot], %{postgres_undelivered_messages: 0},
                    %{}}

    assert_receive {:event, [:chatchat, :runtime, :snapshot],
                    %{active_workers: 2, pending_receivers: 3, loaded_bytes: 4}, %{}}

    assert_receive {:event, [:chatchat, :runtime, :snapshot],
                    %{attempts: 5, receipts: 6, workers: 7, waiting: 8}, %{}}

    assert_receive {:event, [:chatchat, :runtime, :collection],
                    %{success: 1, last_success: timestamp}, %{source: :postgres}}

    assert timestamp > 0

    RuntimeCollector.poll()
    assert_receive {:collect, :postgres, stalled}
    assert_receive {:collect, :inbox, _}
    assert_receive {:collect, :sender, _}
    state = :sys.get_state(collector)
    {reference, _job} = Enum.find(state.jobs, fn {_, job} -> job.source == :postgres end)
    monitor = Process.monitor(stalled)

    assert_receive {:event, [:chatchat, :runtime, :collection, :failed], %{count: 1},
                    %{source: :postgres}},
                   1_000

    assert_receive {:DOWN, ^monitor, :process, ^stalled, :killed}

    assert_receive {:event, [:chatchat, :runtime, :collection],
                    %{success: 0, last_success: ^timestamp}, %{source: :postgres}}

    send(collector, {reference, %{postgres_undelivered_messages: 999}})
    refute_receive {:event, [:chatchat, :runtime, :snapshot], _, _}, 30
    assert Task.Supervisor.children(supervisor) == []

    RuntimeCollector.poll()
    assert_receive {:collect, :postgres, recovered}
    send(recovered, {:return, %{postgres_undelivered_messages: 1}})

    assert_receive {:event, [:chatchat, :runtime, :snapshot], %{postgres_undelivered_messages: 1},
                    %{}}

    assert_receive {:event, [:chatchat, :runtime, :collection], %{success: 1},
                    %{source: :postgres}}
  end

  @tag capture_log: true
  test "a crashed source fails independently and can be collected again" do
    RuntimeCollector.poll()

    assert_receive {:event, [:chatchat, :runtime, :collection], %{success: 0, last_success: 0},
                    %{source: :sender}}

    assert_receive {:collect, :sender, sender}
    assert_receive {:collect, :inbox, inbox}
    send(sender, :crash)
    send(inbox, {:return, %{active_workers: 0}})

    assert_receive {:event, [:chatchat, :runtime, :collection, :failed], %{count: 1},
                    %{source: :sender}}

    assert_receive {:event, [:chatchat, :runtime, :snapshot], %{active_workers: 0}, %{}}
    RuntimeCollector.poll()
    assert_receive {:collect, :sender, next_sender}
    assert next_sender != sender
  end

  test "an overdue result cannot bypass the deadline while its timer is queued", %{
    collector: collector
  } do
    RuntimeCollector.poll()
    assert_receive {:collect, :postgres, postgres}
    monitor = Process.monitor(postgres)

    state =
      :sys.replace_state(collector, fn state ->
        jobs =
          Map.new(state.jobs, fn {reference, job} ->
            deadline =
              if job.source == :postgres,
                do: System.monotonic_time(:millisecond) - 1,
                else: job.deadline

            {reference, %{job | deadline: deadline}}
          end)

        %{state | jobs: jobs}
      end)

    {reference, _} = Enum.find(state.jobs, fn {_, job} -> job.source == :postgres end)
    send(collector, {reference, %{postgres_undelivered_messages: 999}})
    assert_receive {:event, [:chatchat, :runtime, :collection, :failed], _, %{source: :postgres}}
    assert_receive {:DOWN, ^monitor, :process, ^postgres, :killed}
    refute_receive {:event, [:chatchat, :runtime, :snapshot], _, _}, 30
  end

  @tag capture_log: true
  test "exports compatible gauges and source health through the Prometheus collector" do
    metrics = MessagePlugin.event_metrics([]).metrics ++ MessagePlugin.polling_metrics([]).metrics

    start_supervised!(
      TelemetryMetricsPrometheus.Core.child_spec(
        name: __MODULE__.Metrics,
        metrics: metrics,
        require_seconds: false,
        consistent_units: true,
        start_async: false
      )
    )

    MessagePlugin.execute_poll()
    assert_receive {:collect, :postgres, postgres}
    assert_receive {:collect, :sender, sender}
    send(postgres, {:return, %{postgres_undelivered_messages: 0}})
    send(sender, :crash)

    assert_receive {:event, [:chatchat, :runtime, :snapshot], %{postgres_undelivered_messages: 0},
                    %{}}

    assert_receive {:event, [:chatchat, :runtime, :collection, :failed], _, %{source: :sender}}

    # Synchronize with the collector after its telemetry handlers finish.
    :sys.get_state(RuntimeCollector)
    scrape = TelemetryMetricsPrometheus.Core.scrape(__MODULE__.Metrics)
    assert scrape =~ "chatchat_tcp_connected_clients "
    assert scrape =~ "chatchat_postgres_undelivered_messages 0"
    assert scrape =~ ~s(chatchat_runtime_collection_success{source="postgres"} 1)
    assert scrape =~ ~s(chatchat_runtime_collection_success{source="sender"} 0)
    assert scrape =~ ~s(chatchat_runtime_collection_failures_total{source="sender"} 1)

    assert scrape =~
             ~s(chatchat_runtime_collection_last_success_timestamp_seconds{source="postgres"})
  end
end
