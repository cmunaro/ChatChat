defmodule ChatchatTcp.Presence do
  alias ChatchatTcp.{PresenceRouting, RedisKeys}
  alias ChatchatTcp.Presence.Registry, as: PresenceRegistry

  @redis ChatchatTcp.Redis

  @spec register(integer()) :: {:ok, pid()} | {:error, term()}
  def register(user_id) when is_integer(user_id) do
    node_id = PresenceRouting.node_id()
    heartbeat_ttl = PresenceRouting.heartbeat_ttl()

    commands = [
      ["SADD", RedisKeys.presence(user_id), node_id],
      ["SET", RedisKeys.presence_node(node_id), "1", "PX", heartbeat_ttl]
    ]

    with {:ok, owner} <- Registry.register(PresenceRegistry, user_id, nil),
         {:ok, [_added, "OK"]} <- Redix.pipeline(@redis, commands) do
      {:ok, owner}
    else
      error ->
        Registry.unregister(PresenceRegistry, user_id)
        error
    end
  end

  @spec unregister(integer()) :: :ok
  def unregister(user_id) when is_integer(user_id) do
    Registry.unregister(PresenceRegistry, user_id)

    if not online?(user_id) do
      Redix.command(@redis, ["SREM", RedisKeys.presence(user_id), PresenceRouting.node_id()])
    end

    :ok
  end

  @spec online?(integer()) :: boolean()
  def online?(user_id) when is_integer(user_id) do
    Registry.lookup(PresenceRegistry, user_id) != []
  end

  @spec get_connections(integer()) :: [{pid(), any()}]
  def get_connections(user_id) when is_integer(user_id) do
    Registry.lookup(PresenceRegistry, user_id)
  end

  def get_connections(_), do: []

  @spec connection_count() :: non_neg_integer()
  def connection_count, do: Registry.count(PresenceRegistry)
end
