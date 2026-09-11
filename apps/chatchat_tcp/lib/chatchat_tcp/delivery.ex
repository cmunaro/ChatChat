defmodule ChatchatTcp.Delivery do
  use GenServer

  alias ChatchatTcp.Presence
  alias Ecto.UUID

  @redis ChatchatTcp.Redis
  @channel "chatchat:delivery"
  @message_prefix "chatchat:message:"
  @receiver_set_prefix "chatchat:sending:"
  @sending_deadlines "chatchat:sending_deadlines"
  @acknowledgement_script File.read!(
                            Application.app_dir(
                              :chatchat_tcp,
                              "priv/redis/acknowledge_message.lua"
                            )
                          )
  @acknowledgement_script_sha Base.encode16(
                                :crypto.hash(:sha, @acknowledgement_script),
                                case: :lower
                              )

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec wake(pos_integer()) :: :ok
  def wake(receiver_id), do: GenServer.cast(__MODULE__, {:wake, receiver_id})

  @spec acknowledge(pos_integer(), UUID.t()) :: :ok | {:error, :unknown_message | :unavailable}
  def acknowledge(receiver_id, message_id) do
    with {:ok, _message_id} <- UUID.cast(message_id) do
      acknowledge(@redis, receiver_id, message_id)
    else
      :error -> {:error, :unknown_message}
    end
  end

  @impl GenServer
  def init(nil) do
    with :ok <- load_acknowledgement_script(),
         {:ok, pubsub} <-
           Redix.PubSub.start_link(Application.fetch_env!(:chatchat_tcp, :redis_url)),
         {:ok, subscription} <- Redix.PubSub.subscribe(pubsub, @channel, self()) do
      {:ok,
       %{pubsub: pubsub, subscription: subscription, active: MapSet.new(), pending: MapSet.new()}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_cast({:wake, receiver_id}, state) do
    {:noreply, schedule(receiver_id, state)}
  end

  @impl GenServer
  def handle_info(
        {:redix_pubsub, pubsub, subscription, :message, %{channel: @channel, payload: payload}},
        %{pubsub: pubsub, subscription: subscription} = state
      ) do
    case Integer.parse(payload) do
      {receiver_id, ""} -> {:noreply, schedule(receiver_id, state)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:delivery_complete, receiver_id}, state) do
    state = %{state | active: MapSet.delete(state.active, receiver_id)}

    if MapSet.member?(state.pending, receiver_id) do
      schedule(receiver_id, %{state | pending: MapSet.delete(state.pending, receiver_id)})
      |> then(&{:noreply, &1})
    else
      {:noreply, state}
    end
  end

  def handle_info({:redix_pubsub, _, _, _, _}, state), do: {:noreply, state}

  defp schedule(receiver_id, state) do
    if MapSet.member?(state.active, receiver_id) do
      %{state | pending: MapSet.put(state.pending, receiver_id)}
    else
      owner = self()

      case Task.Supervisor.start_child(ChatchatTcp.Delivery.TaskSupervisor, fn ->
             try do
               deliver_pending(receiver_id)
             after
               send(owner, {:delivery_complete, receiver_id})
             end
           end) do
        {:ok, _pid} -> %{state | active: MapSet.put(state.active, receiver_id)}
        {:error, _reason} -> state
      end
    end
  end

  defp deliver_pending(receiver_id) do
    if Presence.online?(receiver_id) do
      case Redix.command(@redis, ["SMEMBERS", receiver_set(receiver_id)]) do
        {:ok, []} ->
          :ok

        {:ok, message_ids} ->
          with {:ok, messages} <-
                 Redix.pipeline(@redis, Enum.map(message_ids, &["GET", message_key(&1)])) do
            messages
            |> Enum.zip(message_ids)
            |> Enum.each(fn
              {encoded, message_id} when is_binary(encoded) ->
                deliver(receiver_id, message_id, encoded)

              _ ->
                :ok
            end)
          end

        {:error, _reason} ->
          :ok
      end
    end
  end

  defp deliver(receiver_id, message_id, encoded) do
    with {:ok, %{"sender_id" => sender_id, "message" => message}} <- Jason.decode(encoded) do
      Presence.deliver(receiver_id, message_id, sender_id, message)
    end
  end

  defp acknowledge(conn, receiver_id, message_id) do
    command = acknowledgement_command(receiver_id, message_id)

    case Redix.command(conn, command) do
      {:ok, 1} -> :ok
      {:ok, 0} -> {:error, :unknown_message}
      {:error, %Redix.Error{message: "NOSCRIPT" <> _}} -> reload_and_acknowledge(conn, command)
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp acknowledgement_command(receiver_id, message_id) do
    [
      "EVALSHA",
      @acknowledgement_script_sha,
      3,
      receiver_set(receiver_id),
      message_key(message_id),
      @sending_deadlines,
      message_id
    ]
  end

  defp reload_and_acknowledge(conn, command) do
    with :ok <- load_acknowledgement_script(conn) do
      case Redix.command(conn, command) do
        {:ok, 1} -> :ok
        {:ok, 0} -> {:error, :unknown_message}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  end

  defp load_acknowledgement_script(conn \\ @redis) do
    case Redix.command(conn, ["SCRIPT", "LOAD", @acknowledgement_script]) do
      {:ok, @acknowledgement_script_sha} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp receiver_set(receiver_id), do: "#{@receiver_set_prefix}#{receiver_id}"
  defp message_key(message_id), do: "#{@message_prefix}#{message_id}"
end
