defmodule ChatchatTcp.MessageAdmission do
  @moduledoc """
  C1 - RequestId + Message + C2 -> BE        prepare_message_sending/4
  C1 - ACK RequestId + MessageId -> BE       confirm_message_id_attribution/3

  One pending key per sender + request_id, one TTL, last one wins.
  """
  use GenServer
  alias Ecto.UUID

  @redis ChatchatTcp.Redis
  @sending_deadlines "chatchat:sending_deadlines"
  @message_prefix "chatchat:message:"
  @receiver_set_prefix "chatchat:sending:"
  @delivery_channel "chatchat:delivery"
  @confirmation_script File.read!(
                         Application.app_dir(
                           :chatchat_tcp,
                           "priv/redis/confirm_message_id_attribution.lua"
                         )
                       )
  @confirmation_script_sha Base.encode16(
                             :crypto.hash(:sha, @confirmation_script),
                             case: :lower
                           )

  @spec prepare_message_sending(pos_integer(), String.t(), pos_integer(), String.t()) ::
          {:ok, UUID.t()} | {:error, :unavailable}
  def prepare_message_sending(sender_id, request_id, recipient_id, message) do
    pending_key = request_key("pending", sender_id, request_id)

    message_id = UUID.generate()

    admission =
      Jason.encode!(%{
        "message_id" => message_id,
        "sender_id" => sender_id,
        "request_id" => request_id,
        "recipient_id" => recipient_id,
        "message" => message
      })

    case Redix.command(@redis, ["SET", pending_key, admission, "PX", config(:pending_ttl)]) do
      {:ok, "OK"} -> {:ok, message_id}
      _ -> {:error, :unavailable}
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec confirm_message_id_attribution(pos_integer(), String.t(), UUID.t()) ::
          {:ok, UUID.t()} | {:error, :unknown_message | :unavailable}
  def confirm_message_id_attribution(sender_id, request_id, message_id) do
    pending_key = request_key("pending", sender_id, request_id)

    execute_confirmation(@redis, pending_key, message_id)
  end

  @impl GenServer
  @spec init(nil) :: {:ok, nil} | {:stop, term()}
  def init(nil) do
    case load_confirmation_script(@redis) do
      :ok -> {:ok, nil}
      {:error, reason} -> {:stop, reason}
    end
  end

  @spec execute_confirmation(Redix.connection(), String.t(), UUID.t()) ::
          {:ok, UUID.t()} | {:error, :unknown_message | :unavailable}
  defp execute_confirmation(conn, pending_key, message_id) do
    command = [
      "EVALSHA",
      @confirmation_script_sha,
      2,
      pending_key,
      @sending_deadlines,
      message_id,
      System.system_time(:millisecond) + config(:delivery_window),
      @message_prefix,
      @receiver_set_prefix,
      @delivery_channel
    ]

    case Redix.command(conn, command) do
      {:ok, 1} ->
        {:ok, message_id}

      {:ok, 0} ->
        {:error, :unknown_message}

      {:error, %Redix.Error{message: "NOSCRIPT" <> _}} ->
        reload_and_confirm(conn, command, message_id)

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  @spec reload_and_confirm(Redix.connection(), Redix.command(), UUID.t()) ::
          {:ok, UUID.t()} | {:error, :unknown_message | :unavailable}
  defp reload_and_confirm(conn, command, message_id) do
    with :ok <- load_confirmation_script(conn) do
      case Redix.command(conn, command) do
        {:ok, 1} -> {:ok, message_id}
        {:ok, 0} -> {:error, :unknown_message}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  end

  @spec load_confirmation_script(Redix.connection()) :: :ok | {:error, term()}
  defp load_confirmation_script(conn) do
    case Redix.command(conn, ["SCRIPT", "LOAD", @confirmation_script]) do
      {:ok, @confirmation_script_sha} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec request_key(String.t(), pos_integer(), String.t()) :: String.t()
  defp request_key(table, sender_id, request_id) do
    encoded_request_id = Base.url_encode64(request_id, padding: false)
    "chatchat:{admission}:#{table}:#{sender_id}:#{encoded_request_id}"
  end

  @spec config(:pending_ttl | :delivery_window) :: pos_integer()
  defp config(key) do
    :chatchat_tcp |> Application.fetch_env!(:admission) |> Keyword.fetch!(key)
  end
end
