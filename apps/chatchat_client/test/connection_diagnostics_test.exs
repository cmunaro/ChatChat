defmodule ChatchatClient.ConnectionDiagnosticsTest do
  use ExUnit.Case, async: false

  alias ChatchatClient.{ConnectionDiagnostics, SimulatedClient, Simulator, Store}

  setup do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    previous = Application.get_env(:chatchat_client, :tcp_port)
    Application.put_env(:chatchat_client, :tcp_port, port)

    on_exit(fn ->
      :gen_tcp.close(listener)

      if previous,
        do: Application.put_env(:chatchat_client, :tcp_port, previous),
        else: Application.delete_env(:chatchat_client, :tcp_port)
    end)

    %{listener: listener, port: port}
  end

  defp state(socket \\ nil) do
    %{
      socket: socket,
      store: Store.new(1),
      user_id: 1,
      token: "unused",
      username: "diagnostic-test",
      preprovisioned: true,
      result_observer: self(),
      ping_timer: nil,
      reconnect_timer: nil,
      retry_timer: nil,
      inflight: %{}
    }
  end

  test "intentional disconnect counts once, ignores stale sockets, and preserves the outbox", %{
    listener: listener,
    port: port
  } do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
    {:ok, server} = :gen_tcp.accept(listener)
    {:ok, id, store} = Store.put_outbox(Store.new(1), 2, "pending")
    state = %{state(socket) | store: store}

    assert {:noreply, disconnected} = ChatchatClient.handle_cast(:disconnect, state)
    assert_receive {:connection_diagnostic, {:disconnect, :intentional}}
    assert disconnected.socket == nil
    assert [[^id, 2, "pending", nil]] = Store.outbox(disconnected.store)

    assert {:noreply, ^disconnected} =
             ChatchatClient.handle_info({:tcp_closed, socket}, disconnected)

    assert {:noreply, ^disconnected} =
             ChatchatClient.handle_info({:tcp_error, socket, :closed}, disconnected)

    assert {:noreply, ^disconnected} = ChatchatClient.handle_cast(:disconnect, disconnected)
    refute_receive {:connection_diagnostic, _}, 30
    Process.cancel_timer(disconnected.reconnect_timer)
    :gen_tcp.close(server)
  end

  test "outbox admission reports queued work even after the submitting caller times out" do
    {:ok, client} = GenServer.start(ChatchatClient, %{state() | result_observer: self()})
    :sys.suspend(client)
    assert catch_exit(GenServer.call(client, {:send_message, 2, "pending"}, 10))
    :sys.resume(client)
    assert_receive {:delivery_queued, id}
    assert [[^id, 2, "pending", nil]] = ChatchatClient.outbox(client)
    refute_receive {:delivery_queued, _}, 30
    GenServer.stop(client)
  end

  test "ping failure is distinct from an intentional disconnect" do
    # Closed sockets still enter the ping failure path; a nil socket must not
    # count a second disconnection.
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    :gen_tcp.close(listener)
    assert {:noreply, disconnected} = ChatchatClient.handle_info(:ping, state(listener))
    assert_receive {:connection_diagnostic, {:disconnect, :ping_failure}}
    Process.cancel_timer(disconnected.reconnect_timer)
    ChatchatClient.terminate(:normal, disconnected)
    refute_receive {:connection_diagnostic, _}, 30
  end

  test "transient lease loss reconnects and retries the retained identity", %{
    listener: listener,
    port: port
  } do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
    {:ok, old_server} = :gen_tcp.accept(listener)
    {:ok, id, store} = Store.put_outbox(Store.new(1), 2, "pending")

    assert {:noreply, failed} =
             ChatchatClient.handle_info(
               {:tcp, socket, ~s({"type":"error","error":"presence_unavailable"}\n)},
               %{state(socket) | store: store}
             )

    assert failed.store.suspension == nil
    assert [[^id, 2, "pending", nil]] = Store.outbox(failed.store)
    :gen_tcp.close(old_server)

    backend =
      Task.async(fn ->
        {:ok, server} = :gen_tcp.accept(listener)
        assert {:ok, _auth} = :gen_tcp.recv(server, 0, 1_000)
        :gen_tcp.send(server, ~s({"type":"authenticated","user_id":1}\n))
        assert {:ok, frame} = :gen_tcp.recv(server, 0, 1_000)
        request = Jason.decode!(frame)
        assert request["message_id"] == id

        :gen_tcp.send(
          server,
          Jason.encode!(%{
            type: "message_result",
            status: "ok",
            message_id: id,
            request_id: request["request_id"]
          }) <> "\n"
        )

        receive do
          :done -> :gen_tcp.close(server)
        end
      end)

    assert {:noreply, recovered} = ChatchatClient.handle_info(:reconnect, failed)
    assert {:noreply, sending} = ChatchatClient.handle_info(:retry_outbox, recovered)
    active = sending.socket
    assert_receive {:tcp, ^active, line}, 1_000
    assert {:noreply, confirmed} = ChatchatClient.handle_info({:tcp, active, line}, sending)
    assert_receive {:delivery_confirmed, _}
    assert Store.outbox(confirmed.store) == []
    ChatchatClient.terminate(:normal, confirmed)
    send(backend.pid, :done)
    Task.await(backend)
  end

  test "authentication failure and successful reconnect keep their existing behavior", %{
    listener: listener
  } do
    backend =
      Task.async(fn ->
        {:ok, first} = :gen_tcp.accept(listener)
        assert {:ok, _auth} = :gen_tcp.recv(first, 0, 1_000)
        :gen_tcp.send(first, ~s({"type":"error","error":"unauthorized"}\n))
        :gen_tcp.close(first)
        {:ok, second} = :gen_tcp.accept(listener)
        assert {:ok, _auth} = :gen_tcp.recv(second, 0, 1_000)
        :gen_tcp.send(second, ~s({"type":"authenticated","user_id":1}\n))

        receive do
          :done -> :gen_tcp.close(second)
        end
      end)

    assert {:noreply, failed} = ChatchatClient.handle_info(:reconnect, state())
    assert_receive {:connection_diagnostic, :reconnect_attempt}
    assert_receive {:connection_diagnostic, {:reconnect_failed, :connect_authenticate}}
    assert failed.socket == nil
    assert is_reference(failed.reconnect_timer)
    assert failed.reconnect_failures == 1
    Process.cancel_timer(failed.reconnect_timer)

    assert {:noreply, recovered} =
             ChatchatClient.handle_info(:reconnect, %{failed | reconnect_timer: nil})

    assert_receive {:connection_diagnostic, :reconnect_attempt}
    assert_receive {:connection_diagnostic, :reconnect_ok}
    assert recovered.socket != nil
    assert recovered.reconnect_failures == 0
    assert recovered.reconnect_generation == nil
    assert recovered.last_reconnect_attempt == nil
    ChatchatClient.terminate(:normal, recovered)
    assert_receive {:connection_diagnostic, {:disconnect, :shutdown}}
    send(backend.pid, :done)
    Task.await(backend)
  end

  test "repeated failures back off, ignore stale timers and retain queued identities", %{
    listener: listener
  } do
    backend =
      Task.async(fn ->
        for _ <- 1..8 do
          {:ok, socket} = :gen_tcp.accept(listener)
          assert {:ok, _} = :gen_tcp.recv(socket, 0, 1_000)
          :gen_tcp.send(socket, ~s({"type":"error","error":"unauthorized"}\n))
          :gen_tcp.close(socket)
        end
      end)

    {:ok, id, store} = Store.put_outbox(Store.new(1), 2, "pending")

    final =
      Enum.reduce(1..8, %{state() | store: store}, fn attempt, previous ->
        assert {:noreply, failed} = ChatchatClient.handle_info(:reconnect, previous)
        ceiling = min(1_000 * Integer.pow(2, min(attempt, 5)), 30_000)
        remaining = Process.read_timer(failed.reconnect_timer)
        assert remaining <= ceiling and remaining >= div(ceiling * 4, 5) - 100
        assert failed.reconnect_failures == min(attempt, 5)
        assert [[^id, 2, "pending", nil]] = Store.outbox(failed.store)
        assert {:noreply, ^failed} = ChatchatClient.handle_info({:reconnect, make_ref()}, failed)
        assert {:noreply, ^failed} = ChatchatClient.handle_cast(:disconnect, failed)
        failed
      end)

    Process.cancel_timer(final.reconnect_timer)
    Task.await(backend)
  end

  test "wrapper startup retries reset on authentication and never compete with a live client", %{
    listener: listener
  } do
    backend =
      Task.async(fn ->
        for _ <- 1..3 do
          {:ok, socket} = :gen_tcp.accept(listener)
          assert {:ok, _} = :gen_tcp.recv(socket, 0, 1_000)
          :gen_tcp.send(socket, ~s({"type":"error","error":"unauthorized"}\n))
          :gen_tcp.close(socket)
        end

        {:ok, socket} = :gen_tcp.accept(listener)
        assert {:ok, _} = :gen_tcp.recv(socket, 0, 1_000)
        :gen_tcp.send(socket, ~s({"type":"authenticated","user_id":1}\n))

        receive do
          :done -> :gen_tcp.close(socket)
        end
      end)

    clients = :ets.new(:startup_clients, [:set, :public])

    options = [
      index: 1,
      username: "startup-test",
      user_id: 1,
      clients: clients,
      simulator: self(),
      connection_counts: ConnectionDiagnostics.new()
    ]

    {:ok, wrapper, {:continue, :start_client}} = SimulatedClient.init(options)
    assert {:noreply, first} = SimulatedClient.handle_continue(:start_client, wrapper)
    assert first.restart_failures == 1

    final =
      Enum.reduce(2..3, first, fn attempt, state ->
        assert {:noreply, failed} = SimulatedClient.handle_info(:start_client, state)
        assert failed.restart_failures == attempt
        assert failed.client == nil

        assert {:noreply, ^failed} =
                 SimulatedClient.handle_info({:start_client, make_ref()}, failed)

        failed
      end)

    assert {:noreply, recovered} = SimulatedClient.handle_info(:start_client, final)
    assert is_pid(recovered.client)
    assert recovered.restart_failures == 0
    assert recovered.restart_timer == nil
    assert recovered.last_start_attempt == nil
    assert {:noreply, ^recovered} = SimulatedClient.handle_info(:start_client, recovered)

    assert {:noreply, ^recovered} =
             SimulatedClient.handle_info(
               {:DOWN, make_ref(), :process, self(), :normal},
               recovered
             )

    SimulatedClient.terminate(:normal, recovered)
    send(backend.pid, :done)
    Task.await(backend)
  end

  test "HTTP login rejection is classified as token failure", %{listener: listener, port: port} do
    previous = Application.get_env(:chatchat_client, :http_url)
    Application.put_env(:chatchat_client, :http_url, "http://localhost:#{port}")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:chatchat_client, :http_url, previous),
        else: Application.delete_env(:chatchat_client, :http_url)
    end)

    backend =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        assert {:ok, _} = :gen_tcp.recv(socket, 0, 1_000)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )

        :gen_tcp.close(socket)
      end)

    assert {:noreply, failed} =
             ChatchatClient.handle_info(:reconnect, %{state() | preprovisioned: false})

    assert_receive {:connection_diagnostic, :reconnect_attempt}
    assert_receive {:connection_diagnostic, {:reconnect_failed, :token}}
    refute_receive {:connection_diagnostic, :reconnect_ok}, 30
    Process.cancel_timer(failed.reconnect_timer)
    Task.await(backend)
  end

  test "simulation status aggregates fixed counters without losing existing fields" do
    {:ok, simulation} =
      Simulator.init(%{
        number_of_clients: 1,
        username_prefix: nil,
        send_message_probability_per_second: 0
      })

    wrapper = %{connection_counts: simulation.connection_counts}

    for event <- [
          :reconnect_attempt,
          :reconnect_ok,
          {:reconnect_failed, :token},
          {:reconnect_failed, :activate},
          {:disconnect, :peer_close}
        ] do
      assert {:noreply, ^wrapper} =
               SimulatedClient.handle_info({:connection_diagnostic, event}, wrapper)
    end

    assert {:reply, status, ^simulation} = Simulator.handle_call(:status, nil, simulation)
    assert status.queued_messages == 0
    assert status.unique_confirmed_messages == 0
    assert status.retry_attempts == 0
    assert Jason.decode!(Jason.encode!(status))["confirmation_latency_ms"]["buckets"]["100"] == 0
    assert status.connection_diagnostics.reconnects == %{attempted: 1, ok: 1, failed: 2}
    assert status.connection_diagnostics.disconnects.peer_close == 1
    assert status.connection_diagnostics.reconnect_failures.activate == 1

    assert ConnectionDiagnostics.snapshot(simulation.connection_counts) ==
             status.connection_diagnostics

    Supervisor.stop(simulation.supervisor)
  end
end
