defmodule ChatchatClient.SocketTest do
  use ExUnit.Case, async: true
  alias ChatchatClient.{Socket, Store}

  defp state do
    %{store: Store.new(2), user_id: 2, username: "test", inflight: %{}, result_observer: self()}
  end

  test "edit replacement cancels inflight attempts and ignores late results and timeouts" do
    {:ok, id, store} = Store.put_outbox(Store.new(2), 1, "original")
    request = Ecto.UUID.generate()
    {:ok, store} = Store.begin_attempt(store, id, request)
    timer = Process.send_after(self(), :unused_timeout, 10_000)
    initial = %{state() | store: store, inflight: %{id => {request, timer}}}

    assert {:reply, {:ok, ^id}, updated} =
             ChatchatClient.handle_call({:edit_message, 1, id, "edited"}, nil, initial)

    assert Process.read_timer(timer) == false
    assert updated.inflight == %{}
    assert_receive :retry_outbox

    assert {:noreply, ^updated} =
             ChatchatClient.handle_info({:send_timeout, id, request}, updated)

    response = %{
      "type" => "message_result",
      "message_id" => id,
      "request_id" => request,
      "status" => "ok"
    }

    assert {:ok, ^updated} = ChatchatClient.handle_response(nil, response, updated)
    assert Store.outbox(updated.store) == [[id, 1, "edited", nil]]
  end

  test "mock receiver logs and ACKs edits without modifying the inbox" do
    {client, server} = connected_sockets()

    frame = %{
      "type" => "edit_message",
      "from_user_id" => 1,
      "message_id" => Ecto.UUID.generate(),
      "message" => "edited",
      "inserted_at" => "2026-10-15T10:00:00.000000Z",
      "receipt_id" => Ecto.UUID.generate()
    }

    initial = state()

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:ok, ^initial} = ChatchatClient.handle_response(client, frame, initial)
        assert {:ok, ^initial} = ChatchatClient.handle_response(client, frame, initial)
      end)

    assert output =~ "received message edit"

    for _ <- 1..2 do
      assert {:ok, line} = :gen_tcp.recv(server, 0, 1_000)

      assert Jason.decode!(line) ==
               frame
               |> Map.take(["from_user_id", "message_id", "receipt_id"])
               |> Map.put("type", "message_delivered_ack")
    end

    for invalid <- [
          Map.put(frame, "inserted_at", "invalid"),
          Map.put(frame, "message", 1),
          Map.put(frame, "receipt_id", "invalid")
        ] do
      assert {:error, :invalid_edit, ^initial} =
               ChatchatClient.handle_response(client, invalid, initial)
    end

    assert {:error, :timeout} = :gen_tcp.recv(server, 0, 30)
  end

  test "delete helper refuses messages still awaiting delivery" do
    initial = state()
    {:ok, id, store} = Store.put_outbox(initial.store, 1, "pending")
    initial = %{initial | store: store}

    assert {:reply, {:error, :message_pending}, ^initial} =
             ChatchatClient.handle_call({:delete_message, 1, id}, nil, initial)
  end

  test "mock client logs and acknowledges a deletion without changing its store" do
    {client, server} = connected_sockets()

    frame = %{
      "type" => "message_deleted",
      "from_user_id" => 1,
      "message_id" => Ecto.UUID.generate(),
      "receipt_id" => Ecto.UUID.generate()
    }

    initial = state()

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:ok, ^initial} = ChatchatClient.handle_response(client, frame, initial)
      end)

    assert output =~ "received message deletion"
    assert {:ok, line} = :gen_tcp.recv(server, 0, 1_000)
    assert Jason.decode!(line) == Map.put(frame, "type", "message_delivered_ack")
  end

  test "interleaved confirmations update state before the request completes" do
    {client, server} = connected_sockets()
    :ok = Socket.activate(client)
    {:ok, id, store} = Store.put_outbox(Store.new(2), 1, "hello")
    request = Ecto.UUID.generate()
    {:ok, store} = Store.begin_attempt(store, id, request)
    timer = Process.send_after(self(), :unused_timeout, 10_000)
    state = %{state() | store: store, inflight: %{id => {request, timer}}}

    task =
      Task.async(fn ->
        assert {:ok, _} = :gen_tcp.recv(server, 0, 1_000)

        send_json(server, %{
          type: "message_result",
          request_id: Ecto.UUID.generate(),
          message_id: id,
          status: "ok"
        })

        send_json(server, %{
          type: "message_result",
          request_id: request,
          message_id: id,
          status: "ok"
        })

        send_json(server, %{type: "pong"})
      end)

    assert {:ok, %{"type" => "pong"}, state} =
             Socket.request(client, %{type: "ping"}, &match?(%{"type" => "pong"}, &1), state)

    assert Store.outbox(state.store) == []
    assert state.inflight == %{}
    assert_receive {:delivery_result, :ok}
    assert_receive {:delivery_confirmed, latency}
    assert latency >= 0
    refute_received {:delivery_confirmed, _}
    refute_received {:delivery_result, _}
    Task.await(task)
  end

  test "confirmation latency includes failed attempts and ignores stale results" do
    {:ok, id, store} = Store.put_outbox(Store.new(2), 1, "retry")
    {:value, entry} = :gb_trees.lookup(id, store.outbox)

    store = %{
      store
      | outbox: :gb_trees.update(id, %{entry | queued_at: entry.queued_at - 1_000}, store.outbox)
    }

    first = Ecto.UUID.generate()
    {:ok, store} = Store.begin_attempt(store, id, first)
    timer = Process.send_after(self(), :unused_timeout, 10_000)
    state = %{state() | store: store, inflight: %{id => {first, timer}}}

    failed = %{
      "type" => "message_result",
      "message_id" => id,
      "request_id" => first,
      "status" => "failed",
      "reason" => "unavailable"
    }

    assert {:ok, state} = ChatchatClient.handle_response(nil, failed, state)
    assert_receive {:delivery_result, :failed}
    refute_received {:delivery_confirmed, _}

    second = Ecto.UUID.generate()
    {:ok, store} = Store.begin_attempt(state.store, id, second)
    timer = Process.send_after(self(), :unused_timeout, 10_000)
    state = %{state | store: store, inflight: %{id => {second, timer}}}
    ok = Map.put(failed, "status", "ok")
    assert {:ok, ^state} = ChatchatClient.handle_response(nil, ok, state)
    refute_received {:delivery_confirmed, _}

    assert {:ok, state} =
             ChatchatClient.handle_response(nil, Map.put(ok, "request_id", second), state)

    assert_receive {:delivery_confirmed, latency}
    assert latency >= 1_000
    assert Store.outbox(state.store) == []

    assert {:ok, ^state} =
             ChatchatClient.handle_response(nil, Map.put(ok, "request_id", second), state)

    refute_received {:delivery_confirmed, _}
  end

  for ending <- [:pong, :closed, :invalid] do
    @ending ending
    test "interleaved inbox state survives #{@ending} and duplicates ACK again" do
      {client, server} = connected_sockets()
      :ok = Socket.activate(client)
      id = Ecto.UUID.generate()

      frame = %{
        type: "message",
        message_id: id,
        from_user_id: 1,
        message: "hello",
        inserted_at: "2026-10-09T10:00:00Z",
        receipt_id: Ecto.UUID.generate()
      }

      task =
        Task.async(fn ->
          assert {:ok, _} = :gen_tcp.recv(server, 0, 1_000)

          for _ <- 1..2 do
            send_json(server, frame)
            assert {:ok, line} = :gen_tcp.recv(server, 0, 1_000)
            assert %{"type" => "message_delivered_ack", "message_id" => ^id} = Jason.decode!(line)
          end

          case @ending do
            :pong -> send_json(server, %{type: "pong"})
            :closed -> :gen_tcp.close(server)
            :invalid -> :gen_tcp.send(server, "invalid JSON\n")
          end
        end)

      result = Socket.request(client, %{type: "ping"}, &match?(%{"type" => "pong"}, &1), state())

      returned_state =
        case @ending do
          :pong ->
            assert {:ok, %{"type" => "pong"}, state} = result
            state

          :closed ->
            assert {:error, :closed, state} = result
            state

          :invalid ->
            assert {:error, {:protocol_suspended, "invalid_response"}, state} = result
            state
        end

      assert Store.inbox(returned_state.store) == [[1, id, "hello", "2026-10-09T10:00:00Z"]]
      Task.await(task)
    end
  end

  test "conflicting received content is not acknowledged" do
    {client, server} = connected_sockets()
    id = Ecto.UUID.generate()

    frame = %{
      type: "message",
      message_id: id,
      from_user_id: 1,
      message: "hello",
      inserted_at: "2026-10-09T10:00:00Z",
      receipt_id: Ecto.UUID.generate()
    }

    assert {:ok, state} = Socket.handle_incoming(client, Jason.encode!(frame), state())
    assert {:ok, _} = :gen_tcp.recv(server, 0, 1_000)

    assert {:error, {:receive_storage, {:error, :identity_conflict}}, ^state} =
             Socket.handle_incoming(client, Jason.encode!(%{frame | message: "changed"}), state)

    assert {:error, :timeout} = :gen_tcp.recv(server, 0, 50)
  end

  test "ACK send failure still returns the recorded inbox state" do
    {client, _server} = connected_sockets()
    :ok = Socket.close(client)
    id = Ecto.UUID.generate()

    frame = %{
      type: "message",
      message_id: id,
      from_user_id: 1,
      message: "hello",
      inserted_at: "2026-10-09T10:00:00Z",
      receipt_id: Ecto.UUID.generate()
    }

    assert {:error, :closed, state} =
             Socket.handle_incoming(client, Jason.encode!(frame), state())

    assert Store.inbox(state.store) == [[1, id, "hello", "2026-10-09T10:00:00Z"]]
  end

  test "transient presence errors during a request preserve retry state and existing safety holds" do
    {client, server} = connected_sockets()
    {:ok, _id, store} = Store.put_outbox(Store.new(2), 1, "retained")
    state = %{state() | store: store}
    frame = Jason.encode!(%{type: "error", error: "presence_unavailable"})
    :ok = Socket.activate(client)
    :ok = :gen_tcp.send(server, frame <> "\n")

    assert {:error, :presence_unavailable, ^state} =
             Socket.request(client, %{type: "ping"}, &(&1["type"] == "pong"), state)

    assert length(Store.pending(state.store)) == 1
    held = %{state | store: Store.suspend(state.store, "invalid_response")}
    assert {:error, :presence_unavailable, ^held} = Socket.handle_incoming(client, frame, held)
    assert Store.pending(held.store) == []
  end

  test "uncorrelated and malformed responses suspend automatic retries" do
    {client, _server} = connected_sockets()
    {:ok, _id, store} = Store.put_outbox(Store.new(2), 1, "retained")
    state = %{state() | store: store}

    for frame <- [
          %{type: "error", error: "invalid_request"},
          %{type: "error", error: %{unexpected: true}},
          %{type: "message_result", status: "ok"},
          %{type: "unknown"}
        ] do
      assert {:error, {:protocol_suspended, reason}, state} =
               Socket.handle_incoming(client, Jason.encode!(frame), state)

      assert state.store.suspension == reason
      assert Store.pending(state.store) == []
      assert length(Store.outbox(state.store)) == 1
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
