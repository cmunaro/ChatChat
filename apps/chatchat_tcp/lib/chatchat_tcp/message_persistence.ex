defmodule ChatchatTcp.MessagePersistence do
  require Logger

  alias ChatchatBroker.Storage.MessagesStore
  alias ChatchatTcp.{RedisKeys, RedisScript}

  @redis ChatchatTcp.Redis
  @script_path Application.app_dir(:chatchat_tcp, "priv/redis/claim_message_persistence.lua")
  @external_resource @script_path
  @script File.read!(@script_path)
  @script_sha Base.encode16(:crypto.hash(:sha, @script), case: :lower)

  @spec load_script() :: :ok | {:error, term()}
  def load_script, do: RedisScript.load(@redis, @script, @script_sha)

  @spec persist_batch() :: non_neg_integer()
  def persist_batch do
    persist_interrupted() + persist_expired()
  end

  @spec next_run_in(non_neg_integer()) :: non_neg_integer()
  def next_run_in(processed) when processed > 0, do: 0

  def next_run_in(0) do
    case Redix.command(@redis, ["ZRANGE", RedisKeys.sending_deadlines(), 0, 0, "WITHSCORES"]) do
      {:ok, [_message_id, score]} ->
        {deadline, _remainder} = Float.parse(score)
        max(trunc(deadline) - System.system_time(:millisecond), 1)

      _ ->
        config(:persistence_retry_interval)
    end
  end

  defp persist_interrupted do
    command = ["SSCAN", RedisKeys.persisting_set(), "0", "COUNT", config(:persistence_batch_size)]

    case Redix.command(@redis, command) do
      {:ok, message_ids} when is_list(message_ids) -> persist(message_ids)
      _ -> 0
    end
  end

  defp persist_expired do
    now = System.system_time(:millisecond)

    command = [
      "ZRANGEBYSCORE",
      RedisKeys.sending_deadlines(),
      "-inf",
      now,
      "LIMIT",
      0,
      config(:persistence_batch_size)
    ]

    with {:ok, message_ids} <- Redix.command(@redis, command) do
      message_ids
      |> claim(now)
      |> store()
    else
      _error -> 0
    end
  end

  defp claim([], _now), do: []

  defp claim(message_ids, now) do
    commands =
      Enum.map(message_ids, fn message_id ->
        [
          "EVALSHA",
          @script_sha,
          2,
          RedisKeys.sending_deadlines(),
          RedisKeys.persisting_set(),
          message_id,
          now
        ]
      end)

    case RedisScript.pipeline(@redis, @script, @script_sha, commands) do
      {:ok, results} -> decode_claims(results, message_ids)
      {:error, _reason} -> []
    end
  end

  defp persist([]), do: 0

  defp persist(message_ids) do
    commands = Enum.map(message_ids, &["GET", RedisKeys.persisting(&1)])

    case Redix.pipeline(@redis, commands) do
      {:ok, messages} -> messages |> decode_claims(message_ids) |> store()
      {:error, _reason} -> 0
    end
  end

  defp decode_claims(messages, message_ids) do
    messages
    |> Enum.zip(message_ids)
    |> Enum.flat_map(fn
      {encoded, message_id} when is_binary(encoded) -> [{message_id, encoded}]
      _missing -> []
    end)
  end

  defp store([]), do: 0

  defp store(claims) do
    try do
      rows = Enum.map(claims, fn {_message_id, encoded} -> decode_row(encoded) end)
      :ok = MessagesStore.insert_all(rows)
      cleanup(Enum.map(claims, &elem(&1, 0)))
    rescue
      error ->
        Logger.error("Could not persist messages: #{Exception.message(error)}")
        0
    end
  end

  defp decode_row(encoded) do
    %{
      "message_id" => message_id,
      "sender_id" => sender_id,
      "recipient_id" => receiver_id,
      "message" => payload
    } = Jason.decode!(encoded)

    %{
      message_id: message_id,
      sender_id: sender_id,
      receiver_id: receiver_id,
      payload: payload,
      inserted_at: DateTime.utc_now()
    }
  end

  defp cleanup(message_ids) do
    commands =
      Enum.flat_map(message_ids, fn message_id ->
        [
          ["DEL", RedisKeys.persisting(message_id)],
          ["DEL", RedisKeys.message(message_id)],
          ["SREM", RedisKeys.persisting_set(), message_id],
          ["ZREM", RedisKeys.sending_deadlines(), message_id]
        ]
      end)

    case Redix.pipeline(@redis, commands) do
      {:ok, _results} -> length(message_ids)
      {:error, _reason} -> 0
    end
  end

  defp config(key) do
    :chatchat_tcp |> Application.fetch_env!(:admission) |> Keyword.fetch!(key)
  end
end
