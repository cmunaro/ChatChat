defmodule ChatchatClient.SimulatorTest do
  use ExUnit.Case, async: true

  alias ChatchatClient.Simulator

  test "starting activity targets client wrappers" do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    owner = self()

    {:ok, wrapper} =
      DynamicSupervisor.start_child(supervisor, %{
        id: :wrapper,
        start:
          {Task, :start_link,
           [
             fn ->
               receive do
                 :start_activity -> send(owner, :activity_started)
               end

               receive do
                 :stop -> :ok
               end
             end
           ]},
        restart: :temporary,
        modules: [ChatchatClient.SimulatedClient]
      })

    clients = :ets.new(:clients, [:set])
    :ets.insert(clients, {1, wrapper, 1})

    state = %{
      supervisor: supervisor,
      clients: clients,
      activity_started: false,
      options: %{number_of_clients: 1, duration_seconds: :infinity}
    }

    assert {:reply, :ok, %{activity_started: true}} =
             Simulator.handle_call(:start_activity, nil, state)

    assert_receive :activity_started
  end

  test "a simulation supervisor starts without a shared store" do
    options = %{
      number_of_clients: 1,
      username_prefix: nil,
      send_message_probability_per_second: 0
    }

    {:ok, state} = Simulator.init(options)

    try do
      assert DynamicSupervisor.count_children(state.supervisor).active == 0
      refute Map.has_key?(state, :store_server)
      refute Map.has_key?(state, :state_namespace)
    after
      Supervisor.stop(state.supervisor)
    end
  end

  test "counts startup failures by their preserved reason" do
    state = %{startup_failures: 1, startup_failures_by_reason: %{"timeout" => 1}}

    assert {:noreply, updated} =
             Simulator.handle_info({:client_start_failed, 42, "connection refused"}, state)

    assert updated.startup_failures == 2

    assert updated.startup_failures_by_reason == %{
             "timeout" => 1,
             "connection refused" => 1
           }
  end

  test "asynchronous result accounting separates confirmation, failure and rejection" do
    counts = :atomics.new(5, signed: false)
    state = %{result_counts: counts}

    for status <- [:ok, :failed, :rejected, :ok] do
      assert {:noreply, ^state} =
               ChatchatClient.SimulatedClient.handle_info({:delivery_result, status}, state)
    end

    assert Enum.map(1..5, &:atomics.get(counts, &1)) == [0, 2, 1, 1, 0]
  end

  test "attempt accounting distinguishes retries" do
    counts = :atomics.new(15, signed: false)
    state = %{result_counts: counts}

    for retry? <- [false, true, true] do
      assert {:noreply, ^state} =
               ChatchatClient.SimulatedClient.handle_info({:delivery_attempt, retry?}, state)
    end

    assert :atomics.get(counts, 14) == 3
    assert :atomics.get(counts, 15) == 2
  end

  test "unique confirmations record bounded cumulative latency buckets" do
    counts = :atomics.new(13, signed: false)
    state = %{result_counts: counts}

    for latency <- [5, 70, 15_000] do
      assert {:noreply, ^state} =
               ChatchatClient.SimulatedClient.handle_info({:delivery_confirmed, latency}, state)
    end

    assert Enum.map(6..13, &:atomics.get(counts, &1)) == [3, 15_075, 1, 1, 2, 2, 2, 2]
  end

  test "a dead client counts a submission failure without crashing its wrapper" do
    client = spawn(fn -> :ok end)
    monitor = Process.monitor(client)
    assert_receive {:DOWN, ^monitor, :process, ^client, _}

    clients = :ets.new(:clients, [:set])
    :ets.insert(clients, {1, self(), 42})
    counts = :atomics.new(5, signed: false)

    state = %{
      client: client,
      clients: clients,
      number_of_clients: 1,
      send_probability: 1,
      disconnection_probability: 0,
      message: "test",
      result_counts: counts
    }

    assert {:noreply, ^state} = ChatchatClient.SimulatedClient.handle_info(:tick, state)
    assert :atomics.get(counts, 5) == 1
    assert :atomics.get(counts, 1) == 0
  end

  test "one shared traffic control pauses busy wrappers without touching clients or outboxes" do
    options = %{
      number_of_clients: 1,
      username_prefix: nil,
      send_message_probability_per_second: 1
    }

    {:ok, simulation} = Simulator.init(options)
    client = spawn(fn -> :ok end)
    monitor = Process.monitor(client)
    assert_receive {:DOWN, ^monitor, :process, ^client, _}
    :ets.insert(simulation.clients, {1, self(), 42})

    wrapper = %{
      client: client,
      clients: simulation.clients,
      activity_options: simulation.activity_options,
      number_of_clients: 1,
      send_probability: 1,
      disconnection_probability: 0,
      message: "test",
      result_counts: simulation.result_counts
    }

    try do
      assert {:reply, :ok, paused} =
               Simulator.handle_call({:set_send_probability, 0}, nil, simulation)

      assert paused.options.send_message_probability_per_second == 0
      assert {:noreply, ^wrapper} = ChatchatClient.SimulatedClient.handle_info(:tick, wrapper)
      assert :atomics.get(simulation.result_counts, 5) == 0
      assert :ets.info(simulation.clients, :size) == 1

      assert {:reply, {:error, :invalid_probability}, ^paused} =
               Simulator.handle_call({:set_send_probability, 2}, nil, paused)

      assert :ets.lookup_element(simulation.activity_options, :send_probability, 2) == 0
      assert {:reply, :ok, _} = Simulator.handle_call({:set_send_probability, 1}, nil, paused)
      assert {:noreply, ^wrapper} = ChatchatClient.SimulatedClient.handle_info(:tick, wrapper)
      assert :atomics.get(simulation.result_counts, 5) == 1
    after
      Supervisor.stop(simulation.supervisor)
    end
  end

  @tag timeout: 10_000
  test "a slow status poll does not crash the load generator" do
    owner = self()

    simulation =
      spawn_link(fn ->
        receive do
          {:"$gen_call", _from, :status} -> send(owner, :status_requested)
        end

        receive do
          :stop -> :ok
        end
      end)

    state = %{simulation: simulation, barrier_announced: true}

    try do
      assert {:noreply, ^state} = ChatchatClient.LoadGenerator.handle_info(:poll, state)
      assert_received :status_requested
      assert Process.alive?(simulation)
    after
      send(simulation, :stop)
    end
  end
end
