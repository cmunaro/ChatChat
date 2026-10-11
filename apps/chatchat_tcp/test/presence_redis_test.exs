defmodule ChatchatTcp.PresenceRedisTest do
  use ExUnit.Case, async: false
  alias ChatchatTcp.{Capacity, Presence, PresenceRedis, PresenceRouting, RedisKeys, RedisScript}
  alias ChatchatTcp.PresenceRedis.Lane

  setup do
    user = System.unique_integer([:positive]) + 2_000_000

    on_exit(fn ->
      Redix.command(PresenceRedis.heartbeat(), ["DEL", RedisKeys.presence_route(user)])
    end)

    %{user: user, lane: PresenceRedis.lane(:session, user)}
  end

  test "bounded session saturation refuses acquisition but does not block renewal or heartbeat",
       %{user: user, lane: lane} do
    route = route()
    assert {:ok, 1} = Presence.session_operation(:acquire, user, route)
    tickets = for _ <- 1..Lane.slots(), do: elem(Capacity.claim(lane), 1)

    try do
      assert {:error, :capacity} =
               PresenceRedis.run(:session, user, fn _, _ -> flunk("overload reached Redis") end)

      assert {:error, :presence_unavailable} = Presence.register(user)
      assert [] == Presence.get_connections(user)
      assert {:ok, 1} = Presence.session_operation(:renew, user, route)
      assert {:ok, "PONG"} = Redix.command(PresenceRedis.heartbeat(), ["PING"])
    after
      for ticket <- tickets, do: Capacity.release(lane, ticket)
    end

    assert {:ok, _} = Presence.route(user)
  end

  test "registration fails closed while its Redis lane is unavailable and succeeds after restoration",
       %{user: user, lane: lane} do
    :ok = Supervisor.terminate_child(PresenceRedis, lane)

    try do
      assert {:error, :presence_unavailable} = Presence.register(user)
      assert [] == Presence.get_connections(user)
    after
      {:ok, _} = Supervisor.restart_child(PresenceRedis, lane)
    end

    wait_for(fn -> match?({:ok, _}, Presence.register(user)) end)
    assert :ok = Presence.renew(user)
    assert :ok = Presence.unregister(user)
  end

  test "delayed session work expires before execution while heartbeat refresh remains independent",
       %{user: user, lane: lane} do
    :ok = :sys.suspend(lane)

    task =
      Task.async(fn ->
        PresenceRedis.run(:session, user, fn _, _ ->
          send(self(), :executed)
          {:ok, :executed}
        end)
      end)

    try do
      key = RedisKeys.presence_node(PresenceRouting.node_id())
      assert {:ok, 1} = Redix.command(PresenceRedis.heartbeat(), ["PEXPIRE", key, 5_000])
      send(PresenceRouting, :heartbeat)
      :sys.get_state(PresenceRouting)
      assert {:ok, ttl} = Redix.command(PresenceRedis.heartbeat(), ["PTTL", key])
      assert ttl > PresenceRouting.heartbeat_ttl() - 1_000
      Process.sleep(Lane.timeout() + 20)
    after
      :sys.resume(lane)
    end

    assert {:error, :expired} = Task.await(task)
    assert :ets.info(lane, :size) == 1
  end

  test "admitted work pipelines concurrently and releases slots after caller death", %{
    user: user,
    lane: lane
  } do
    parent = self()

    waiting =
      Task.async(fn ->
        PresenceRedis.run(:session, user, fn _, _ ->
          send(parent, {:operation_started, self()})

          receive do
            :finish -> {:ok, :finished}
          end
        end)
      end)

    assert_receive {:operation_started, operation}

    assert {:ok, "PONG"} =
             PresenceRedis.run(:session, user, fn connection, deadline ->
               RedisScript.command_before(connection, ["PING"], deadline)
             end)

    Process.unlink(waiting.pid)
    Process.exit(waiting.pid, :kill)
    wait_for(fn -> not Process.alive?(operation) and :ets.info(lane, :size) == 1 end)
    assert Enum.all?(PresenceRedis.snapshot(), &(&1.reserved == 0))
  end

  test "script cache miss reload shares one deadline and expired commands do not execute", %{
    user: user
  } do
    key = RedisKeys.presence_route(user)
    script = "-- #{Ecto.UUID.generate()}\nreturn redis.call('SET', KEYS[1], ARGV[1])"
    sha = Base.encode16(:crypto.hash(:sha, script), case: :lower)

    assert {:ok, "OK"} =
             PresenceRedis.run(:session, user, fn connection, deadline ->
               RedisScript.command(
                 connection,
                 script,
                 sha,
                 ["EVALSHA", sha, 1, key, "loaded"],
                 deadline
               )
             end)

    assert {:error, %Redix.ConnectionError{reason: :timeout}} =
             RedisScript.command_before(
               PresenceRedis.heartbeat(),
               ["SET", key, "expired"],
               System.monotonic_time(:millisecond) - 1
             )

    assert {:ok, "loaded"} = Redix.command(PresenceRedis.heartbeat(), ["GET", key])
  end

  test "connection death restarts only its lane and preserves ownership", %{
    user: user,
    lane: lane
  } do
    assert {:ok, _} = Presence.register(user)
    assert {:ok, route} = Presence.route(user)
    old = Process.whereis(lane)
    redis = :sys.get_state(lane).redis
    monitor = Process.monitor(old)
    heartbeat = Process.whereis(PresenceRedis.heartbeat())
    Process.exit(redis, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old, _}
    wait_for(fn -> is_pid(Process.whereis(lane)) and Process.whereis(lane) != old end)
    assert Process.whereis(PresenceRedis.heartbeat()) == heartbeat
    wait_for(fn -> Presence.route(user) == {:ok, route} end)
    assert :ok = Presence.renew(user)
    assert :ok = Presence.unregister(user)
    assert {:ok, _} = Presence.register(user)
    assert :ok = Presence.renew(user)
    assert :ok = Presence.unregister(user)
  end

  test "a burst of lane failures preserves the supervisor, heartbeat and session owner", %{
    user: user
  } do
    assert {:ok, _} = Presence.register(user)
    assert {:ok, route} = Presence.route(user)
    supervisor = Process.whereis(PresenceRedis)
    heartbeat = Process.whereis(PresenceRedis.heartbeat())
    owner = PresenceRouting.node_id()

    lanes =
      Enum.map(PresenceRedis.snapshot(), fn item ->
        name = String.to_existing_atom(item.role)
        {name, Process.whereis(name), :sys.get_state(name).redis}
      end)

    Enum.each(lanes, fn {_, _, redis} -> Process.exit(redis, :kill) end)

    wait_for(fn ->
      Enum.all?(lanes, fn {name, old, _} ->
        is_pid(Process.whereis(name)) and Process.whereis(name) != old
      end)
    end)

    assert Process.whereis(PresenceRedis) == supervisor
    assert Process.whereis(PresenceRedis.heartbeat()) == heartbeat
    assert PresenceRouting.node_id() == owner
    wait_for(fn -> Presence.route(user) == {:ok, route} end)
    assert :ok = Presence.renew(user)
    assert :ok = Presence.unregister(user)
  end

  test "Redis socket disconnect reconnects without replacing a live session owner", %{
    user: user,
    lane: lane
  } do
    assert {:ok, _} = Presence.register(user)
    redis = :sys.get_state(lane).redis
    assert {:ok, old_id} = Redix.command(redis, ["CLIENT", "ID"])
    assert {:ok, 1} = Redix.command(PresenceRedis.heartbeat(), ["CLIENT", "KILL", "ID", old_id])

    wait_for(fn ->
      case Redix.command(redis, ["CLIENT", "ID"]) do
        {:ok, id} -> id != old_id
        _ -> false
      end
    end)

    assert :sys.get_state(lane).redis == redis
    assert :ok = Presence.renew(user)
    assert :ok = Presence.unregister(user)
  end

  test "timed out Redis work discards the socket and recovers without accumulating commands", %{
    user: user,
    lane: lane
  } do
    old = Process.whereis(lane)
    state = :sys.get_state(lane)
    :sys.suspend(state.redis)
    monitor = Process.monitor(old)

    assert {:error, %Redix.ConnectionError{reason: :timeout}} =
             PresenceRedis.run(:session, user, fn connection, deadline ->
               RedisScript.command_before(connection, ["PING"], deadline)
             end)

    assert_receive {:DOWN, ^monitor, :process, ^old, _}
    refute Process.alive?(state.redis)
    wait_for(fn -> is_pid(Process.whereis(lane)) and Process.whereis(lane) != old end)

    wait_for(fn ->
      PresenceRedis.run(:session, user, fn conn, deadline ->
        RedisScript.command_before(conn, ["PING"], deadline)
      end) == {:ok, "PONG"}
    end)
  end

  test "renewal jitter and diagnostics have fixed bounded roles" do
    deadline = System.monotonic_time(:millisecond) + PresenceRouting.heartbeat_ttl()
    delays = for _ <- 1..200, do: PresenceRouting.renewal_delay(deadline)
    assert Enum.min(delays) >= 8_000
    assert Enum.max(delays) <= 12_000
    assert length(Enum.uniq(delays)) > 1
    assert PresenceRouting.renewal_delay(System.monotonic_time(:millisecond) + 1_000) == 0
    assert length(PresenceRedis.snapshot()) == 8

    assert Enum.all?(
             PresenceRedis.snapshot(),
             &(&1.available and &1.reserved == 0 and &1.limit == 512)
           )

    assert length(PresenceRedis.connections()) == 9
    assert Enum.all?(PresenceRedis.connections(), &is_pid(Process.whereis(&1)))

    assert Enum.frequencies(Enum.map(PresenceRedis.connections(), &PresenceRedis.role/1)) == %{
             heartbeat: 1,
             session: 4,
             renewal: 4
           }
  end

  defp route do
    %{
      "node" => Atom.to_string(node()),
      "owner" => PresenceRouting.node_id(),
      "session" => Ecto.UUID.generate()
    }
  end

  defp wait_for(predicate, attempts \\ 100)

  defp wait_for(predicate, attempts) when attempts > 0 do
    if predicate.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_for(predicate, attempts - 1)
        )
  end

  defp wait_for(_, 0), do: flunk("lane did not recover")
end
