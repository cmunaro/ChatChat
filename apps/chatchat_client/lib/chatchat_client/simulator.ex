defmodule ChatchatClient.Simulator do
  use GenServer

  alias ChatchatClient.SimulatedClient

  @defaults %{
    creation_concurrency: 40,
    ramp_interval_ms: 0,
    duration_seconds: :infinity,
    message_payload_size: 32
  }

  def start(options) do
    options = validate!(options)
    configure_http_pool(options.creation_concurrency)

    case DynamicSupervisor.start_child(
           ChatchatClient.SimulationSupervisor,
           {__MODULE__, options}
         ) do
      {:ok, pid} -> pid
      {:error, reason} -> raise "could not start simulation: #{inspect(reason)}"
    end
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def child_spec(options) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary
    }
  end

  @impl true
  def init(options) do
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    clients = :ets.new(:simulated_clients, [:set, :public])
    prefix = "sim_#{System.unique_integer([:positive])}"

    state = %{
      options: options,
      supervisor: supervisor,
      clients: clients,
      prefix: prefix,
      started: 0,
      startup_failures: 0
    }

    send(self(), :start_batch)
    schedule_stop(options.duration_seconds)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    children = DynamicSupervisor.count_children(state.supervisor)

    status = %{
      requested_clients: state.options.number_of_clients,
      wrappers_started: state.started,
      running_wrappers: children.active,
      ready_clients: :ets.info(state.clients, :size),
      startup_failures: state.startup_failures
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:start_batch, state) do
    {:noreply, start_clients(state, state.options.creation_concurrency)}
  end

  def handle_info({:client_ready, _index}, state) do
    if state.started < state.options.number_of_clients do
      Process.send_after(self(), :start_next, state.options.ramp_interval_ms)
    end

    {:noreply, state}
  end

  def handle_info({:client_start_failed, _index}, state) do
    {:noreply, %{state | startup_failures: state.startup_failures + 1}}
  end

  def handle_info(:start_next, state) do
    {:noreply, start_clients(state, 1)}
  end

  def handle_info(:stop, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.supervisor), do: Supervisor.stop(state.supervisor)
    :ok
  end

  defp validate!(options) when is_map(options) do
    options = Map.merge(@defaults, options)

    require_positive_integer!(options, :number_of_clients)
    require_probability!(options, :send_message_probability_per_second)
    require_probability!(options, :disconnection_probability_per_second)
    require_positive_integer!(options, :creation_concurrency)
    require_non_negative_integer!(options, :ramp_interval_ms)
    require_positive_integer!(options, :message_payload_size)

    case options.duration_seconds do
      :infinity -> :ok
      duration when is_integer(duration) and duration > 0 -> :ok
      _ -> raise ArgumentError, "duration_seconds must be :infinity or a positive integer"
    end

    options
  end

  defp validate!(_options), do: raise(ArgumentError, "simulation options must be a map")

  defp start_clients(state, maximum) do
    count = min(state.options.number_of_clients - state.started, maximum)

    if count > 0 do
      first = state.started + 1

      Enum.reduce(first..(first + count - 1), state, fn index, acc ->
        options = [
          index: index,
          username: "#{acc.prefix}_#{index}",
          simulator: self(),
          clients: acc.clients,
          number_of_clients: acc.options.number_of_clients,
          send_probability: acc.options.send_message_probability_per_second,
          disconnection_probability: acc.options.disconnection_probability_per_second,
          message: String.duplicate("x", acc.options.message_payload_size)
        ]

        case DynamicSupervisor.start_child(acc.supervisor, {SimulatedClient, options}) do
          {:ok, _pid} -> %{acc | started: acc.started + 1}
          {:error, _reason} -> acc
        end
      end)
    else
      state
    end
  end

  defp require_positive_integer!(options, key) do
    unless is_integer(options[key]) and options[key] > 0 do
      raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp require_probability!(options, key) do
    unless is_number(options[key]) and options[key] >= 0 and options[key] <= 1 do
      raise ArgumentError, "#{key} must be between 0.0 and 1.0"
    end
  end

  defp require_non_negative_integer!(options, key) do
    unless is_integer(options[key]) and options[key] >= 0 do
      raise ArgumentError, "#{key} must be a non-negative integer"
    end
  end

  defp schedule_stop(:infinity), do: :ok
  defp schedule_stop(seconds), do: Process.send_after(self(), :stop, seconds * 1_000)

  defp configure_http_pool(creation_concurrency) do
    {:ok, options} = :httpc.get_options([:max_sessions])
    current_max = Keyword.fetch!(options, :max_sessions)
    :ok = :httpc.set_options(max_sessions: max(current_max, creation_concurrency))
  end
end
