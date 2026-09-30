defmodule ChatchatTcp.MessageAdmission do
  @moduledoc """
  C1 - RequestId + Message + C2 -> BE        prepare_message_sending/4
  C1 - ACK RequestId + MessageId -> BE       confirm_message_id_attribution/3

  One pending key per sender + request_id, one TTL, last one wins.
  """
  use GenServer

  alias ChatchatTcp.{RedisKeys, RedisScript}
  alias Ecto.UUID

  @redis ChatchatTcp.Redis
  @admit_path Application.app_dir(:chatchat_tcp, "priv/redis/admit_message.lua")
  @external_resource @admit_path
  @admit_script File.read!(@admit_path)
  @admit_sha Base.encode16(:crypto.hash(:sha, @admit_script), case: :lower)
  @confirmation_script_path Application.app_dir(
                              :chatchat_tcp,
                              "priv/redis/confirm_message_id_attribution.lua"
                            )
  @external_resource @confirmation_script_path
  @confirmation_script File.read!(@confirmation_script_path)
  @confirmation_script_sha Base.encode16(
                             :crypto.hash(:sha, @confirmation_script),
                             case: :lower
                           )

  @impl GenServer
  @spec init(nil) :: {:ok, nil} | {:stop, term()}
  def init(nil) do
    case RedisScript.load(@redis, @confirmation_script, @confirmation_script_sha) do
      :ok -> {:ok, nil}
      {:error, reason} -> {:stop, reason}
    end
  end

  @spec prepare_message_sending(pos_integer(), String.t(), pos_integer(), String.t()) ::
          {:ok, UUID.t()} | {:error, :unavailable | :overloaded}
  def prepare_message_sending(sender_id, request_id, recipient_id, message) do
    message_id = UUID.generate()

    admission =
      Jason.encode!(%{
        "message_id" => message_id,
        "sender_id" => sender_id,
        "request_id" => request_id,
        "recipient_id" => recipient_id,
        "message" => message
      })

    event =
      Jason.encode!(%{
        "message_id" => message_id,
        "sender_id" => sender_id,
        "recipient_id" => recipient_id
      })

    command = [
      "EVALSHA",
      @admit_sha,
      1,
      RedisKeys.pending(sender_id, request_id),
      System.system_time(:millisecond),
      config(:pending_ttl),
      config(:max_outstanding),
      admission,
      event
    ]

    case RedisScript.command(@redis, @admit_script, @admit_sha, command) do
      {:ok, 1} ->
        :telemetry.execute([:chatchat, :message, :admitted], %{count: 1}, %{})
        {:ok, message_id}

      {:ok, 0} ->
        {:error, :overloaded}

      _ ->
        {:error, :unavailable}
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec confirm_message_id_attribution(pos_integer(), String.t(), UUID.t()) ::
          {:ok, UUID.t()} | {:error, :unknown_message | :unavailable}
  def confirm_message_id_attribution(sender_id, request_id, message_id) do
    execute_confirmation(@redis, RedisKeys.pending(sender_id, request_id), message_id)
  end

  @spec execute_confirmation(Redix.connection(), String.t(), UUID.t()) ::
          {:ok, UUID.t()} | {:error, :unknown_message | :unavailable}
  defp execute_confirmation(conn, pending_key, message_id) do
    command = [
      "EVALSHA",
      @confirmation_script_sha,
      1,
      pending_key,
      message_id,
      System.system_time(:millisecond) + config(:delivery_window)
    ]

    case RedisScript.command(conn, @confirmation_script, @confirmation_script_sha, command) do
      {:ok, [1, published, stale]} ->
        ChatchatTcp.Telemetry.delivery_routing(published, stale)
        {:ok, message_id}

      {:ok, 0} ->
        {:error, :unknown_message}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  @spec config(:pending_ttl | :delivery_window | :max_outstanding) :: pos_integer()
  defp config(key) do
    :chatchat_tcp |> Application.fetch_env!(:admission) |> Keyword.fetch!(key)
  end
end
