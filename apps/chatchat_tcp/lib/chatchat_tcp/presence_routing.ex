defmodule ChatchatTcp.PresenceRouting do
  @moduledoc """
  Maintains this TCP node's Redis heartbeat and node-specific delivery channel.

  User ownership is stored separately by `ChatchatTcp.Presence`. A random boot
  suffix prevents ownership left by a crashed process from becoming valid when
  a container name is reused.
  """

  use GenServer

  alias ChatchatTcp.RedisKeys

  @redis ChatchatTcp.Redis
  @node_id_key {__MODULE__, :node_id}
  @heartbeat_ttl_key {__MODULE__, :heartbeat_ttl}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec node_id() :: binary()
  def node_id, do: :persistent_term.get(@node_id_key)

  @spec delivery_channel() :: binary()
  def delivery_channel, do: RedisKeys.delivery_channel(node_id())

  @spec heartbeat_ttl() :: pos_integer()
  def heartbeat_ttl, do: :persistent_term.get(@heartbeat_ttl_key)

  @impl GenServer
  def init(_options) do
    config = Application.fetch_env!(:chatchat_tcp, :presence_routing)
    base_id = Keyword.fetch!(config, :node_id)
    ttl = Keyword.fetch!(config, :heartbeat_ttl)
    interval = Keyword.fetch!(config, :heartbeat_interval)
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
    case Redix.command(@redis, ["SET", RedisKeys.presence_node(node_id), "1", "PX", ttl]) do
      {:ok, "OK"} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_heartbeat(interval), do: Process.send_after(self(), :heartbeat, interval)
end
