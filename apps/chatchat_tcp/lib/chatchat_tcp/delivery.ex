defmodule ChatchatTcp.Delivery do
  use GenServer

  @moduledoc """
  Coordinates message delivery for this node

  It starts a delivery task when:
  - A client connects and needs queued messages from PostgreSQL and Redis
  - Redis publishes a notification that new messages are available

  The state contains:
  - `active`: Set of receiver IDs that currently have a delivery task running
  - `pending`: Set of receiver IDs that need another delivery pass after their active task finishes

  When a receiver needs to be handled and is not active, a task is started and
  the receiver ID is added to `active`

  If a task is already active for that receiver, the receiver ID is added to
  `pending` if not already present
  """

  alias ChatchatTcp.MessageDelivery
  alias Ecto.UUID

  @channel "chatchat:delivery"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec wake(pos_integer()) :: :ok
  def wake(receiver_id), do: GenServer.cast(__MODULE__, {:wake, receiver_id})

  @spec acknowledge(pos_integer(), UUID.t()) :: :ok | {:error, :unknown_message | :unavailable}
  defdelegate acknowledge(receiver_id, message_id), to: MessageDelivery

  @spec metric_snapshot() :: %{
          active_workers: non_neg_integer(),
          pending_receivers: non_neg_integer()
        }
  def metric_snapshot, do: GenServer.call(__MODULE__, :metric_snapshot)

  @impl GenServer
  def init(nil) do
    with :ok <- MessageDelivery.load_script(),
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
  def handle_call(:metric_snapshot, _from, state) do
    snapshot = %{
      active_workers: MapSet.size(state.active),
      pending_receivers: MapSet.size(state.pending)
    }

    {:reply, snapshot, state}
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
               MessageDelivery.deliver_pending(receiver_id)
             after
               send(owner, {:delivery_complete, receiver_id})
             end
           end) do
        {:ok, _pid} ->
          %{state | active: MapSet.put(state.active, receiver_id)}

        {:error, _reason} ->
          ChatchatTcp.Telemetry.delivery_failure(:unknown, :task_start_failed)
          state
      end
    end
  end
end
