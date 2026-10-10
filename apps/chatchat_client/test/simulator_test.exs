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
    options = %{number_of_clients: 1, username_prefix: nil}
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
end
