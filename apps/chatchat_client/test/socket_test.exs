defmodule ChatchatClient.SocketTest do
  use ExUnit.Case, async: true
  alias ChatchatClient.{Socket, Store}

  setup do
    pid =
      start_supervised!(
        {Store,
         [
           root: Path.join(System.tmp_dir!(), "chatchat-socket-tests"),
           namespace: Ecto.UUID.generate(),
           name: nil
         ]}
      )

    %{store: Store.handle(pid), pid: pid}
  end

  test "matches both IDs and passes late results to the bounded client lifecycle", %{store: store} do
    {client, server} = connected_sockets()
    :ok = Socket.activate(client)
    request = Ecto.UUID.generate()
    id = Ecto.UUID.generate()
    owner = self()

    context = %{
      store: store,
      user_id: 2,
      on_result: fn result -> send(owner, {:result, result}) end
    }

    late = Ecto.UUID.generate()

    task =
      Task.async(fn ->
        assert {:ok, _} = :gen_tcp.recv(server, 0, 1_000)

        send_json(server, %{
          type: "message_result",
          request_id: late,
          message_id: id,
          status: "ok"
        })

        send_json(server, %{
          type: "message_result",
          request_id: request,
          message_id: id,
          status: "ok"
        })
      end)

    matcher =
      &match?(%{"type" => "message_result", "request_id" => ^request, "message_id" => ^id}, &1)

    assert {:ok, %{"request_id" => ^request}} =
             Socket.request(client, %{type: "ping"}, matcher, context)

    assert_receive {:result, %{"request_id" => ^late}}
    Task.await(task)
  end

  test "interleaved receive commits before ACK and duplicates ACK again", %{store: store} do
    {client, server} = connected_sockets()
    :ok = Socket.activate(client)
    id = Ecto.UUID.generate()

    frame = %{
      type: "message",
      message_id: id,
      from_user_id: 1,
      message: "hello",
      inserted_at: "2026-10-09T10:00:00.000000Z",
      receipt_id: Ecto.UUID.generate()
    }

    owner = self()

    task =
      Task.async(fn ->
        assert {:ok, _} = :gen_tcp.recv(server, 0, 1_000)

        for _ <- 1..2 do
          send_json(server, frame)
          assert {:ok, line} = :gen_tcp.recv(server, 0, 1_000)

          assert %{"type" => "message_delivered_ack", "message_id" => ^id, "from_user_id" => 1} =
                   Jason.decode!(line)

          assert {:ok, [[1, ^id, "hello", _]]} = Store.inbox(store, 2)
        end

        send_json(server, %{type: "pong"})
      end)

    assert {:ok, %{"type" => "pong"}} =
             Socket.request(client, %{type: "ping"}, &match?(%{"type" => "pong"}, &1), %{
               store: store,
               user_id: 2,
               on_message: fn message ->
                 assert {:ok, [[1, ^id, "hello", _]]} = Store.inbox(store, 2)
                 send(owner, {:received_message, message})
               end
             })

    Task.await(task)
    assert_received {:received_message, %{"message_id" => ^id, "message" => "hello"}}
    refute_received {:received_message, _}
  end

  test "durable write failure sends no receipt ACK", %{store: store, pid: pid} do
    {client, server} = connected_sockets()
    %{db: db} = :sys.get_state(pid)
    :ok = Exqlite.Sqlite3.execute(db, "PRAGMA query_only=ON")

    frame = %{
      type: "message",
      message_id: Ecto.UUID.generate(),
      from_user_id: 1,
      message: "unsaved",
      inserted_at: "2026-10-09T10:00:00Z",
      receipt_id: Ecto.UUID.generate()
    }

    assert {:error, {:receive_storage, _}} =
             Socket.handle_incoming(client, Jason.encode!(frame), %{store: store, user_id: 2})

    assert {:error, :timeout} = :gen_tcp.recv(server, 0, 50)
    assert {:ok, []} = Store.inbox(store, 2)
  end

  test "uncorrelated error durably suspends the user's automatic sends", %{store: store} do
    {client, _server} = connected_sockets()
    assert {:ok, _} = Store.put_outbox(store, 2, 1, "retained")

    assert {:error, {:protocol_suspended, "invalid_request"}} =
             Socket.handle_incoming(
               client,
               Jason.encode!(%{type: "error", error: "invalid_request"}),
               %{store: store, user_id: 2}
             )

    assert {:ok, "invalid_request"} = Store.suspension(store, 2)
    assert {:ok, []} = Store.pending(store, 2)
    assert {:ok, [_]} = Store.outbox(store, 2)
  end

  test "malformed server results and error reasons safely suspend retries", %{store: store} do
    {client, _server} = connected_sockets()

    context = %{
      store: store,
      user_id: 2,
      on_result: fn _ -> flunk("invalid result forwarded") end
    }

    for frame <- [
          %{type: "error", error: %{unexpected: true}},
          %{type: "message_result", status: "ok"},
          %{type: "unknown"}
        ] do
      assert {:error, {:protocol_suspended, "invalid_response"}} =
               Socket.handle_incoming(client, Jason.encode!(frame), context)

      assert {:ok, "invalid_response"} = Store.suspension(store, 2)
    end
  end

  defp connected_sockets do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    owner = self()

    task =
      Task.async(fn ->
        {:ok, server} = :gen_tcp.accept(listener)
        :ok = :gen_tcp.controlling_process(server, owner)
        server
      end)

    {:ok, client} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :line])

    server = Task.await(task)
    :gen_tcp.close(listener)

    on_exit(fn ->
      Socket.close(client)
      Socket.close(server)
    end)

    {client, server}
  end

  defp send_json(socket, payload), do: :gen_tcp.send(socket, Jason.encode!(payload) <> "\n")
end
