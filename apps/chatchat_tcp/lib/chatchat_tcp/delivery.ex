defmodule ChatchatTcp.Delivery do
  use GenServer

  @moduledoc """
  Coordinates message delivery for this node

  It starts a delivery task when:
  - A client connects and needs queued messages from PostgreSQL and Redis
  - Redis publishes a notification that new messages are available

  The state contains:
  - `active`: Set of receiver IDs that currently have a delivery task running
  - `pending`: Receiver IDs waiting for a delivery pass and the strongest requested kind
  - `max_concurrency`: Maximum number of delivery tasks that may run at once

  When a receiver needs to be handled and capacity is available, a task is started
  and the receiver ID is added to `active`.

  If all worker slots are occupied, or a task is already active for that receiver,
  the receiver ID is coalesced into `pending`. Completing a task drains pending
  receivers up to the configured concurrency limit.
  """

  alias ChatchatTcp.MessageDelivery
  alias Ecto.UUID

  @channel "chatchat:delivery"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @type delivery_kind :: :realtime | :recovery

  @spec wake(pos_integer(), delivery_kind()) :: :ok
  def wake(receiver_id, kind), do: GenServer.cast(__MODULE__, {:wake, receiver_id, kind})

  @spec acknowledge(pos_integer(), UUID.t()) :: :ok | {:error, :unknown_message | :unavailable}
  defdelegate acknowledge(receiver_id, message_id), to: MessageDelivery

  @spec metric_snapshot() :: %{
          active_workers: non_neg_integer(),
          pending_receivers: non_neg_integer()
        }
  def metric_snapshot, do: GenServer.call(__MODULE__, :metric_snapshot)

  @impl GenServer
  def init(nil) do
    max_concurrency =
      :chatchat_tcp
      |> Application.fetch_env!(:delivery)
      |> Keyword.fetch!(:max_concurrency)

    with :ok <- MessageDelivery.load_script(),
         {:ok, pubsub} <-
           Redix.PubSub.start_link(Application.fetch_env!(:chatchat_tcp, :redis_url)),
         {:ok, subscription} <- Redix.PubSub.subscribe(pubsub, @channel, self()) do
      {:ok,
       %{
         pubsub: pubsub,
         subscription: subscription,
         active: MapSet.new(),
         pending: %{},
         max_concurrency: max_concurrency
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_cast({:wake, receiver_id, kind}, state) do
    {:noreply, schedule(receiver_id, kind, state)}
  end

  @impl GenServer
  def handle_call(:metric_snapshot, _from, state) do
    snapshot = %{
      active_workers: MapSet.size(state.active),
      pending_receivers: map_size(state.pending)
    }

    {:reply, snapshot, state}
  end

  @impl GenServer
  def handle_info(
        {:redix_pubsub, pubsub, subscription, :message, %{channel: @channel, payload: payload}},
        %{pubsub: pubsub, subscription: subscription} = state
      ) do
    case Integer.parse(payload) do
      {receiver_id, ""} -> {:noreply, schedule(receiver_id, :realtime, state)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:delivery_complete, receiver_id}, state) do
    state = %{state | active: MapSet.delete(state.active, receiver_id)}
    {:noreply, drain_pending(state)}
  end

  def handle_info({:redix_pubsub, _, _, _, _}, state), do: {:noreply, state}

  defp schedule(receiver_id, kind, state) do
    cond do
      MapSet.member?(state.active, receiver_id) ->
        put_pending(state, receiver_id, kind)

      Map.has_key?(state.pending, receiver_id) ->
        put_pending(state, receiver_id, kind)

      MapSet.size(state.active) < state.max_concurrency ->
        start_delivery(receiver_id, kind, state)

      true ->
        put_pending(state, receiver_id, kind)
    end
  end

  defp drain_pending(state) do
    if MapSet.size(state.active) < state.max_concurrency and map_size(state.pending) > 0 do
      {receiver_id, kind} = Enum.at(state.pending, 0)
      state = %{state | pending: Map.delete(state.pending, receiver_id)}
      receiver_id |> start_delivery(kind, state) |> drain_pending()
    else
      state
    end
  end

  defp start_delivery(receiver_id, kind, state) do
    owner = self()

    case Task.Supervisor.start_child(ChatchatTcp.Delivery.TaskSupervisor, fn ->
           try do
             MessageDelivery.deliver_pending(receiver_id, kind)
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

  defp put_pending(state, receiver_id, :recovery) do
    %{state | pending: Map.put(state.pending, receiver_id, :recovery)}
  end

  defp put_pending(state, receiver_id, :realtime) do
    %{state | pending: Map.put_new(state.pending, receiver_id, :realtime)}
  end
end
