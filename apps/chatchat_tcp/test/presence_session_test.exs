defmodule ChatchatTcp.PresenceSessionTest do
  use ExUnit.Case, async: false

  alias ChatchatTcp.{Presence, PresenceRouting, RedisKeys}

  setup do
    user_id = System.unique_integer([:positive]) + 1_000_000

    on_exit(fn ->
      Redix.command(ChatchatTcp.Redis.Heartbeat, [
        "DEL",
        RedisKeys.presence_route(user_id)
      ])
    end)

    %{user_id: user_id}
  end

  test "second local connection cannot disturb the first", %{user_id: user_id} do
    assert {:ok, _} = Presence.register(user_id)
    assert {:ok, route} = Presence.route(user_id)
    parent = self()

    task =
      Task.async(fn ->
        result = Presence.register(user_id)
        Presence.unregister(user_id)
        send(parent, {:second, result})
      end)

    Task.await(task)
    assert_receive {:second, {:error, :already_connected}}
    assert {:ok, ^route} = Presence.route(user_id)
    assert :ok = Presence.renew(user_id)
    assert :ok = Presence.unregister(user_id)
    assert {:error, :unavailable} = Presence.route(user_id)
  end

  test "expired session cannot renew or remove its replacement", %{user_id: user_id} do
    old = route()
    new = route()
    assert {:ok, 1} = Presence.session_operation(:acquire, user_id, old)
    assert {:ok, 0} = Presence.session_operation(:acquire, user_id, new)

    assert {:ok, 1} =
             Redix.command(ChatchatTcp.Redis.Heartbeat, [
               "PEXPIRE",
               RedisKeys.presence_route(user_id),
               1
             ])

    Process.sleep(10)
    assert {:ok, 0} = Presence.session_operation(:renew, user_id, old)
    assert {:ok, 1} = Presence.session_operation(:acquire, user_id, new)
    assert {:ok, 0} = Presence.session_operation(:release, user_id, old)
    assert {:ok, %{session: session}} = Presence.route(user_id)
    assert session == new["session"]
  end

  test "dead heartbeat and unknown node are unavailable routes", %{user_id: user_id} do
    value = %{route() | "owner" => "absent-#{Ecto.UUID.generate()}"}

    assert {:ok, "OK"} =
             Redix.command(ChatchatTcp.Redis.Heartbeat, [
               "SET",
               RedisKeys.presence_route(user_id),
               Jason.encode!(value),
               "PX",
               30_000
             ])

    assert {:error, :unavailable} = Presence.route(user_id)
    value = %{route() | "node" => "unknown@untrusted"}

    assert {:ok, "OK"} =
             Redix.command(ChatchatTcp.Redis.Heartbeat, [
               "SET",
               RedisKeys.presence_route(user_id),
               Jason.encode!(value),
               "PX",
               30_000
             ])

    assert {:error, :unavailable} = Presence.route(user_id)
  end

  test "Redis outage refuses acquisition and renewal without retaining local registration", %{
    user_id: user_id
  } do
    assert {:ok, _} = Presence.register(user_id)

    names =
      for role <- [:session, :renewal] do
        lane = ChatchatTcp.PresenceRedis.lane(role, user_id)
        :sys.get_state(lane).connection
      end

    connections =
      for name <- names do
        connection = Process.whereis(name)
        Process.unregister(name)
        {:ok, unavailable} = Redix.start_link("redis://localhost:1/15", name: name)

        lane =
          Enum.find([:session, :renewal], fn role ->
            :sys.get_state(ChatchatTcp.PresenceRedis.lane(role, user_id)).connection == name
          end)
          |> ChatchatTcp.PresenceRedis.lane(user_id)

        :sys.replace_state(lane, &%{&1 | redis: unavailable})
        {name, lane, connection, unavailable}
      end

    try do
      assert {:error, :presence_unavailable} = Presence.renew(user_id)
      assert {:error, :unavailable} = Presence.route(user_id)
      Presence.unregister(user_id)
      assert {:error, :presence_unavailable} = Presence.register(user_id)
      assert [] = Presence.get_connections(user_id)
    after
      for {name, lane, connection, unavailable} <- connections do
        :sys.replace_state(lane, &%{&1 | redis: connection})
        GenServer.stop(unavailable)
        Process.register(connection, name)
      end

      Presence.unregister(user_id)
    end
  end

  defp route do
    %{
      "node" => Atom.to_string(node()),
      "owner" => PresenceRouting.node_id(),
      "session" => Ecto.UUID.generate()
    }
  end
end
