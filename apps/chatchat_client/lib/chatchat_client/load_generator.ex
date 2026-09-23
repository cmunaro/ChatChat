defmodule ChatchatClient.LoadGenerator do
  use GenServer

  @poll_interval 5_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(options) do
    File.mkdir_p!(Keyword.fetch!(options, :barrier_directory))
    shard = claim_shard!(options)

    first_user_id =
      Keyword.fetch!(options, :first_user_id) + shard * Keyword.fetch!(options, :clients)

    simulation =
      ChatchatClient.simulate(%{
        number_of_clients: Keyword.fetch!(options, :clients),
        creation_concurrency: Keyword.fetch!(options, :creation_concurrency),
        ramp_interval_ms: Keyword.fetch!(options, :ramp_interval_ms),
        duration_seconds: Keyword.fetch!(options, :duration_seconds),
        send_message_probability_per_second: Keyword.fetch!(options, :send_probability),
        disconnection_probability_per_second: Keyword.fetch!(options, :disconnection_probability),
        message_payload_size: Keyword.fetch!(options, :message_payload_size),
        username_prefix: Keyword.fetch!(options, :id),
        first_user_id: first_user_id,
        auto_start_activity: false
      })

    state = %{
      options: options,
      simulation: simulation,
      barrier_announced: false,
      connect_deadline:
        System.monotonic_time(:second) + Keyword.fetch!(options, :connect_timeout_seconds),
      shard: shard
    }

    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    status = ChatchatClient.simulation_status(state.simulation)

    IO.inspect(
      status
      |> Map.put(:load_generator, state.options[:id])
      |> Map.put(:shard, state.shard)
    )

    enforce_connect_deadline!(state, status)
    state = announce_ready(state, status)
    start_if_ready(state, status)

    if Process.alive?(state.simulation), do: schedule_poll()
    {:noreply, state}
  end

  defp announce_ready(%{barrier_announced: false} = state, %{phase: :ready}) do
    File.write!(barrier_file(state), "ready\n")
    %{state | barrier_announced: true}
  end

  defp announce_ready(state, _status), do: state

  defp start_if_ready(state, %{phase: :ready}) do
    if ready_participants(state) >= state.options[:participants] do
      :ok = ChatchatClient.start_simulation_activity(state.simulation)
    end
  end

  defp start_if_ready(_state, _status), do: :ok

  defp ready_participants(state) do
    state.options[:barrier_directory]
    |> Path.join("*.ready")
    |> Path.wildcard()
    |> length()
  end

  defp barrier_file(state) do
    Path.join(state.options[:barrier_directory], "#{state.options[:id]}.ready")
  end

  defp enforce_connect_deadline!(state, %{phase: :connecting}) do
    if System.monotonic_time(:second) >= state.connect_deadline do
      raise "connection stage exceeded #{state.options[:connect_timeout_seconds]} seconds"
    end
  end

  defp enforce_connect_deadline!(_state, _status), do: :ok

  defp claim_shard!(options) do
    claims_directory = Path.join(Keyword.fetch!(options, :barrier_directory), "claims")
    File.mkdir_p!(claims_directory)

    Enum.find_value(0..(Keyword.fetch!(options, :participants) - 1), fn shard ->
      case File.mkdir(Path.join(claims_directory, Integer.to_string(shard))) do
        :ok -> shard
        {:error, :eexist} -> nil
        {:error, reason} -> raise "could not claim load-generator shard: #{inspect(reason)}"
      end
    end) || raise "no unclaimed load-generator shard is available"
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval)
end
