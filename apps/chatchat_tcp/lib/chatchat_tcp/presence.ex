defmodule ChatchatTcp.Presence do
  alias ChatchatTcp.{PresenceRouting, PresenceRedis, RedisKeys, RedisScript}
  alias ChatchatTcp.Presence.Registry, as: PresenceRegistry

  @script_path Application.app_dir(:chatchat_tcp, "priv/redis/presence_session.lua")
  @external_resource @script_path
  @script File.read!(@script_path)
  @sha Base.encode16(:crypto.hash(:sha, @script), case: :lower)

  @spec register(pos_integer()) :: {:ok, pid()} | {:error, atom()}
  def register(user_id) when is_integer(user_id) and user_id > 0 do
    route = %{
      "node" => Atom.to_string(node()),
      "owner" => PresenceRouting.node_id(),
      "session" => Ecto.UUID.generate()
    }

    case Registry.register(PresenceRegistry, user_id, route) do
      {:ok, owner} -> acquire(user_id, route, owner)
      {:error, {:already_registered, _pid}} -> {:error, :already_connected}
    end
  end

  defp acquire(user_id, route, owner) do
    case session_operation(:acquire, user_id, route) do
      {:ok, 1} ->
        :ets.insert(ChatchatTcp.Presence.Users, {user_id, self()})
        {:ok, owner}

      result ->
        Registry.unregister(PresenceRegistry, user_id)
        :ets.delete_object(ChatchatTcp.Presence.Users, {user_id, self()})
        reason = if result == {:ok, 0}, do: :already_connected, else: :presence_unavailable
        {:error, reason}
    end
  end

  @doc "Renews only the calling connection's still-live lease."
  def renew(user_id) do
    with [{pid, route}] when pid == self() <- get_connections(user_id),
         {:ok, 1} <- session_operation(:renew, user_id, route) do
      :ok
    else
      _ -> {:error, :presence_unavailable}
    end
  end

  @spec unregister(integer()) :: :ok
  def unregister(user_id) when is_integer(user_id) do
    case get_connections(user_id) do
      [{pid, route}] when pid == self() ->
        _ = session_operation(:release, user_id, route)
        Registry.unregister(PresenceRegistry, user_id)
        :ets.delete_object(ChatchatTcp.Presence.Users, {user_id, self()})

      _ ->
        :ok
    end

    :ok
  end

  @doc false
  def session_operation(operation, user_id, route)
      when operation in [:acquire, :renew, :release] do
    command = [
      "EVALSHA",
      @sha,
      2,
      RedisKeys.presence_route(user_id),
      RedisKeys.presence_node(route["owner"]),
      Atom.to_string(operation),
      Jason.encode!(route),
      PresenceRouting.heartbeat_ttl()
    ]

    role = if operation == :renew, do: :renewal, else: :session

    PresenceRedis.run(role, user_id, fn connection, deadline ->
      RedisScript.command(connection, @script, @sha, command, deadline)
    end)
  end

  @doc "Resolves Redis hints only against this node and trusted connected nodes."
  def route(user_id) when is_integer(user_id) and user_id > 0 do
    PresenceRedis.run(:session, user_id, fn connection, deadline ->
      with {:ok, encoded} when is_binary(encoded) <-
             RedisScript.command_before(
               connection,
               ["GET", RedisKeys.presence_route(user_id)],
               deadline
             ),
           {:ok, %{"node" => name, "owner" => owner, "session" => session}} <-
             Jason.decode(encoded),
           true <- is_binary(owner) and is_binary(session),
           {:ok, ^session} <- Ecto.UUID.cast(session),
           {:ok, 1} <-
             RedisScript.command_before(
               connection,
               ["EXISTS", RedisKeys.presence_node(owner)],
               deadline
             ),
           {:ok, destination} <- trusted_node(name) do
        {:ok, %{node: destination, owner: owner, session: session}}
      else
        {:error, %Redix.ConnectionError{} = reason} -> {:error, reason}
        _ -> {:error, :unavailable}
      end
    end)
    |> case do
      {:ok, route} -> {:ok, route}
      _ -> {:error, :unavailable}
    end
  end

  def trusted_node(name, nodes \\ [node() | Node.list()]) do
    case Enum.find(nodes, &(Atom.to_string(&1) == name)) do
      nil -> {:error, :unavailable}
      destination -> {:ok, destination}
    end
  end

  @spec online?(integer()) :: boolean()
  def online?(user_id) when is_integer(user_id), do: get_connections(user_id) != []

  @spec get_connections(integer()) :: [{pid(), map()}]
  def get_connections(user_id) when is_integer(user_id),
    do: Registry.lookup(PresenceRegistry, user_id)

  def get_connections(_), do: []

  @spec connection_count() :: non_neg_integer()
  def connection_count, do: Registry.count(PresenceRegistry)

  def connections_page(cursor \\ nil) do
    result =
      if cursor,
        do: :ets.select(cursor),
        else:
          :ets.select(ChatchatTcp.Presence.Users, [{{:"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}], 128)

    case result do
      :"$end_of_table" ->
        {[], nil}

      {entries, next} ->
        live =
          Enum.filter(entries, fn {user, pid} ->
            if match?([{^pid, _}], get_connections(user)) do
              true
            else
              :ets.delete_object(ChatchatTcp.Presence.Users, {user, pid})
              false
            end
          end)

        {live, if(next == :"$end_of_table", do: nil, else: next)}
    end
  rescue
    ArgumentError -> {[], nil}
  end
end
