defmodule ChatchatTcp.Delivery do
  @moduledoc "Bounded PostgreSQL inbox passes with wrapping cursors and reconciliation."
  use GenServer

  alias ChatchatBroker.Storage.MessagesStore
  alias ChatchatTcp.{Capacity, DeliveryQueue, MessageDelivery, Presence}

  @gate ChatchatTcp.InboxWakeCapacity
  @pending_limit 4_096
  @row_bytes 20_480
  @byte_budget 8 * 1_024 * 1_024

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def wake(receiver) do
    case Capacity.claim(@gate) do
      {:ok, ticket} ->
        send(__MODULE__, {:wake, ticket, receiver})
        :ok

      _ ->
        :ok
    end
  end

  def metric_snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(nil) do
    Capacity.new(@gate, @pending_limit)
    config = Application.fetch_env!(:chatchat_tcp, :delivery)
    timer = Process.send_after(self(), :reconcile, 1_000)

    {:ok,
     %{
       workers: %{},
       active: MapSet.new(),
       pending: DeliveryQueue.new(),
       cursors: %{},
       retries: %{},
       rerun: MapSet.new(),
       bytes: 0,
       limit: min(Keyword.fetch!(config, :batch_size), 128),
       concurrency: min(Keyword.fetch!(config, :max_concurrency), 64),
       scan: nil,
       reconcile_timer: timer
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       active_workers: map_size(state.workers),
       pending_receivers: DeliveryQueue.size(state.pending) + MapSet.size(state.rerun),
       loaded_bytes: state.bytes
     }, state}
  end

  @impl true
  def handle_info({:wake, ticket, receiver}, state) do
    Capacity.release(@gate, ticket)
    {:noreply, schedule(receiver, state) |> drain()}
  end

  def handle_info({:wake, receiver}, state), do: {:noreply, schedule(receiver, state) |> drain()}

  def handle_info(:reconcile, state) do
    Process.cancel_timer(state.reconcile_timer)
    {connections, cursor} = Presence.connections_page(state.scan)
    state = Enum.reduce(connections, state, fn {user, _pid}, state -> schedule(user, state) end)
    # Spread 128-user passes across the reconciliation period. No keyspace scan.
    batches = max(div(Presence.connection_count() + 127, 128), 1)
    interval = max(div(30_000, batches), 1)
    timer = Process.send_after(self(), :reconcile, interval)
    {:noreply, drain(%{state | scan: cursor, reconcile_timer: timer})}
  end

  def handle_info({:retry, receiver}, state) do
    if timer = state.retries[receiver], do: Process.cancel_timer(timer)
    state = %{state | retries: Map.delete(state.retries, receiver)}
    {:noreply, schedule(receiver, state) |> drain()}
  end

  def handle_info({reference, result}, state) when is_reference(reference) do
    Process.demonitor(reference, [:flush])
    {:noreply, complete(reference, result, state) |> drain()}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    {:noreply, complete(reference, %{cursor: nil, retry: true}, state) |> drain()}
  end

  defp schedule(receiver, state) do
    cond do
      not Presence.online?(receiver) ->
        forget(receiver, state)

      MapSet.member?(state.active, receiver) and
          DeliveryQueue.size(state.pending) + MapSet.size(state.rerun) < @pending_limit ->
        %{state | rerun: MapSet.put(state.rerun, receiver)}

      MapSet.member?(state.active, receiver) ->
        state

      DeliveryQueue.size(state.pending) + MapSet.size(state.rerun) >= @pending_limit ->
        state

      true ->
        %{state | pending: DeliveryQueue.put(state.pending, receiver)}
    end
  end

  defp drain(state) do
    rows = min(min(state.limit, 16), div(@byte_budget - state.bytes, @row_bytes))

    if map_size(state.workers) < state.concurrency and rows > 0 do
      case DeliveryQueue.pop(state.pending) do
        :empty ->
          state

        {:ok, receiver, _queued_at, pending} ->
          state = %{state | pending: pending}

          case Presence.get_connections(receiver) do
            [{_pid, %{"session" => session}}] ->
              cursor = state.cursors[receiver]

              task =
                Task.Supervisor.async_nolink(ChatchatTcp.Delivery.TaskSupervisor, fn ->
                  messages = MessagesStore.pending_page(receiver, cursor, rows)

                  messages =
                    if messages == [] and cursor,
                      do: MessagesStore.pending_page(receiver, nil, rows),
                      else: messages

                  Enum.each(messages, &MessageDelivery.deliver_stored(&1, session))

                  cursor =
                    case List.last(messages) do
                      nil -> nil
                      message -> {message.sender_id, message.message_id}
                    end

                  %{cursor: cursor, retry: messages != []}
                end)

              state = %{
                state
                | workers:
                    Map.put(state.workers, task.ref, {receiver, rows * @row_bytes, task.pid}),
                  active: MapSet.put(state.active, receiver),
                  bytes: state.bytes + rows * @row_bytes
              }

              drain(state)

            _ ->
              forget(receiver, state) |> drain()
          end
      end
    else
      state
    end
  end

  defp complete(reference, result, state) do
    case Map.pop(state.workers, reference) do
      {nil, _} ->
        state

      {{receiver, bytes, _pid}, workers} ->
        rerun = MapSet.member?(state.rerun, receiver)

        state = %{
          state
          | workers: workers,
            bytes: state.bytes - bytes,
            active: MapSet.delete(state.active, receiver),
            rerun: MapSet.delete(state.rerun, receiver)
        }

        if Presence.online?(receiver) do
          cursors =
            if result.cursor && map_size(state.cursors) < @pending_limit,
              do: Map.put(state.cursors, receiver, result.cursor),
              else: Map.delete(state.cursors, receiver)

          state = %{state | cursors: cursors}

          cond do
            rerun ->
              schedule(receiver, state)

            result.retry and not Map.has_key?(state.retries, receiver) and
                map_size(state.retries) < @pending_limit ->
              timer = Process.send_after(self(), {:retry, receiver}, 10_000)
              %{state | retries: Map.put(state.retries, receiver, timer)}

            true ->
              state
          end
        else
          forget(receiver, state)
        end
    end
  end

  defp forget(receiver, state) do
    if timer = state.retries[receiver], do: Process.cancel_timer(timer)

    %{
      state
      | cursors: Map.delete(state.cursors, receiver),
        retries: Map.delete(state.retries, receiver)
    }
  end
end
