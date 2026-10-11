defmodule ChatchatTcp.ConnectionMaintenanceTest do
  use ExUnit.Case, async: false

  alias ChatchatTcp.{Capacity, MessageDelivery, Presence, PresenceRedis, RedisKeys}
  alias ChatchatTcp.PresenceRedis.Lane

  setup do
    user = System.unique_integer([:positive]) + 5_000_000
    socket = connect(user)
    [{handler, route}] = Presence.get_connections(user)
    lane = PresenceRedis.lane(:renewal, user)

    on_exit(fn ->
      :gen_tcp.close(socket)
      Redix.command(PresenceRedis.heartbeat(), ["DEL", RedisKeys.presence_route(user)])
    end)

    %{user: user, socket: socket, handler: handler, route: route, lane: lane}
  end

  test "renewal overload keeps a live socket responsive and refuses sends until recovery",
       context do
    tickets = for _ <- 1..Lane.slots(), do: elem(Capacity.claim(context.lane), 1)
    initial_deadline = state(context.handler).presence_deadline
    id = Ecto.UUID.generate()

    try do
      send(context.handler, :renew_presence)
      send_json(context.socket, %{type: "ping"})
      assert {:ok, %{"type" => "pong"}} = recv(context.socket)
      degraded = state(context.handler)
      assert degraded.presence_deadline == initial_deadline
      assert degraded.presence_failures == 1

      send_json(context.socket, request(context.user + 1, id))

      assert {:ok, %{"status" => "failed", "reason" => "unavailable", "message_id" => ^id}} =
               recv(context.socket)

      assert MessageDelivery.metric_snapshot().attempts == 0
    after
      for ticket <- tickets, do: Capacity.release(context.lane, ticket)
    end

    eventually(fn -> state(context.handler).presence_failures == 0 end)
    assert state(context.handler).presence_deadline > initial_deadline
    assert [{handler, route}] = Presence.get_connections(context.user)
    assert handler == context.handler and route == context.route

    receiver = connect(context.user + 1)
    on_exit(fn -> :gen_tcp.close(receiver) end)
    send_json(context.socket, request(context.user + 1, id))
    assert {:ok, frame} = recv(receiver)
    assert frame["message_id"] == id

    send_json(receiver, %{
      type: "message_delivered_ack",
      from_user_id: context.user,
      message_id: id,
      receipt_id: frame["receipt_id"]
    })

    assert {:ok, %{"status" => "ok", "message_id" => ^id}} = recv(context.socket)
  end

  test "unavailable renewal lane retries without extending the lease", context do
    :ok = Supervisor.terminate_child(PresenceRedis, context.lane)
    initial_deadline = state(context.handler).presence_deadline

    try do
      send(context.handler, :renew_presence)
      send_json(context.socket, %{type: "ping"})
      assert {:ok, %{"type" => "pong"}} = recv(context.socket)
      assert state(context.handler).presence_deadline == initial_deadline
    after
      {:ok, _} = Supervisor.restart_child(PresenceRedis, context.lane)
    end

    eventually(fn -> state(context.handler).presence_failures == 0 end)
    assert Process.alive?(context.handler)
  end

  test "renewal overload cannot keep an expired local lease connected", context do
    tickets = for _ <- 1..Lane.slots(), do: elem(Capacity.claim(context.lane), 1)

    try do
      :sys.replace_state(context.handler, fn {socket, state} ->
        {socket, %{state | presence_deadline: System.monotonic_time(:millisecond) + 150}}
      end)

      send(context.handler, :renew_presence)
      assert {:error, :closed} = :gen_tcp.recv(context.socket, 0, 2_000)
      eventually(fn -> not Presence.online?(context.user) end)
    after
      for ticket <- tickets, do: Capacity.release(context.lane, ticket)
    end
  end

  test "replacement ownership closes the old socket immediately and is not deleted", context do
    replacement = %{context.route | "session" => Ecto.UUID.generate()}

    assert {:ok, "OK"} =
             Redix.command(PresenceRedis.heartbeat(), [
               "SET",
               RedisKeys.presence_route(context.user),
               Jason.encode!(replacement),
               "PX",
               30_000
             ])

    send(context.handler, :renew_presence)
    assert {:error, :closed} = :gen_tcp.recv(context.socket, 0, 1_000)

    assert {:ok, encoded} =
             Redix.command(PresenceRedis.heartbeat(), [
               "GET",
               RedisKeys.presence_route(context.user)
             ])

    assert Jason.decode!(encoded) == replacement
  end

  defp state(handler), do: elem(:sys.get_state(handler), 1)

  defp connect(user) do
    {:ok, socket} =
      :gen_tcp.connect(~c"localhost", ChatchatTcp.port(), [:binary, active: false, packet: :line])

    %{access_token: token} = ChatchatAuth.issue(user)
    send_json(socket, %{type: "authenticate", token: token})
    assert {:ok, %{"type" => "authenticated", "user_id" => ^user}} = recv(socket)
    socket
  end

  defp request(receiver, id) do
    %{
      type: "send_message",
      request_id: Ecto.UUID.generate(),
      message_id: id,
      user_id: receiver,
      message: "retry after renewal"
    }
  end

  defp send_json(socket, frame), do: :gen_tcp.send(socket, Jason.encode!(frame) <> "\n")

  defp recv(socket) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0, 2_000), do: Jason.decode(line)
  end

  defp eventually(predicate, attempts \\ 300)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    unless predicate.() do
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end
end
