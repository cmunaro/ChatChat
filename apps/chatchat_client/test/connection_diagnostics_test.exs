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
    Process.cancel_timer(failed.reconnect_timer)

    assert {:noreply, recovered} =
             ChatchatClient.handle_info(:reconnect, %{failed | reconnect_timer: nil})

    assert_receive {:connection_diagnostic, :reconnect_attempt}
    assert_receive {:connection_diagnostic, :reconnect_ok}
    assert recovered.socket != nil
    ChatchatClient.terminate(:normal, recovered)
    assert_receive {:connection_diagnostic, {:disconnect, :shutdown}}
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
    {:ok, simulation} = Simulator.init(%{number_of_clients: 1, username_prefix: nil})
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
    assert status.connection_diagnostics.reconnects == %{attempted: 1, ok: 1, failed: 2}
    assert status.connection_diagnostics.disconnects.peer_close == 1
    assert status.connection_diagnostics.reconnect_failures.activate == 1

    assert ConnectionDiagnostics.snapshot(simulation.connection_counts) ==
             status.connection_diagnostics

    Supervisor.stop(simulation.supervisor)
  end
end
