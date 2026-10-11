defmodule ChatchatTcp.MessageDeliveryTest do
  use ExUnit.Case, async: false

  alias ChatchatBroker.Repo
  alias ChatchatBroker.Storage.{MessagesStore, Schemas.Message, Schemas.User}
  alias ChatchatTcp.{Capacity, MessageDelivery}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    users =
      for _ <- 1..3,
          do: Repo.insert!(%User{username: Ecto.UUID.generate(), password_hash: "unused"})

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> Enum.each(users, &Repo.delete!/1) end)
    end)

    [sender, receiver, other] = users
    previous_port = Application.get_env(:chatchat_client, :tcp_port)
    Application.put_env(:chatchat_client, :tcp_port, ChatchatTcp.port())

    on_exit(fn ->
      if previous_port,
        do: Application.put_env(:chatchat_client, :tcp_port, previous_port),
        else: Application.delete_env(:chatchat_client, :tcp_port)
    end)

    %{sender: sender, receiver: receiver, other: other}
  end

  test "confirmed local receipt makes no per-message PostgreSQL queries or Redis payload writes",
       %{
         sender: sender,
         receiver: receiver
       } do
    observe_stages()
    from = connect(sender.id)
    to = connect(receiver.id)
    request = request(receiver.id)
    observer = self()
    telemetry_id = make_ref()
    {:ok, database_id} = Ecto.UUID.dump(request.message_id)

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:chatchat_broker, :repo, :query],
        fn _, _, metadata, {observer, database_id} ->
          # Independent connection/reconciliation inbox reads are still expected.
          if String.contains?(metadata.query, "\"messages\"") and
               database_id in metadata.params,
             do: send(observer, :message_query)
        end,
        {observer, database_id}
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)
    send_json(from, request)
    assert {:ok, frame} = recv(to)
    assert frame["message_id"] == request.message_id
    assert frame["from_user_id"] == sender.id
    assert {:error, :timeout} = :gen_tcp.recv(from, 0, 50)
    acknowledge(to, frame)
    assert {:ok, %{"status" => "ok", "request_id" => request_id}} = recv(from)
    assert request_id == request.request_id
    refute_receive :message_query
    :telemetry.detach(telemetry_id)
    assert Repo.get_by(Message, sender_id: sender.id, message_id: request.message_id) == nil

    assert {:ok, nil} =
             Redix.command(ChatchatTcp.Redis.Heartbeat, [
               "GET",
               "chatchat:message:#{request.message_id}"
             ])

    eventually(fn -> MessageDelivery.metric_snapshot().attempts == 0 end)
    assert_stage(:queue, :dispatched)
    assert_stage(:schedule, :started)
    assert_stage(:route, :ok)
    assert_stage(:direct_wait, :ok)
    refute_receive {:stage, _, %{stage: :direct_wait}}, 30
    refute_receive {:stage, _, %{stage: :persist}}, 30
  end

  test "offline commit and reconnect recover ownership with scoped deletion", %{
    sender: sender,
    receiver: receiver,
    other: other
  } do
    observe_stages()
    from = connect(sender.id)
    request = request(receiver.id)
    send_json(from, request)
    assert {:ok, %{"status" => "ok"}} = recv(from)
    assert_stage(:route, :error)
    assert_stage(:persist, :ok)
    assert_stage(:wake, :ok)

    assert %Message{payload: "hello"} =
             Repo.get_by!(Message, sender_id: sender.id, message_id: request.message_id)

    to = connect(receiver.id)
    wrong = connect(other.id)
    assert {:ok, frame} = recv(to)
    acknowledge(wrong, frame)
    Process.sleep(20)
    assert Repo.get_by(Message, sender_id: sender.id, message_id: request.message_id)
    acknowledge(to, frame)

    eventually(fn ->
      Repo.get_by(Message, sender_id: sender.id, message_id: request.message_id) == nil
    end)
  end

  test "wrong identity and receiver ACKs cannot confirm a direct attempt", %{
    sender: sender,
    receiver: receiver,
    other: other
  } do
    from = connect(sender.id)
    to = connect(receiver.id)
    wrong = connect(other.id)
    send_json(from, request(receiver.id))
    assert {:ok, frame} = recv(to)
    acknowledge(wrong, frame)
    acknowledge(to, Map.put(frame, "from_user_id", other.id))
    assert {:error, :timeout} = :gen_tcp.recv(from, 0, 50)
    acknowledge(to, frame)
    assert {:ok, %{"status" => "ok"}} = recv(from)
  end

  test "direct receipt timeout commits fallback and ignores expired correlation", %{
    sender: sender,
    receiver: receiver
  } do
    observe_stages()
    from = connect(sender.id)
    to = connect(receiver.id)
    request = request(receiver.id)
    send_json(from, request)
    assert {:ok, direct} = recv(to)
    assert {:ok, %{"status" => "ok"}} = recv(from, 4_000)
    assert_stage(:direct_wait, :fallback)
    assert_stage(:persist, :ok)
    assert_stage(:wake, :ok)
    refute_receive {:stage, _, %{stage: :direct_wait}}, 30
    assert Repo.get_by(Message, sender_id: sender.id, message_id: request.message_id)
    acknowledge(to, direct)
    Process.sleep(20)
    assert Repo.get_by(Message, sender_id: sender.id, message_id: request.message_id)
  end

  test "fallback rejects conflicting stored identity", %{
    sender: sender,
    receiver: receiver
  } do
    request = request(receiver.id)

    assert {:ok, _} =
             MessagesStore.insert_pending(%{
               sender_id: sender.id,
               receiver_id: receiver.id,
               message_id: request.message_id,
               payload: "immutable"
             })

    from = connect(sender.id)
    send_json(from, request)
    assert {:ok, %{"status" => "rejected", "reason" => "identity_conflict"}} = recv(from)
  end

  test "capacity rejection precedes payload work", %{sender: sender, receiver: receiver} do
    from = connect(sender.id)

    tickets =
      for _ <- 1..409 do
        assert {:ok, ticket} = Capacity.claim(ChatchatTcp.SenderCapacity)
        ticket
      end

    try do
      send_json(from, request(receiver.id))
      assert {:ok, %{"status" => "failed", "reason" => "capacity"}} = recv(from)
      assert MessageDelivery.metric_snapshot().attempts == 0
    after
      Enum.each(tickets, &Capacity.release(ChatchatTcp.SenderCapacity, &1))
    end
  end

  test "authenticated identity and canonical IDs are mandatory", %{
    sender: sender,
    receiver: receiver
  } do
    from = connect(sender.id)
    send_json(from, Map.put(request(receiver.id), :sender_id, receiver.id))
    assert {:ok, %{"status" => "rejected", "reason" => "invalid_request"}} = recv(from)
    send_json(from, %{type: "send_message", request_id: "malformed", message_id: "malformed"})
    assert {:ok, %{"type" => "error", "error" => "invalid_request"}} = recv(from)
    assert {:error, :closed} = :gen_tcp.recv(from, 0, 100)
  end

  test "permanent invalid receiver does not become retryable failure", %{sender: sender} do
    observe_stages()
    from = connect(sender.id)
    send_json(from, request(9_223_372_036_854_775_807))
    assert {:ok, %{"status" => "rejected", "reason" => "invalid_receiver"}} = recv(from)
    assert_stage(:persist, :error)
    refute_receive {:stage, _, %{stage: :wake}}, 30
  end

  test "coalesced lost-wakeup reconciliation recovers a committed row", %{
    sender: sender,
    receiver: receiver
  } do
    to = connect(receiver.id)
    Process.sleep(20)
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             MessagesStore.insert_pending(%{
               sender_id: sender.id,
               receiver_id: receiver.id,
               message_id: id,
               payload: "lost wakeup"
             })

    send(ChatchatTcp.Delivery, :reconcile)
    assert {:ok, %{"message_id" => ^id} = frame} = recv(to)
    acknowledge(to, frame)
    eventually(fn -> Repo.get_by(Message, sender_id: sender.id, message_id: id) == nil end)
    assert ChatchatTcp.Delivery.metric_snapshot().loaded_bytes <= 8 * 1_024 * 1_024
  end

  test "crashed inbox worker releases page bytes and reconciliation recovers", %{
    sender: sender,
    receiver: receiver
  } do
    to = connect(receiver.id)
    eventually(fn -> ChatchatTcp.Delivery.metric_snapshot().active_workers == 0 end)
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             MessagesStore.insert_pending(%{
               sender_id: sender.id,
               receiver_id: receiver.id,
               message_id: id,
               payload: "worker recovery"
             })

    parent = self()

    lock =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Ecto.Adapters.SQL.query!(Repo, "LOCK TABLE messages IN ACCESS EXCLUSIVE MODE", [])
            send(parent, :inbox_locked)

            receive do
              :release -> :ok
            after
              3_000 -> :ok
            end
          end)
        end)
      end)

    assert_receive :inbox_locked
    ChatchatTcp.Delivery.wake(receiver.id)
    eventually(fn -> ChatchatTcp.Delivery.metric_snapshot().active_workers == 1 end)

    {_reference, {_, reserved, worker}} =
      Enum.find(:sys.get_state(ChatchatTcp.Delivery).workers, fn {_, {user, _, _}} ->
        user == receiver.id
      end)

    assert reserved > 0
    Process.exit(worker, :kill)
    eventually(fn -> ChatchatTcp.Delivery.metric_snapshot().loaded_bytes == 0 end)
    send(lock.pid, :release)
    Task.await(lock)
    send(ChatchatTcp.Delivery, :reconcile)
    assert {:ok, %{"message_id" => ^id} = frame} = recv(to)
    acknowledge(to, frame)
    eventually(fn -> Repo.get_by(Message, sender_id: sender.id, message_id: id) == nil end)
  end

  test "saturated wake ingress drops hints and reconciliation still recovers", %{
    sender: sender,
    receiver: receiver
  } do
    to = connect(receiver.id)
    eventually(fn -> ChatchatTcp.Delivery.metric_snapshot().active_workers == 0 end)
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             MessagesStore.insert_pending(%{
               sender_id: sender.id,
               receiver_id: receiver.id,
               message_id: id,
               payload: "recover after saturation"
             })

    :ok = :sys.suspend(ChatchatTcp.Delivery)

    try do
      for user <- 1..4_200, do: ChatchatTcp.Delivery.wake(user + 9_000_000)
      entries = :ets.tab2list(ChatchatTcp.InboxWakeCapacity)
      assert length(entries) == 4_097
      assert :ok = ChatchatTcp.Delivery.wake(receiver.id)
      assert length(:ets.tab2list(ChatchatTcp.InboxWakeCapacity)) == 4_097
    after
      :sys.resume(ChatchatTcp.Delivery)
    end

    send(ChatchatTcp.Delivery, :reconcile)
    assert {:ok, %{"message_id" => ^id} = frame} = recv(to, 3_000)
    acknowledge(to, frame)
    eventually(fn -> Repo.get_by(Message, sender_id: sender.id, message_id: id) == nil end)
    eventually(fn -> ChatchatTcp.Delivery.metric_snapshot().loaded_bytes == 0 end)
  end

  test "mocked client deduplicates until its process restarts", %{
    sender: sender,
    receiver: receiver
  } do
    client = ChatchatClient.run_preprovisioned("unused", receiver.id)
    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    from = connect(sender.id)
    request = request(receiver.id)
    send_json(from, request)
    assert {:ok, %{"status" => "ok"}} = recv(from)
    assert rows = ChatchatClient.inbox(client)
    assert [[sender_id, id, "hello", _timestamp]] = rows
    assert sender_id == sender.id and id == request.message_id
    send_json(from, %{request | request_id: Ecto.UUID.generate()})
    assert {:ok, %{"status" => "ok"}} = recv(from)
    assert ^rows = ChatchatClient.inbox(client)
    GenServer.stop(client)
    eventually(fn -> not ChatchatTcp.Presence.online?(receiver.id) end)
    restarted = ChatchatClient.run_preprovisioned("unused", receiver.id)
    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)
    assert ChatchatClient.inbox(restarted) == []
    send_json(from, %{request | request_id: Ecto.UUID.generate()})
    assert {:ok, %{"status" => "ok"}} = recv(from)
    assert [[^sender_id, ^id, "hello", _timestamp]] = ChatchatClient.inbox(restarted)
  end

  @tag capture_log: true
  test "storage outage without receipt returns failed and releases attempts", %{
    sender: sender,
    receiver: receiver
  } do
    from = connect(sender.id)
    :ok = Supervisor.terminate_child(ChatchatBroker.Supervisor, Repo)

    on_exit(fn ->
      if Process.whereis(Repo) == nil do
        {:ok, _} = Supervisor.restart_child(ChatchatBroker.Supervisor, Repo)
        Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
      end
    end)

    request = request(receiver.id)
    send_json(from, request)
    assert {:ok, %{"status" => "failed", "reason" => "unavailable"}} = recv(from)
    eventually(fn -> MessageDelivery.metric_snapshot().attempts == 0 end)
    {:ok, _} = Supervisor.restart_child(ChatchatBroker.Supervisor, Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    eventually(fn -> match?({:ok, _}, Ecto.Adapters.SQL.query(Repo, "SELECT 1", [])) end)
    send_json(from, %{request | request_id: Ecto.UUID.generate()})
    assert {:ok, %{"status" => "ok"}} = recv(from)
    assert Repo.get_by!(Message, sender_id: sender.id, message_id: request.message_id)
    to = connect(receiver.id)
    assert {:ok, frame} = recv(to)
    assert frame["message_id"] == request.message_id
    acknowledge(to, frame)

    eventually(fn ->
      Repo.get_by(Message, sender_id: sender.id, message_id: request.message_id) == nil
    end)
  end

  test "ACK racing a running insert completes once and leaves committed row recoverable", %{
    sender: sender,
    receiver: receiver
  } do
    from = connect(sender.id)
    to = connect(receiver.id)
    request = request(receiver.id)
    send_json(from, request)
    assert {:ok, frame} = recv(to)
    parent = self()

    lock =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Ecto.Adapters.SQL.query!(Repo, "LOCK TABLE messages IN SHARE MODE", [])
            send(parent, :locked)

            receive do
              :release -> :ok
            after
              3_000 -> :ok
            end
          end)
        end)
      end)

    assert_receive :locked

    {reference, _} =
      Enum.find(:sys.get_state(MessageDelivery).attempts, fn {_, attempt} ->
        attempt.id == request.message_id
      end)

    send(MessageDelivery, {:permit_refused, reference})
    eventually(fn -> :sys.get_state(MessageDelivery).attempts[reference].job != nil end)
    acknowledge(to, frame)
    assert {:ok, %{"status" => "ok"}} = recv(from)
    send(lock.pid, :release)
    Task.await(lock)

    eventually(fn ->
      Repo.get_by(Message, sender_id: sender.id, message_id: request.message_id) != nil
    end)

    eventually(fn -> MessageDelivery.metric_snapshot().attempts == 0 end)
    assert {:error, :timeout} = :gen_tcp.recv(from, 0, 50)
  end

  test "worker scheduling past the sender deadline never starts a persistence write", %{
    sender: sender,
    receiver: receiver
  } do
    from = connect(sender.id)
    request = request(receiver.id)
    pause_stages([{:route, :routing, :error}, {:schedule, :fallback, :started}])
    send_json(from, request)
    assert_receive {:paused_stage, routing, :route}

    {reference, _} =
      Enum.find(:sys.get_state(MessageDelivery).attempts, fn {_, attempt} ->
        attempt.id == request.message_id
      end)

    :sys.replace_state(MessageDelivery, fn state ->
      attempt = state.attempts[reference]
      Process.cancel_timer(attempt.result_timer)

      attempt = %{
        attempt
        | deadline: System.monotonic_time(:millisecond) + 300,
          result_timer: Process.send_after(MessageDelivery, {:deadline, reference}, 300)
      }

      %{state | attempts: Map.put(state.attempts, reference, attempt)}
    end)

    send(routing, :continue)
    assert_receive {:paused_stage, worker, :schedule}
    Process.sleep(350)
    send(worker, :continue)
    assert {:ok, %{"status" => "failed"}} = recv(from)
    eventually(fn -> MessageDelivery.metric_snapshot().attempts == 0 end)
    assert Repo.get_by(Message, sender_id: sender.id, message_id: request.message_id) == nil
  end

  test "confirmed late commit remains recoverable when the sender sees failure", %{
    sender: sender,
    receiver: receiver
  } do
    from = connect(sender.id)
    request = request(receiver.id)
    pause_stages([{:persist, :fallback, :ok}])
    send_json(from, request)
    assert_receive {:paused_stage, worker, :persist}

    {reference, _} =
      Enum.find(:sys.get_state(MessageDelivery).attempts, fn {_, attempt} ->
        attempt.id == request.message_id
      end)

    :sys.replace_state(MessageDelivery, fn state ->
      attempt = state.attempts[reference]
      Process.cancel_timer(attempt.result_timer)

      %{
        state
        | attempts:
            Map.put(state.attempts, reference, %{
              attempt
              | deadline: System.monotonic_time(:millisecond) - 1,
                result_timer: nil
            })
      }
    end)

    send(MessageDelivery, {:deadline, reference})
    assert {:ok, %{"status" => "failed"}} = recv(from)
    original = Repo.get_by!(Message, sender_id: sender.id, message_id: request.message_id)
    send(worker, :continue)
    eventually(fn -> MessageDelivery.metric_snapshot().attempts == 0 end)
    # Disable the pause before replaying the same immutable identity.
    :telemetry.detach({__MODULE__, :pause, self()})
    send_json(from, %{request | request_id: Ecto.UUID.generate()})
    assert {:ok, %{"status" => "ok"}} = recv(from)
    assert original == Repo.get_by!(Message, sender_id: sender.id, message_id: request.message_id)
    to = connect(receiver.id)
    assert {:ok, frame} = recv(to)
    acknowledge(to, frame)

    eventually(fn ->
      Repo.get_by(Message, sender_id: sender.id, message_id: request.message_id) == nil
    end)
  end

  test "commit acknowledgement precedes a delayed failed Redis wakeup", %{
    sender: sender,
    receiver: receiver
  } do
    from = connect(sender.id)
    request = request(receiver.id)
    pause_stages([{:persist, :fallback, :ok}])
    send_json(from, request)
    assert_receive {:paused_stage, worker, :persist}
    lane = ChatchatTcp.PresenceRedis.lane(:session, receiver.id)
    :sys.suspend(lane)

    try do
      send(worker, :continue)
      assert {:ok, %{"status" => "ok"}} = recv(from)
      assert Repo.get_by(Message, sender_id: sender.id, message_id: request.message_id)
      assert map_size(:sys.get_state(MessageDelivery).jobs) > 0
      Process.sleep(ChatchatTcp.PresenceRedis.Lane.timeout() + 20)
    after
      :sys.resume(lane)
    end

    eventually(fn -> MessageDelivery.metric_snapshot().attempts == 0 end)
    assert Repo.get_by(Message, sender_id: sender.id, message_id: request.message_id)
    :telemetry.detach({__MODULE__, :pause, self()})
    to = connect(receiver.id)
    assert {:ok, frame} = recv(to)
    acknowledge(to, frame)

    eventually(fn ->
      Repo.get_by(Message, sender_id: sender.id, message_id: request.message_id) == nil
    end)
  end

  def pause_stage(
        _event,
        _measurements,
        %{stage: stage, phase: phase, outcome: outcome},
        {owner, wanted}
      ) do
    if {stage, phase, outcome} in wanted do
      send(owner, {:paused_stage, self(), stage})

      receive do
        :continue -> :ok
      after
        2_000 -> :ok
      end
    end
  end

  defp pause_stages(wanted) do
    id = {__MODULE__, :pause, self()}

    :telemetry.attach(
      id,
      [:chatchat, :delivery, :stage],
      &__MODULE__.pause_stage/4,
      {self(), wanted}
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "reconnected session cannot ACK an old stored receipt", %{
    sender: sender,
    receiver: receiver
  } do
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             MessagesStore.insert_pending(%{
               sender_id: sender.id,
               receiver_id: receiver.id,
               message_id: id,
               payload: "session"
             })

    old = connect(receiver.id)
    assert {:ok, old_frame} = recv(old)
    :gen_tcp.close(old)
    eventually(fn -> not ChatchatTcp.Presence.online?(receiver.id) end)
    current = connect(receiver.id)
    assert {:ok, current_frame} = recv(current)
    acknowledge(current, old_frame)
    Process.sleep(20)
    assert Repo.get_by(Message, sender_id: sender.id, message_id: id)
    acknowledge(current, current_frame)
    eventually(fn -> Repo.get_by(Message, sender_id: sender.id, message_id: id) == nil end)
  end

  test "unacknowledged pages rotate fairly and wrap to earlier rows", %{
    sender: sender,
    receiver: receiver
  } do
    ids = for _ <- 1..17, do: Ecto.UUID.generate()
    ids = Enum.sort(ids)

    for id <- ids do
      assert {:ok, _} =
               MessagesStore.insert_pending(%{
                 sender_id: sender.id,
                 receiver_id: receiver.id,
                 message_id: id,
                 payload: "fair"
               })
    end

    to = connect(receiver.id)

    frames =
      for _ <- 1..16 do
        assert {:ok, frame} = recv(to)
        frame
      end

    assert Enum.map(frames, & &1["message_id"]) == Enum.take(ids, 16)
    # Advance the same receipt-expiry/retry callbacks without a ten-second sleep.
    Enum.each(frames, &send(MessageDelivery, {:receipt_expired, &1["receipt_id"]}))

    eventually(fn ->
      Enum.all?(:sys.get_state(MessageDelivery).receipts, fn {_, receipt} ->
        receipt.receiver != receiver.id
      end)
    end)

    send(ChatchatTcp.Delivery, {:retry, receiver.id})
    assert {:ok, last} = recv(to)
    assert last["message_id"] == List.last(ids)
    send(MessageDelivery, {:receipt_expired, last["receipt_id"]})
    send(ChatchatTcp.Delivery, {:retry, receiver.id})
    assert {:ok, wrapped} = recv(to)
    assert wrapped["message_id"] == hd(ids)
    assert length(MessagesStore.pending_page(receiver.id)) == 17
  end

  test "queued frames retain permits after expiry until a slow handler consumes them", %{
    sender: sender,
    receiver: receiver
  } do
    from = connect(sender.id)
    _to = connect(receiver.id)
    [{handler, _route}] = ChatchatTcp.Presence.get_connections(receiver.id)
    :sys.suspend(handler)

    try do
      send_json(from, request(receiver.id))

      eventually(fn ->
        Enum.any?(:sys.get_state(MessageDelivery).receipts, fn {_, receipt} ->
          receipt.handler == handler and receipt.queued
        end)
      end)

      {receipt, _} =
        Enum.find(:sys.get_state(MessageDelivery).receipts, fn {_, value} ->
          value.handler == handler
        end)

      send(MessageDelivery, {:receipt_expired, receipt})
      eventually(fn -> :sys.get_state(MessageDelivery).receipts[receipt].expires == 0 end)
      assert :sys.get_state(MessageDelivery).receipts[receipt].queued
      assert MessageDelivery.metric_snapshot().receipts <= 682
    after
      :sys.resume(handler)
    end
  end

  test "presence heartbeats do not disable the idle deadline", %{receiver: receiver} do
    server = Application.fetch_env!(:chatchat_tcp, :server)
    presence = Application.fetch_env!(:chatchat_tcp, :presence_routing)
    Application.put_env(:chatchat_tcp, :server, Keyword.put(server, :read_timeout, 100))

    Application.put_env(
      :chatchat_tcp,
      :presence_routing,
      Keyword.put(presence, :heartbeat_interval, 10)
    )

    on_exit(fn ->
      Application.put_env(:chatchat_tcp, :server, server)
      Application.put_env(:chatchat_tcp, :presence_routing, presence)
    end)

    to = connect(receiver.id)
    assert {:error, :closed} = :gen_tcp.recv(to, 0, 500)
    eventually(fn -> not ChatchatTcp.Presence.online?(receiver.id) end)
  end

  defp request(receiver),
    do: %{
      type: "send_message",
      request_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      user_id: receiver,
      message: "hello"
    }

  def forward_stage(_event, measurements, metadata, owner),
    do: send(owner, {:stage, measurements, metadata})

  defp observe_stages do
    id = make_ref()
    :telemetry.attach(id, [:chatchat, :delivery, :stage], &__MODULE__.forward_stage/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp assert_stage(stage, outcome) do
    assert_receive {:stage, %{duration: duration}, %{stage: ^stage, outcome: ^outcome}}, 1_000
    assert duration >= 0
  end

  defp connect(user) do
    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", ChatchatTcp.port(), [:binary, active: false, packet: :line])

    send_json(socket, %{type: "authenticate", token: ChatchatAuth.issue(user).access_token})
    assert {:ok, %{"type" => "authenticated"}} = recv(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp acknowledge(socket, frame),
    do:
      send_json(socket, %{
        type: "message_delivered_ack",
        message_id: frame["message_id"],
        from_user_id: frame["from_user_id"],
        receipt_id: frame["receipt_id"]
      })

  defp send_json(socket, frame), do: :gen_tcp.send(socket, Jason.encode!(frame) <> "\n")

  defp recv(socket, timeout \\ 1_000) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, timeout), do: Jason.decode(line)
  end

  defp eventually(condition, attempts \\ 200)
  defp eventually(condition, 0), do: assert(condition.())

  defp eventually(condition, attempts) do
    unless condition.() do
      Process.sleep(10)
      eventually(condition, attempts - 1)
    end
  end
end
