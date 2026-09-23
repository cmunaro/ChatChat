defmodule ChatchatClient.SimulatedClient do
  use GenServer

  @tick_interval 1_000
  @restart_interval 1_000

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
        activity_started: false
      })

    {:ok, state, {:continue, :start_client}}
  end

  @impl true
  def handle_continue(:start_client, state), do: start_client(state)

  @impl true
  def handle_info(:start_client, %{client: nil} = state), do: start_client(state)
  def handle_info(:start_client, state), do: {:noreply, state}

  def handle_info(:start_activity, %{activity_started: false} = state) do
    schedule_tick()
    {:noreply, %{state | activity_started: true}}
  end

  def handle_info(:start_activity, state), do: {:noreply, state}

  def handle_info(:tick, %{client: client} = state) when is_pid(client) do
    if selected?(state.send_probability), do: send_message(state)
    if selected?(state.disconnection_probability), do: ChatchatClient.disconnect(client)

    schedule_tick()
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, client, _reason},
        %{monitor: monitor, client: client} = state
      ) do
    :ets.delete(state.clients, state.index)
    Process.send_after(self(), :start_client, @restart_interval)
    {:noreply, %{state | client: nil, monitor: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state.clients, state.index)

    if is_pid(state.client) and Process.alive?(state.client) do
      GenServer.stop(state.client)
    end

    :ok
  end

  defp start_client(state) do
    client =
      if state.user_id do
        ChatchatClient.run_preprovisioned(state.username, state.user_id)
      else
        ChatchatClient.run(state.username)
      end

    register_client(state, client)
  rescue
    _error ->
      send(state.simulator, {:client_start_failed, state.index})
      Process.send_after(self(), :start_client, @restart_interval)
      {:noreply, state}
  end

  defp register_client(state, client) do
    monitor = Process.monitor(client)
    user_id = GenServer.call(client, :user_id)
    true = :ets.insert(state.clients, {state.index, client, user_id})

    unless state.announced_ready do
      send(state.simulator, {:client_ready, state.index, self()})
    end

    {:noreply, %{state | client: client, monitor: monitor, announced_ready: true}}
  rescue
    error ->
      GenServer.stop(client)
      reraise error, __STACKTRACE__
  end

  defp send_message(state) do
    case random_recipient(state, 3) do
      nil -> :ok
      recipient -> ChatchatClient.send_message(state.client, recipient, state.message)
    end
  end

  defp random_recipient(_state, 0), do: nil

  defp random_recipient(state, attempts) do
    index = :rand.uniform(state.number_of_clients)

    case :ets.lookup(state.clients, index) do
      [{^index, recipient, user_id}] when recipient != state.client -> user_id
      _ -> random_recipient(state, attempts - 1)
    end
  end

  defp selected?(0), do: false
  defp selected?(probability), do: :rand.uniform() <= probability
  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)
end
