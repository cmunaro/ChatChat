defmodule ChatchatTcp.MessageDelivery do
  alias ChatchatBroker.Storage.MessagesStore
  alias ChatchatTcp.{Presence, RedisKeys, RedisScript}
  alias Ecto.UUID

  @redis ChatchatTcp.Redis
  @acknowledgement_script_path Application.app_dir(
                                 :chatchat_tcp,
                                 "priv/redis/acknowledge_message.lua"
                               )
  @external_resource @acknowledgement_script_path
  @acknowledgement_script File.read!(@acknowledgement_script_path)
  @acknowledgement_script_sha Base.encode16(
                                :crypto.hash(:sha, @acknowledgement_script),
                                case: :lower
                              )

  @spec load_script() :: :ok | {:error, term()}
  def load_script do
    RedisScript.load(@redis, @acknowledgement_script, @acknowledgement_script_sha)
  end

  @spec deliver_pending(pos_integer()) :: :ok
  def deliver_pending(receiver_id) do
    if Presence.online?(receiver_id) do
      deliver_from_postgres(receiver_id)
      deliver_from_redis(receiver_id)
    end

    :ok
  end

  defp deliver_from_postgres(receiver_id) do
    try do
      receiver_id
      |> MessagesStore.for_receiver()
      |> Enum.each(fn message ->
        deliver(receiver_id, message.message_id, message.sender_id, message.payload, :postgres)
      end)
    rescue
      _error -> ChatchatTcp.Telemetry.delivery_failure(:postgres, :postgres_unavailable)
    end
  end

  defp deliver_from_redis(receiver_id) do
    with {:ok, message_ids} <- Redix.command(@redis, ["SMEMBERS", RedisKeys.sending(receiver_id)]),
         commands = Enum.map(message_ids, &["GET", RedisKeys.message(&1)]),
         {:ok, messages} <- pipeline(commands) do
      messages
      |> Enum.zip(message_ids)
      |> Enum.each(fn
        {encoded, message_id} when is_binary(encoded) ->
          deliver_redis_message(receiver_id, message_id, encoded)

        _missing ->
          :ok
      end)
    else
      _error -> ChatchatTcp.Telemetry.delivery_failure(:redis, :redis_unavailable)
    end
  end

  defp deliver_redis_message(receiver_id, message_id, encoded) do
    with {:ok, %{"sender_id" => sender_id, "message" => message}} <- Jason.decode(encoded) do
      deliver(receiver_id, message_id, sender_id, message, :redis)
    else
      _error -> ChatchatTcp.Telemetry.delivery_failure(:redis, :invalid_payload)
    end
  end

  @spec deliver(integer(), String.t(), integer(), String.t(), :postgres | :redis) :: boolean()
  def deliver(user_id, message_id, from_user_id, message, source) when is_integer(user_id) do
    started_at = System.monotonic_time()
    connections = Presence.get_connections(user_id)

    Enum.each(connections, fn {pid, _value} ->
      send(pid, {:message, message_id, from_user_id, message})
    end)

    delivered? = connections != []
    ChatchatTcp.Telemetry.delivery_stop(started_at, source, delivered?)
    delivered?
  end

  defp pipeline([]), do: {:ok, []}
  defp pipeline(commands), do: Redix.pipeline(@redis, commands)

  @spec acknowledge(pos_integer(), UUID.t()) :: :ok | {:error, :unknown_message | :unavailable}
  def acknowledge(receiver_id, message_id) do
    with {:ok, _message_id} <- UUID.cast(message_id) do
      case acknowledge_redis(receiver_id, message_id) do
        {:error, :unknown_message} -> MessagesStore.delete_for_receiver(receiver_id, message_id)
        result -> result
      end
    else
      :error -> {:error, :unknown_message}
    end
  end

  defp acknowledge_redis(receiver_id, message_id) do
    command = [
      "EVALSHA",
      @acknowledgement_script_sha,
      2,
      RedisKeys.sending(receiver_id),
      RedisKeys.message(message_id),
      message_id
    ]

    case RedisScript.command(
           @redis,
           @acknowledgement_script,
           @acknowledgement_script_sha,
           command
         ) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :unknown_message}
      {:error, _reason} -> {:error, :unavailable}
    end
  end
end
