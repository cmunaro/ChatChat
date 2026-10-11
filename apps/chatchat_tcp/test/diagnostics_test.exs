defmodule ChatchatTcp.DiagnosticsTest do
  use ExUnit.Case, async: false

  alias ChatchatTcp.{Capacity, Diagnostics, MessageDelivery}
  alias ChatchatTcp.PromEx.MessagePlugin

  setup do
    id = make_ref()

    :telemetry.attach_many(
      id,
      [[:chatchat, :delivery, :stage], [:chatchat, :tcp, :connection, :closed]],
      &__MODULE__.observe/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  def observe(event, measurements, metadata, owner),
    do: send(owner, {:diagnostic, event, measurements, metadata})

  test "measures elapsed intervals and preserves errors and exceptions" do
    assert {:error, :unavailable} =
             Diagnostics.measure(:persist, :fallback, fn -> {:error, :unavailable} end)

    assert_receive {:diagnostic, [:chatchat, :delivery, :stage], %{duration: duration, count: 1},
                    %{stage: :persist, phase: :fallback, outcome: :error}}

    assert duration >= 0

    assert_raise ArgumentError, "unchanged", fn ->
      Diagnostics.measure(:wake, :fallback, fn -> raise ArgumentError, "unchanged" end)
    end

    assert_receive {:diagnostic, [:chatchat, :delivery, :stage], _,
                    %{stage: :wake, phase: :fallback, outcome: :exception}}
  end

  test "queue abandonment and direct fallback emit once without altering capacity cleanup" do
    {:ok, ticket} = Capacity.claim(ChatchatTcp.SenderCapacity)
    :ok = Capacity.activate(ChatchatTcp.SenderCapacity, ticket)
    reference = elem(ticket, 2)

    attempt = %{
      phase: :direct,
      completed: false,
      job: nil,
      queued_at: nil,
      direct_started_at: Diagnostics.now() - System.convert_time_unit(20, :millisecond, :native),
      deadline: System.monotonic_time(:millisecond) + 1_000,
      sender: self(),
      sender_id: 1,
      receiver: 2,
      request: Ecto.UUID.generate(),
      id: Ecto.UUID.generate(),
      result_timer: nil,
      direct_timer: nil,
      resend_timer: nil,
      permits: [],
      monitor: Process.monitor(self()),
      remote_monitors: %{},
      pending_frames: MapSet.new(),
      ticket: ticket
    }

    state = %{
      attempts: %{reference => attempt},
      jobs: Map.new(1..32, &{&1, :delete}),
      receipts: %{},
      queue: :queue.new()
    }

    assert {:noreply, queued} = MessageDelivery.handle_info({:direct_timeout, reference}, state)
    assert :queue.len(queued.queue) == 1

    assert_receive {:diagnostic, [:chatchat, :delivery, :stage], %{duration: wait},
                    %{stage: :direct_wait, outcome: :fallback}}

    assert System.convert_time_unit(wait, :native, :millisecond) >= 20

    assert {:noreply, finished} = MessageDelivery.handle_info({:deadline, reference}, queued)
    assert finished.attempts == %{}
    assert :queue.is_empty(finished.queue)

    assert_receive {:diagnostic, [:chatchat, :delivery, :stage], _,
                    %{stage: :queue, phase: :fallback, outcome: :abandoned}}

    assert_receive {:message_result, ^reference, %{status: :failed}}
    assert {:noreply, ^finished} = MessageDelivery.handle_info({:deadline, reference}, finished)
    refute_receive {:diagnostic, _, _, _}, 30
  end

  test "Prometheus uses milliseconds and fixed labels; other Redis connections are ignored" do
    start_supervised!(
      TelemetryMetricsPrometheus.Core.child_spec(
        name: __MODULE__.Metrics,
        metrics: MessagePlugin.event_metrics([]).metrics,
        require_seconds: false,
        consistent_units: true,
        start_async: false
      )
    )

    Diagnostics.elapsed(
      Diagnostics.now() - System.convert_time_unit(25, :millisecond, :native),
      :route,
      :routing,
      :ok
    )

    Diagnostics.connection_closed(:peer_close)

    duration = System.convert_time_unit(10, :millisecond, :native)

    metadata = %{
      connection_name: ChatchatTcp.Redis.Heartbeat,
      commands: [["EVALSHA", "secret-key", "private-payload"]],
      kind: :error,
      reason: "secret-error"
    }

    :telemetry.execute([:redix, :pipeline, :stop], %{duration: duration}, metadata)

    :telemetry.execute([:redix, :pipeline, :stop], %{duration: duration}, %{
      metadata
      | connection_name: :unrelated
    })

    :telemetry.execute(
      [:redix, :pipeline, :stop],
      %{duration: duration},
      %{
        metadata
        | connection_name: nil
      }
      |> Map.put(:extra_metadata, %{connection_name: ChatchatTcp.Redis.Renewal0})
    )

    scrape = TelemetryMetricsPrometheus.Core.scrape(__MODULE__.Metrics)

    assert scrape =~ "chatchat_delivery_stage_duration_milliseconds_bucket"

    assert scrape =~
             ~s(chatchat_delivery_stage_total{outcome="ok",phase="routing",stage="route"} 1)

    assert scrape =~ ~s(chatchat_tcp_disconnections_total{reason="peer_close"} 1)

    assert scrape =~
             ~s(chatchat_redis_pipeline_duration_milliseconds_sum{operation="script",outcome="error",role="heartbeat"} 10)

    assert scrape =~
             ~s(chatchat_redis_pipeline_failures_total{operation="script",role="heartbeat"} 1)

    assert scrape =~
             ~s(chatchat_redis_pipeline_failures_total{operation="script",role="renewal"} 1)

    refute scrape =~ "Renewal0"
    refute scrape =~ "secret"
    refute scrape =~ "private-payload"
    refute scrape =~ "unrelated"
  end
end
