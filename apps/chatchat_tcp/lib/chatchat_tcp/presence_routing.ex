defmodule ChatchatTcp.PresenceRouting do
  @moduledoc """
  Maintains this TCP node's expiring Redis heartbeat.

  User ownership is stored separately by `ChatchatTcp.Presence`. A random boot
  suffix prevents ownership left by a crashed process from becoming valid when
  a container name is reused.
  """

  use GenServer

  alias ChatchatTcp.RedisKeys

  @redis ChatchatTcp.Redis.Heartbeat
  @node_id_key {__MODULE__, :node_id}
  @heartbeat_ttl_key {__MODULE__, :heartbeat_ttl}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec node_id() :: binary()
  def node_id, do: :persistent_term.get(@node_id_key)

  @spec heartbeat_ttl() :: pos_integer()
  def heartbeat_ttl, do: :persistent_term.get(@heartbeat_ttl_key)

  @doc "Jittered renewal delay, capped by the conservative local lease deadline."
  def renewal_delay(deadline) do
    interval = Application.fetch_env!(:chatchat_tcp, :presence_routing)[:heartbeat_interval]
    jitter = div(interval, 5)
    delay = interval - jitter + :rand.uniform(2 * jitter + 1) - 1

    remaining =
      deadline - System.monotonic_time(:millisecond) -
        2 * ChatchatTcp.PresenceRedis.Lane.timeout()

    max(min(delay, remaining), 0)
  end

  @doc "Back off transient renewal failures without extending the confirmed lease."
  def retry_delay(deadline, failures) do
    base = 1_000 * Integer.pow(2, min(failures, 2))
    delay = base + :rand.uniform(div(base, 5) + 1) - 1
    remaining = deadline - System.monotonic_time(:millisecond)
    max(min(delay, remaining), 0)
  end

  @impl GenServer
  def init(_options) do
    Process.flag(:priority, :high)
    :ets.new(ChatchatTcp.Presence.Users, [:set, :named_table, :public])
    config = Application.fetch_env!(:chatchat_tcp, :presence_routing)
    base_id = Keyword.fetch!(config, :node_id)
    ttl = Keyword.fetch!(config, :heartbeat_ttl)
    interval = Keyword.fetch!(config, :heartbeat_interval)

    true =
      interval > 0 and
        interval + div(interval, 5) + 2 * ChatchatTcp.PresenceRedis.Lane.timeout() < ttl

    boot_id = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    node_id = "#{base_id}-#{boot_id}"

    :persistent_term.put(@node_id_key, node_id)
    :persistent_term.put(@heartbeat_ttl_key, ttl)

    case refresh_heartbeat(node_id, ttl) do
      :ok ->
        schedule_heartbeat(interval)
        {:ok, %{node_id: node_id, ttl: ttl, interval: interval}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_info({reference, _late_reply}, state) when is_reference(reference),
    do: {:noreply, state}

  def handle_info(:heartbeat, state) do
    _ = refresh_heartbeat(state.node_id, state.ttl)
    schedule_heartbeat(state.interval)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Redix.command(@redis, ["DEL", RedisKeys.presence_node(state.node_id)])
    :persistent_term.erase(@node_id_key)
    :persistent_term.erase(@heartbeat_ttl_key)
    :ok
  end

  defp refresh_heartbeat(node_id, ttl) do
    case Redix.command(@redis, ["SET", RedisKeys.presence_node(node_id), "1", "PX", ttl],
           timeout: ChatchatTcp.PresenceRedis.Lane.timeout()
         ) do
      {:ok, "OK"} ->
        :telemetry.execute(
          [:chatchat, :presence, :heartbeat],
          %{last_success: System.system_time(:second)},
          %{}
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schedule_heartbeat(interval), do: Process.send_after(self(), :heartbeat, interval)
end
