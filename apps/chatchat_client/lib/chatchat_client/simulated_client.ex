defmodule ChatchatClient.SimulatedClient do
  use GenServer

  @tick_interval 1_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def child_spec(options) do
    %{
      id: {__MODULE__, Keyword.fetch!(options, :index)},
      start: {__MODULE__, :start_link, [options]}
    }
  end

  @impl true
  def init(options) do
    state =
      Map.new(options)
      |> Map.merge(%{
        client: nil,
        monitor: nil,
        announced_ready: false,
        activity_started: false,
        restart_timer: nil,
        restart_generation: nil,
        restart_failures: 0,
        last_start_attempt: nil
      })

    {:ok, state, {:continue, :start_client}}
  end

  @impl true
  def handle_continue(:start_client, state), do: start_client(state)

  @impl true
  def handle_info({:start_client, generation}, state) do
    if Map.get(state, :restart_generation) == generation,
      do: handle_info(:start_client, state),
      else: {:noreply, state}
  end

  def handle_info(:start_client, %{client: nil} = state) do
    if state.restart_timer, do: Process.cancel_timer(state.restart_timer)
    start_client(%{state | restart_timer: nil, restart_generation: nil})
  end

  def handle_info(:start_client, state), do: {:noreply, state}

  def handle_info(:start_activity, %{activity_started: false} = state) do
    schedule_tick()
    {:noreply, %{state | activity_started: true}}
  end

  def handle_info(:start_activity, state), do: {:noreply, state}

  def handle_info(:tick, %{client: client} = state) when is_pid(client) do
    if selected?(send_probability(state)), do: send_message(state)
    if selected?(state.disconnection_probability), do: ChatchatClient.disconnect(client)

    schedule_tick()
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, state}
  end

  def handle_info({:connection_diagnostic, event}, state) do
    ChatchatClient.ConnectionDiagnostics.record(state.connection_counts, event)
    {:noreply, state}
  end

  def handle_info({:retry_interval, role, interval}, state) do
    ChatchatClient.ConnectionDiagnostics.record_interval(state.connection_counts, role, interval)
    {:noreply, state}
  end

  def handle_info({:connection_timing, role, duration}, state) do
    ChatchatClient.ConnectionDiagnostics.record_timing(state.connection_counts, role, duration)
    {:noreply, state}
  end

  def handle_info({:delivery_attempt, retry?}, state) when is_boolean(retry?) do
    :atomics.add(state.result_counts, 14, 1)
    if retry?, do: :atomics.add(state.result_counts, 15, 1)
    {:noreply, state}
  end

  def handle_info({:delivery_queued, _id}, state) do
    :atomics.add(state.result_counts, 1, 1)
    {:noreply, state}
  end

  def handle_info({:delivery_confirmed, latency}, state)
      when is_integer(latency) and latency >= 0 do
    :atomics.add(state.result_counts, 6, 1)
    :atomics.add(state.result_counts, 7, latency)

    Enum.with_index([10, 50, 100, 500, 1_000, 10_000], 8)
    |> Enum.each(fn {bound, index} ->
      if latency <= bound, do: :atomics.add(state.result_counts, index, 1)
    end)

    {:noreply, state}
  end

  def handle_info({:delivery_result, status}, state) when status in [:ok, :failed, :rejected] do
    index =
      case status do
        :ok -> 2
        :failed -> 3
        :rejected -> 4
      end

    :atomics.add(state.result_counts, index, 1)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, client, _reason},
        %{monitor: monitor, client: client} = state
      ) do
    :ets.delete(state.clients, state.index)
    {:noreply, schedule_start_client(%{state | client: nil, monitor: nil})}
  end

  def handle_info({:DOWN, _reference, :process, _client, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state.clients, state.index)
    if state.restart_timer, do: Process.cancel_timer(state.restart_timer)

    if is_pid(state.client) and Process.alive?(state.client) do
      GenServer.stop(state.client)
    end

    :ok
  end

  defp start_client(state) do
    started = System.monotonic_time(:millisecond)

    if previous = state.last_start_attempt do
      ChatchatClient.ConnectionDiagnostics.emit_interval(
        %{result_observer: self()},
        :startup,
        started - previous
      )
    end

    do_start_client(%{state | last_start_attempt: started})
  end

  defp do_start_client(state) do
    options = [result_observer: self(), reconnect_admission: Map.get(state, :reconnect_admission)]

    client =
      if state.user_id do
        ChatchatClient.run_preprovisioned(state.username, state.user_id, options)
      else
        ChatchatClient.run(state.username, options)
      end

    register_client(state, client)
  rescue
    error ->
      send(state.simulator, {:client_start_failed, state.index, Exception.message(error)})
      {:noreply, schedule_start_client(state)}
  end

  defp register_client(state, client) do
    monitor = Process.monitor(client)
    user_id = GenServer.call(client, :user_id)
    true = :ets.insert(state.clients, {state.index, client, user_id})

    unless state.announced_ready do
      send(state.simulator, {:client_ready, state.index, self()})
    end

    {:noreply,
     %{
       state
       | client: client,
         monitor: monitor,
         announced_ready: true,
         restart_failures: 0,
         last_start_attempt: nil
     }}
  rescue
    error ->
      GenServer.stop(client)
      reraise error, __STACKTRACE__
  end

  defp schedule_start_client(%{restart_timer: nil} = state) do
    generation = make_ref()
    delay = ChatchatClient.ReconnectBackoff.delay(state.restart_failures)

    %{
      state
      | restart_timer: Process.send_after(self(), {:start_client, generation}, delay),
        restart_generation: generation,
        restart_failures: min(state.restart_failures + 1, 5)
    }
  end

  defp schedule_start_client(state), do: state

  defp send_message(state) do
    case random_recipient(state, 3) do
      nil ->
        :ok

      recipient ->
        result = submit_message(state, recipient)
        unless match?({:ok, _message_id}, result), do: :atomics.add(state.result_counts, 5, 1)
        result
    end
  end

  defp submit_message(state, recipient) do
    ChatchatClient.send_message(state.client, recipient, state.message)
  catch
    :exit, reason -> {:error, reason}
  end

  defp random_recipient(_state, 0), do: nil

  defp random_recipient(state, attempts) do
    index = :rand.uniform(state.number_of_clients)

    case :ets.lookup(state.clients, index) do
      [{^index, recipient, user_id}] when recipient != state.client -> user_id
      _ -> random_recipient(state, attempts - 1)
    end
  end

  defp send_probability(%{activity_options: table}),
    do: :ets.lookup_element(table, :send_probability, 2)

  defp send_probability(state), do: state.send_probability

  defp selected?(0), do: false
  defp selected?(probability), do: :rand.uniform() <= probability
  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)
end
