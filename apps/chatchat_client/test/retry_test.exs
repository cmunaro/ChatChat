defmodule ChatchatClient.RetryTest do
  use ExUnit.Case, async: false
  alias ChatchatClient.Store

  setup do
    store_pid =
      start_supervised!(
        {Store,
         [
           root: Path.join(System.tmp_dir!(), "chatchat-retry-tests"),
           namespace: Ecto.UUID.generate(),
           name: nil
         ]}
      )

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

    %{listener: listener, store_pid: store_pid, store: Store.handle(store_pid)}
  end

  test "lost response retries the durable identity and ignores an old result", context do
    owner = self()

    backend =
      Task.async(fn ->
        socket = accept(context.listener)
        first = receive_send(socket)
        send(owner, {:first, first})
        second = receive_send(socket, 15_000)
        send_json(socket, Map.merge(first, %{"type" => "message_result", "status" => "ok"}))
        send(owner, {:second, second})

        receive do
          :confirm -> :ok
        end

        send_json(socket, Map.merge(second, %{"type" => "message_result", "status" => "ok"}))

        receive do
          :close -> :ok
        end

        :gen_tcp.close(socket)
      end)

    client = ChatchatClient.run_preprovisioned("retry", 1, store_server: context.store_pid)
    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    assert {:ok, id} = ChatchatClient.send_message(client, 2, "durable")
    assert_receive {:first, first}, 2_000
    assert first["message_id"] == id
    assert {:ok, [[^id, 2, "durable", nil]]} = Store.outbox(context.store, 1)
    # Exercise the actual ten-second response deadline, not a synthetic event.
    assert_receive {:second, second}, 14_000
    assert second["message_id"] == id
    assert second["request_id"] != first["request_id"]
    Process.sleep(20)
    assert {:ok, [[^id, 2, "durable", nil]]} = Store.outbox(context.store, 1)
    send(backend.pid, :confirm)
    eventually(fn -> Store.outbox(context.store, 1) == {:ok, []} end)
    send(backend.pid, :close)
    Task.await(backend)
  end

  test "process restart recovers an unknown-outcome outbox entry", context do
    owner = self()

    backend =
      Task.async(fn ->
        first_socket = accept(context.listener)
        first = receive_send(first_socket)
        send(owner, {:first, first})
        assert {:error, :closed} = :gen_tcp.recv(first_socket, 0, 2_000)
        second_socket = accept(context.listener)
        second = receive_send(second_socket, 15_000)
        send(owner, {:recovered, second})

        send_json(
          second_socket,
          Map.merge(second, %{"type" => "message_result", "status" => "ok"})
        )

        receive do
          :close -> :ok
        end

        :gen_tcp.close(second_socket)
      end)

    first_client =
      ChatchatClient.run_preprovisioned("restart", 1, store_server: context.store_pid)

    assert {:ok, id} = ChatchatClient.send_message(first_client, 2, "unknown")
    assert_receive {:first, first}, 2_000
    GenServer.stop(first_client)

    second_client =
      ChatchatClient.run_preprovisioned("restart", 1, store_server: context.store_pid)

    on_exit(fn -> if Process.alive?(second_client), do: GenServer.stop(second_client) end)
    assert_receive {:recovered, second}, 13_000
    assert second["message_id"] == id and first["message_id"] == id
    assert second["request_id"] != first["request_id"]
    eventually(fn -> Store.outbox(context.store, 1) == {:ok, []} end)
    send(backend.pid, :close)
    Task.await(backend)
  end

  test "disconnect recovers the same committed outbox entry", context do
    owner = self()

    backend =
      Task.async(fn ->
        first_socket = accept(context.listener)
        first = receive_send(first_socket)
        :gen_tcp.close(first_socket)
        second_socket = accept(context.listener)
        second = receive_send(second_socket)
        send(owner, {:retried, first, second})

        send_json(
          second_socket,
          Map.merge(second, %{"type" => "message_result", "status" => "ok"})
        )

        receive do
          :close -> :ok
        end

        :gen_tcp.close(second_socket)
      end)

    client = ChatchatClient.run_preprovisioned("disconnect", 1, store_server: context.store_pid)
    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    assert {:ok, id} = ChatchatClient.send_message(client, 2, "reconnect")
    assert_receive {:retried, first, second}, 5_000
    assert first["message_id"] == id and second["message_id"] == id
    eventually(fn -> Store.outbox(context.store, 1) == {:ok, []} end)
    send(backend.pid, :close)
    Task.await(backend)
  end

  defp accept(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    assert {:ok, line} = :gen_tcp.recv(socket, 0, 1_000)
    assert %{"type" => "authenticate"} = Jason.decode!(line)
    send_json(socket, %{type: "authenticated", user_id: 1})
    socket
  end

  defp receive_send(socket, timeout \\ 5_000) do
    assert {:ok, line} = :gen_tcp.recv(socket, 0, timeout)

    case Jason.decode!(line) do
      %{"type" => "ping"} ->
        send_json(socket, %{type: "pong"})
        receive_send(socket, timeout)

      %{"type" => "send_message"} = frame ->
        frame

      other ->
        flunk("unexpected fixture frame: #{inspect(other)}")
    end
  end

  defp send_json(socket, frame), do: :gen_tcp.send(socket, Jason.encode!(frame) <> "\n")
  defp eventually(condition, attempts \\ 200)
  defp eventually(condition, 0), do: assert(condition.())

  defp eventually(condition, attempts) do
    unless condition.() do
      Process.sleep(10)
      eventually(condition, attempts - 1)
    end
  end
end
