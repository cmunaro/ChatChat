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

  alias ChatchatTcp.{DeliveryQueue, MessageDelivery, PresenceRouting}
  alias Ecto.UUID

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
    channel = PresenceRouting.delivery_channel()

    max_concurrency =
      :chatchat_tcp
      |> Application.fetch_env!(:delivery)
      |> Keyword.fetch!(:max_concurrency)

    with :ok <- MessageDelivery.load_script(),
         {:ok, pubsub} <-
           Redix.PubSub.start_link(Application.fetch_env!(:chatchat_tcp, :redis_url)),
         {:ok, subscription} <- Redix.PubSub.subscribe(pubsub, channel, self()) do
      {:ok,
       %{
         pubsub: pubsub,
         subscription: subscription,
         channel: channel,
         active: MapSet.new(),
         workers: %{},
         cursors: %{},
         rerun: %{},
         retries: %{},
         pending: DeliveryQueue.new(),
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
      pending_receivers: DeliveryQueue.size(state.pending) + map_size(state.rerun)
    }

    {:reply, snapshot, state}
  end

  @impl GenServer
  def handle_info(
        {:redix_pubsub, pubsub, subscription, :message, %{channel: channel, payload: payload}},
        %{pubsub: pubsub, subscription: subscription, channel: channel} = state
      ) do
    case Integer.parse(payload) do
      {receiver_id, ""} -> {:noreply, schedule(receiver_id, :realtime, state)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.workers, ref) do
      {nil, _workers} ->
        {:noreply, state}

      {{receiver_id, _pid}, workers} ->
        complete(receiver_id, result, %{state | workers: workers})
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.workers, ref) do
      {nil, _workers} ->
        {:noreply, state}

      {{receiver_id, _pid}, workers} ->
        ChatchatTcp.Telemetry.delivery_failure(:unknown, :worker_exit)
        result = %{cursor: Map.get(state.cursors, receiver_id), retry: true}
        complete(receiver_id, result, %{state | workers: workers})
    end
  end

  def handle_info({:retry, receiver_id}, state) do
    state = %{state | retries: Map.delete(state.retries, receiver_id)}
    {:noreply, schedule(receiver_id, :realtime, state)}
  end

  def handle_info({:redix_pubsub, _, _, _, _}, state), do: {:noreply, state}

  defp schedule(receiver_id, kind, state) do
    cond do
      MapSet.member?(state.active, receiver_id) ->
        put_pending(state, receiver_id, kind)

      Map.has_key?(state.pending.entries, receiver_id) ->
        put_pending(state, receiver_id, kind)

      MapSet.size(state.active) < state.max_concurrency ->
        start_delivery(receiver_id, kind, state)

      true ->
        put_pending(state, receiver_id, kind)
    end
  end

  defp drain_pending(state) do
    if MapSet.size(state.active) < state.max_concurrency and DeliveryQueue.size(state.pending) > 0 do
      {:ok, receiver_id, kind, _queued_at, pending} = DeliveryQueue.pop(state.pending)
      state = %{state | pending: pending}
      receiver_id |> start_delivery(kind, state) |> drain_pending()
    else
      state
    end
  end

  defp start_delivery(receiver_id, kind, state) do
    cursor = Map.get(state.cursors, receiver_id)

    task =
      Task.Supervisor.async_nolink(ChatchatTcp.Delivery.TaskSupervisor, fn ->
        MessageDelivery.deliver_pending(receiver_id, kind, cursor)
      end)

    %{
      state
      | active: MapSet.put(state.active, receiver_id),
        workers: Map.put(state.workers, task.ref, {receiver_id, task.pid})
    }
  end

  defp complete(receiver_id, result, state) do
    cursors =
      if result.cursor,
        do: Map.put(state.cursors, receiver_id, result.cursor),
        else: Map.delete(state.cursors, receiver_id)

    {rerun, reruns} = Map.pop(state.rerun, receiver_id)

    state = %{
      state
      | active: MapSet.delete(state.active, receiver_id),
        cursors: cursors,
        rerun: reruns
    }

    state = if rerun, do: put_pending(state, receiver_id, rerun), else: state
    state = if result.cursor, do: put_pending(state, receiver_id, :recovery), else: state

    state =
      if result.retry and not Map.has_key?(state.retries, receiver_id) do
        timer = Process.send_after(self(), {:retry, receiver_id}, 1_000)
        %{state | retries: Map.put(state.retries, receiver_id, timer)}
      else
        state
      end

    {:noreply, drain_pending(state)}
  end

  defp put_pending(state, receiver_id, kind) do
    if MapSet.member?(state.active, receiver_id) do
      strongest =
        if kind == :recovery, do: :recovery, else: Map.get(state.rerun, receiver_id, kind)

      %{state | rerun: Map.put(state.rerun, receiver_id, strongest)}
    else
      %{state | pending: DeliveryQueue.put(state.pending, receiver_id, kind)}
    end
  end
end
