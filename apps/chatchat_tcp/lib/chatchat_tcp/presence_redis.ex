defmodule ChatchatTcp.PresenceRedis do
  @moduledoc "Bounded, user-sharded presence work with independent renewal and heartbeat lanes."
  use Supervisor

  @heartbeat ChatchatTcp.Redis.Heartbeat
  @sessions [
    ChatchatTcp.Redis.Session0,
    ChatchatTcp.Redis.Session1,
    ChatchatTcp.Redis.Session2,
    ChatchatTcp.Redis.Session3
  ]
  @renewals [
    ChatchatTcp.Redis.Renewal0,
    ChatchatTcp.Redis.Renewal1,
    ChatchatTcp.Redis.Renewal2,
    ChatchatTcp.Redis.Renewal3
  ]
  @workers [
    ChatchatTcp.PresenceRedis.Session0,
    ChatchatTcp.PresenceRedis.Session1,
    ChatchatTcp.PresenceRedis.Session2,
    ChatchatTcp.PresenceRedis.Session3,
    ChatchatTcp.PresenceRedis.Renewal0,
    ChatchatTcp.PresenceRedis.Renewal1,
    ChatchatTcp.PresenceRedis.Renewal2,
    ChatchatTcp.PresenceRedis.Renewal3
  ]

  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  def heartbeat, do: @heartbeat
  def connections, do: [@heartbeat | @sessions ++ @renewals]
  def role(name) when name in @sessions, do: :session
  def role(name) when name in @renewals, do: :renewal
  def role(@heartbeat), do: :heartbeat
  def role(_), do: nil

  def lane(role, user_id) when role in [:session, :renewal] do
    offset = if role == :renewal, do: 4, else: 0
    Enum.at(@workers, offset + :erlang.phash2(user_id, 4))
  end

  def run(role, user_id, operation),
    do: ChatchatTcp.PresenceRedis.Lane.run(lane(role, user_id), operation)

  @doc false
  def snapshot do
    Enum.map(@workers, fn name ->
      process =
        case Process.whereis(name) do
          nil -> nil
          pid -> Process.info(pid, [:message_queue_len, :memory])
        end

      size = :ets.info(name, :size)

      %{
        role: Atom.to_string(name),
        available: process != nil and is_integer(size),
        process: if(process, do: Map.new(process), else: %{}),
        reserved: if(is_integer(size), do: max(size - 1, 0), else: nil),
        limit: ChatchatTcp.PresenceRedis.Lane.slots()
      }
    end)
  end

  @impl true
  def init(_options) do
    url = Application.fetch_env!(:chatchat_tcp, :redis_url)
    heartbeat = Supervisor.child_spec({Redix, {url, name: @heartbeat}}, id: @heartbeat)

    lanes =
      Enum.zip(@workers, @sessions ++ @renewals)
      |> Enum.map(fn {worker, redis} ->
        Supervisor.child_spec(
          {ChatchatTcp.PresenceRedis.Lane, [name: worker, redis: redis, url: url]},
          id: worker
        )
      end)

    # A shared stall can expire every lane together. Allow two bounded waves
    # without escalating socket resets into a restart of listeners and ownership.
    Supervisor.init([heartbeat | lanes],
      strategy: :one_for_one,
      max_restarts: 2 * length(lanes) + 1,
      max_seconds: 5
    )
  end
end

defmodule ChatchatTcp.PresenceRedis.Lane do
  @moduledoc false
  use GenServer
  alias ChatchatTcp.{Capacity, PresenceRedis}

  @slots 512
  @timeout 5_000
  def timeout, do: @timeout
  def slots, do: @slots
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: options[:name])

  def run(name, operation) do
    started = System.monotonic_time()
    deadline = deadline()

    result =
      with {:ok, ticket} <- Capacity.claim(name) do
        try do
          with {:ok, gate, connection} <-
                 GenServer.call(name, {:admit, ticket, deadline}, :infinity) do
            {result, reset} =
              try do
                {operation.(connection, deadline), false}
              catch
                _, _ -> {{:error, :unavailable}, true}
              end

            GenServer.call(gate, {:finished, ticket, result, reset}, :infinity)
          end
        catch
          :exit, _ -> {:error, :unavailable}
        after
          Capacity.release(name, ticket)
        end
      end

    :telemetry.execute(
      [:chatchat, :presence, :work],
      %{duration: System.monotonic_time() - started, count: 1},
      %{role: worker_role(name), outcome: outcome(result)}
    )

    result
  end

  @impl true
  def init(options) do
    Capacity.new(options[:name], @slots)
    {:ok, redis} = Redix.start_link(options[:url], name: options[:redis])
    {:ok, %{redis: redis, pending: %{}, connection: options[:redis], table: options[:name]}}
  end

  @impl true
  def handle_call({:admit, ticket, deadline}, _from, state) do
    with :ok <- Capacity.activate(state.table, ticket),
         true <- Process.alive?(elem(ticket, 1)),
         true <- System.monotonic_time(:millisecond) < deadline do
      monitor = Process.monitor(elem(ticket, 1))

      {:reply, {:ok, self(), state.redis},
       %{state | pending: Map.put(state.pending, elem(ticket, 2), {ticket, monitor})}}
    else
      false ->
        Capacity.release(state.table, ticket)
        {:reply, {:error, :expired}, state}

      error ->
        Capacity.release(state.table, ticket)
        {:reply, error, state}
    end
  end

  def handle_call({:finished, ticket, result, reset}, _from, state) do
    state = complete(state, ticket)
    # Redix caller timeouts do not cancel commands. Discard this socket before
    # admitting more work after timeout, exception or an abandoned active caller.
    if reset or match?({:error, %Redix.ConnectionError{reason: :timeout}}, result),
      do: {:stop, :redis_timeout, result, state},
      else: {:reply, result, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    if Enum.any?(state.pending, fn {_, {_, reference}} -> reference == monitor end),
      do: {:stop, :abandoned_redis_work, state},
      else: {:noreply, state}
  end

  defp complete(state, ticket) do
    case Map.pop(state.pending, elem(ticket, 2)) do
      {nil, _} ->
        state

      {{^ticket, monitor}, pending} ->
        Process.demonitor(monitor, [:flush])
        Capacity.release(state.table, ticket)
        %{state | pending: pending}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Process.unlink(state.redis)
    Process.exit(state.redis, :kill)
    :ok
  end

  def deadline, do: System.monotonic_time(:millisecond) + @timeout

  defp worker_role(name) do
    if name in [
         PresenceRedis.Renewal0,
         PresenceRedis.Renewal1,
         PresenceRedis.Renewal2,
         PresenceRedis.Renewal3
       ], do: :renewal, else: :session
  end

  defp outcome({:error, :capacity}), do: :overloaded
  defp outcome({:error, _}), do: :error
  defp outcome(_), do: :ok
end
