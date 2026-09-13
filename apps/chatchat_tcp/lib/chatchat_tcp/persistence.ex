defmodule ChatchatTcp.Persistence do
  use GenServer

  alias ChatchatBroker.Storage.MessagesStore

  @redis ChatchatTcp.Redis
  @sending_deadlines "chatchat:sending_deadlines"
  @persisting "chatchat:persisting"
  @script_path Application.app_dir(:chatchat_tcp, "priv/redis/claim_message_persistence.lua")
  @external_resource @script_path
  @script File.read!(@script_path)
  @script_sha Base.encode16(:crypto.hash(:sha, @script), case: :lower)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl GenServer
  def init(nil) do
    case load_script() do
      :ok ->
        send(self(), :persist)
        {:ok, nil}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_info(:persist, state) do
    persisted = persist_claimed() + claim_and_persist_expired()
    Process.send_after(self(), :persist, next_delay(persisted))
    {:noreply, state}
  end

  defp persist_claimed do
    case Redix.command(@redis, ["SRANDMEMBER", @persisting, config(:persistence_batch_size)]) do
      {:ok, message_ids} when is_list(message_ids) -> persist(message_ids)
      _ -> 0
    end
  end

  defp claim_and_persist_expired do
    now = System.system_time(:millisecond)

    with {:ok, message_ids} <-
           Redix.command(@redis, [
             "ZRANGEBYSCORE",
             @sending_deadlines,
             "-inf",
             now,
             "LIMIT",
             0,
             config(:persistence_batch_size)
           ]) do
      message_ids
      |> claim(now)
      |> persist_claims()
    else
      _ -> 0
    end
  end

  defp claim([], _now), do: []
  defp claim(message_ids, now), do: claim(message_ids, now, true)

  defp claim(message_ids, now, reload?) do
    commands =
      Enum.map(message_ids, fn message_id ->
        [
          "EVALSHA",
          @script_sha,
          2,
          @sending_deadlines,
          @persisting,
          message_id,
          now
        ]
      end)

    case Redix.pipeline(@redis, commands) do
      {:ok, results} ->
        if reload? and Enum.any?(results, &match?(%Redix.Error{message: "NOSCRIPT" <> _}, &1)) do
          with :ok <- load_script() do
            claim(message_ids, now, false)
          else
            _ -> []
          end
        else
          results
          |> Enum.zip(message_ids)
          |> Enum.flat_map(fn
            {encoded, message_id} when is_binary(encoded) -> [{message_id, encoded}]
            _ -> []
          end)
        end

      {:error, _reason} ->
        []
    end
  end

  defp persist_claims([]), do: 0

  defp persist_claims(claims) do
    rows = Enum.map(claims, fn {_message_id, encoded} -> row(encoded) end)
    :ok = MessagesStore.insert_all(rows)
    cleanup(Enum.map(claims, &elem(&1, 0)))
  end

  defp persist([]), do: 0

  defp persist(message_ids) do
    case Redix.pipeline(@redis, Enum.map(message_ids, &["GET", persisting_key(&1)])) do
      {:ok, encoded_messages} ->
        claims =
          encoded_messages
          |> Enum.zip(message_ids)
          |> Enum.flat_map(fn
            {encoded, message_id} when is_binary(encoded) -> [{message_id, encoded}]
            _ -> []
          end)

        persist_claims(claims)

      {:error, _reason} ->
        0
    end
  end

  defp row(encoded) do
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
          ["DEL", persisting_key(message_id)],
          ["DEL", "chatchat:message:#{message_id}"],
          ["SREM", @persisting, message_id],
          ["ZREM", @sending_deadlines, message_id]
        ]
      end)

    case Redix.pipeline(@redis, commands) do
      {:ok, _results} -> length(message_ids)
      {:error, _reason} -> 0
    end
  end

  defp next_delay(processed) when processed > 0, do: 0

  defp next_delay(0) do
    case Redix.command(@redis, ["ZRANGE", @sending_deadlines, 0, 0, "WITHSCORES"]) do
      {:ok, [_message_id, score]} ->
        {deadline, _remainder} = Float.parse(score)
        max(trunc(deadline) - System.system_time(:millisecond), 1)

      _ ->
        config(:persistence_retry_interval)
    end
  end

  defp load_script do
    case Redix.command(@redis, ["SCRIPT", "LOAD", @script]) do
      {:ok, @script_sha} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persisting_key(message_id), do: "chatchat:persisting:#{message_id}"

  defp config(key) do
    :chatchat_tcp |> Application.fetch_env!(:admission) |> Keyword.fetch!(key)
  end
end
