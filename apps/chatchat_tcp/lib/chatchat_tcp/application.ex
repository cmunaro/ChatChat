defmodule ChatchatTcp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    tcp_options = Application.fetch_env!(:chatchat_tcp, :server)

    children =
      [
        {Cluster.Supervisor,
         [
           Application.get_env(:chatchat_tcp, :cluster_topologies, []),
           [name: ChatchatTcp.ClusterSupervisor]
         ]},
        {Registry, keys: :unique, name: ChatchatTcp.Presence.Registry},
        redis_child(ChatchatTcp.Redis),
        ChatchatTcp.PresenceRouting,
        {ChatchatTcp.DeliverySupervisor, tcp_options}
      ] ++ metrics_children()

    Supervisor.start_link(children, strategy: :rest_for_one, name: ChatchatTcp.Supervisor)
  end

  defp metrics_children do
    if Application.get_env(:chatchat_tcp, ChatchatTcp.PromEx, [])[:disabled] do
      []
    else
      metrics_server = Application.fetch_env!(:chatchat_tcp, :metrics_server)

      [
        ChatchatTcp.PromEx,
        {Bandit,
         plug: {PromEx.Plug, prom_ex_module: ChatchatTcp.PromEx},
         ip: Keyword.fetch!(metrics_server, :ip),
         port: Keyword.fetch!(metrics_server, :port),
         startup_log: false}
      ]
    end
  end

  defp redis_child(name) do
    options = {Application.fetch_env!(:chatchat_tcp, :redis_url), name: name}
    Supervisor.child_spec({Redix, options}, id: name)
  end
end
